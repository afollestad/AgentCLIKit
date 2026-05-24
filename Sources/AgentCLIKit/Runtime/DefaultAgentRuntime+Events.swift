import Foundation

private struct ProviderSessionSaveFailure {
    let record: AgentSessionRecord
    let processToken: UUID
    let error: Error
}

extension DefaultAgentRuntime {
    func addSubscriber(
        _ continuation: AsyncStream<AgentEventEnvelope>.Continuation,
        conversationId: AgentConversationID,
        afterIndex: Int?
    ) {
        guard var state = states[conversationId] else {
            let id = UUID()
            pendingSubscribers[conversationId, default: [:]][id] = continuation
            continuation.onTermination = { _ in Task { await self.removeSubscriber(id, conversationId: conversationId) } }
            return
        }
        let id = UUID()
        state.subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeSubscriber(id, conversationId: conversationId) } }
        let cursor = afterIndex ?? -1
        state.events.filter { $0.index > cursor }.forEach { continuation.yield($0) }
        states[conversationId] = state
    }

    func removeSubscriber(_ id: UUID, conversationId: AgentConversationID) {
        states[conversationId]?.subscribers[id] = nil
        pendingSubscribers[conversationId]?[id] = nil
    }

    func removeStatusSubscriber(_ id: UUID, conversationId: AgentConversationID) {
        statusSubscribers[conversationId]?[id] = nil
    }

    func pump(
        _ fileHandle: FileHandle,
        source: AgentEventSource,
        conversationId: AgentConversationID,
        processToken: UUID
    ) {
        // Claude stream-json can finish a record at EOF without a trailing newline.
        // A readability handler lets the runtime flush that final record instead of leaving hosts stuck waiting.
        let pump = OutputLinePump(handle: fileHandle) { line in
            await self.consumeLine(line, source: source, conversationId: conversationId, processToken: processToken)
        }
        states[conversationId]?.outputPumps.append(pump)
        pump.start()
    }

    func consumeLine(
        _ line: String,
        source: AgentEventSource,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        // Stream pumps can outlive a replaced process; the token prevents stale output from entering the new session.
        guard let state = states[conversationId], state.processToken == processToken else {
            return
        }
        if source == .stderr {
            appendStderr(line, conversationId: conversationId)
            append(.diagnostic(AgentDiagnosticEvent(severity: .info, message: line)), source: .stderr, conversationId: conversationId)
            return
        }
        do {
            let events = try await state.adapter.decodeStdoutLine(line)
            // Decoders can suspend, so re-check the token before accepting output for a replaced process.
            guard states[conversationId]?.processToken == processToken else {
                return
            }
            for event in events {
                await recordProviderSessionIfNeeded(from: event, conversationId: conversationId, processToken: processToken)
                guard states[conversationId]?.processToken == processToken else {
                    return
                }
                append(event, source: .stdout, conversationId: conversationId)
            }
        } catch {
            // Stdout and stderr are pumped independently; a short grace period lets earlier stderr lines reach the tail.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard states[conversationId]?.processToken == processToken else {
                return
            }
            let tail = states[conversationId]?.stderrTail.joined(separator: "\n") ?? ""
            let message = tail.isEmpty ? error.localizedDescription : "\(error.localizedDescription)\nRecent stderr:\n\(tail)"
            // Preserve the raw stdout frame in metadata so provider decoder gaps can be fixed from host logs.
            append(.diagnostic(AgentDiagnosticEvent(
                severity: .error,
                message: message,
                metadata: ["raw_stdout_line": .string(line)]
            )), source: .runtime, conversationId: conversationId)
        }
    }

    func recordProviderSessionIfNeeded(
        from event: AgentEvent,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        guard
            var state = states[conversationId],
            state.processToken == processToken,
            let providerSessionId = state.adapter.sessionID(from: event)
        else {
            return
        }
        guard state.providerSessionId != providerSessionId else {
            return
        }

        // Session IDs are discovered from provider output; update runtime status before awaiting durable storage.
        state.providerSessionId = providerSessionId
        let createdAt = state.providerSessionCreatedAt ?? Date()
        state.providerSessionCreatedAt = createdAt
        states[conversationId] = state
        publishStatus(conversationId: conversationId)

        let record = providerSessionRecord(
            conversationId: conversationId,
            state: state,
            providerSessionId: providerSessionId,
            createdAt: createdAt
        )
        if let failure = await persistProviderSessionRecord(record, processToken: processToken) {
            guard
                let current = states[conversationId],
                current.processToken == failure.processToken || current.providerSessionId == failure.record.providerSessionId
            else {
                return
            }
            emitDiagnostic(
                severity: .warning,
                message: "Could not persist provider session: \(failure.error.localizedDescription)",
                source: .runtime,
                conversationId: conversationId
            )
        }
    }

    private func persistProviderSessionRecord(
        _ record: AgentSessionRecord,
        processToken: UUID
    ) async -> ProviderSessionSaveFailure? {
        var pendingRecord = record
        var pendingProcessToken = processToken

        while true {
            do {
                try await sessionStore.save(pendingRecord)
            } catch {
                return ProviderSessionSaveFailure(record: pendingRecord, processToken: pendingProcessToken, error: error)
            }
            guard
                let current = states[pendingRecord.conversationId],
                current.processToken != pendingProcessToken,
                let currentProviderSessionId = current.providerSessionId,
                currentProviderSessionId != pendingRecord.providerSessionId
            else {
                return nil
            }

            // A save from a replaced process can resume last; persist the active session again so continuity stays current.
            let createdAt = current.providerSessionCreatedAt ?? Date()
            pendingRecord = providerSessionRecord(
                conversationId: pendingRecord.conversationId,
                state: current,
                providerSessionId: currentProviderSessionId,
                createdAt: createdAt
            )
            pendingProcessToken = current.processToken
        }
    }

    private func providerSessionRecord(
        conversationId: AgentConversationID,
        state: ConversationState,
        providerSessionId: AgentSessionID,
        createdAt: Date
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: conversationId,
            providerId: state.providerId,
            providerSessionId: providerSessionId,
            generation: state.generation,
            createdAt: createdAt,
            metadata: ["source": .string("runtime")]
        )
    }

    func processExited(conversationId: AgentConversationID, processToken: UUID, exitCode: Int32) async {
        // Termination handlers may race with reconfigure/freshSession; ignore callbacks from older processes.
        guard let current = states[conversationId], current.processToken == processToken else {
            return
        }
        switch states[conversationId]?.lifecycleState {
        case .cancelled, .exited, .failed:
            states[conversationId]?.stdin = nil
            states[conversationId]?.stdinWriter = nil
            await current.adapter.processDidTerminate(processToken: processToken)
            return
        case .starting, .running, nil:
            break
        }
        let state: AgentLifecycleState = exitCode == 0 ? .exited : .failed
        emitLifecycle(state, conversationId: conversationId, exitCode: exitCode)
        states[conversationId]?.stdin = nil
        states[conversationId]?.stdinWriter = nil
        await current.adapter.processDidTerminate(processToken: processToken)
    }

    func emitLifecycle(
        _ state: AgentLifecycleState,
        conversationId: AgentConversationID,
        exitCode: Int32? = nil,
        message: String? = nil
    ) {
        append(.lifecycle(AgentLifecycleEvent(state: state, exitCode: exitCode, message: message)), source: .process, conversationId: conversationId)
        states[conversationId]?.lifecycleState = state
        if state.isTerminal {
            states[conversationId]?.inputAvailability = .blocked(reason: "The provider process is \(state.rawValue).")
            states[conversationId]?.waitingState = .idle
        }
        publishStatus(conversationId: conversationId)
    }

    func emitDiagnostic(
        severity: AgentDiagnosticSeverity,
        message: String,
        source: AgentEventSource,
        conversationId: AgentConversationID
    ) {
        append(.diagnostic(AgentDiagnosticEvent(severity: severity, message: message)), source: source, conversationId: conversationId)
    }

    func emitSessionContinuity(
        _ continuity: AgentSessionContinuity?,
        providerSessionId: AgentSessionID?,
        conversationId: AgentConversationID
    ) {
        guard let continuity else {
            return
        }
        let message: String? = switch continuity {
        case .fresh:
            "Started a fresh provider session."
        case .resumed:
            "Resumed provider session."
        case .restartedFresh:
            "Provider session artifact was unavailable; restarted with the saved session identifier."
        }
        append(
            .sessionContinuity(AgentSessionContinuityEvent(
                continuity: continuity,
                providerSessionId: providerSessionId,
                message: message
            )),
            source: .runtime,
            conversationId: conversationId
        )
    }

    func appendStderr(_ line: String, conversationId: AgentConversationID) {
        guard var state = states[conversationId] else {
            return
        }
        state.stderrTail.append(line)
        if state.stderrTail.count > 20 {
            state.stderrTail.removeFirst(state.stderrTail.count - 20)
        }
        states[conversationId] = state
    }

    func append(_ event: AgentEvent, source: AgentEventSource, conversationId: AgentConversationID) {
        guard var state = states[conversationId] else {
            return
        }
        let envelope = AgentEventEnvelope(
            generation: state.generation,
            index: (state.events.last?.index ?? -1) + 1,
            providerId: state.providerId,
            conversationId: conversationId,
            providerSessionId: state.providerSessionId,
            source: source,
            event: event
        )
        state.events.append(envelope)
        applyStatusSideEffects(for: event, state: &state)
        state.compactReplayBuffer(replayLimit: replayLimit)
        state.subscribers.values.forEach { $0.yield(envelope) }
        states[conversationId] = state
        publishStatus(conversationId: conversationId)
    }

    private func applyStatusSideEffects(for event: AgentEvent, state: inout ConversationState) {
        switch event {
        case let .permissionMode(permissionMode):
            state.permissionMode = permissionMode.mode
        case let .interaction(interaction):
            switch interaction.kind {
            case .approval:
                state.waitingState = .approval
                state.inputAvailability = .blocked(reason: "Waiting for approval.")
            case .prompt:
                state.waitingState = .prompt
                state.inputAvailability = .blocked(reason: "Waiting for a prompt answer.")
            case .planModeExit:
                state.waitingState = .planModeExit
                state.inputAvailability = .blocked(reason: "Waiting for plan-mode approval.")
            }
        case let .lifecycle(lifecycle):
            if lifecycle.state == .running {
                state.inputAvailability = .available
            }
        default:
            break
        }
    }

    func publishStatus(conversationId: AgentConversationID) {
        guard let status = states[conversationId]?.status(conversationId: conversationId) else {
            return
        }
        statusSubscribers[conversationId]?.values.forEach { $0.yield(status) }
    }
}

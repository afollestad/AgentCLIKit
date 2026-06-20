import Foundation

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
            append(
                .diagnostic(AgentDiagnosticEvent(code: .providerStderr, severity: .info, message: line)),
                source: .stderr,
                conversationId: conversationId
            )
            return
        }
        guard state.hasDeferredToolStop == false else {
            return
        }
        do {
            let context = AgentProviderOutputContext(
                conversationId: conversationId,
                processToken: processToken,
                providerSessionId: state.providerSessionId,
                spawnConfig: state.spawnConfig
            )
            let events = try await state.adapter.decodeStdoutLine(line, context: context)
            await appendDecodedProviderEvents(events, conversationId: conversationId, processToken: processToken)
        } catch {
            await appendProviderDecodeFailure(error, line: line, conversationId: conversationId, processToken: processToken)
        }
    }

    private func appendDecodedProviderEvents(
        _ events: [AgentEvent],
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        // Decoders can suspend, so re-check the token before accepting output for a replaced process.
        guard states[conversationId]?.processToken == processToken else {
            return
        }
        var hasDeferredToolStop = false
        for decodedEvent in events {
            let eventsToAppend = lifecycleGuardedEvents(from: decodedEvent, conversationId: conversationId)
            for event in eventsToAppend {
                await recordProviderSessionIfNeeded(from: event, conversationId: conversationId, processToken: processToken)
                guard states[conversationId]?.processToken == processToken else {
                    return
                }
                guard shouldAppendProviderEvent(event, conversationId: conversationId) else {
                    continue
                }
                hasDeferredToolStop = hasDeferredToolStop || isDeferredToolStop(event)
                append(event, source: .stdout, conversationId: conversationId)
            }
            guard states[conversationId]?.processToken == processToken else {
                return
            }
        }
        if hasDeferredToolStop {
            stopProcessAfterDeferredToolStop(conversationId: conversationId)
        }
    }

    private func appendProviderDecodeFailure(
        _ error: Error,
        line: String,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        // Stdout and stderr are pumped independently; a short grace period lets earlier stderr lines reach the tail.
        await sleep(50_000_000)
        guard states[conversationId]?.processToken == processToken else {
            return
        }
        let tail = states[conversationId]?.stderrTail.joined(separator: "\n") ?? ""
        let message = tail.isEmpty ? error.localizedDescription : "\(error.localizedDescription)\nRecent stderr:\n\(tail)"
        // Preserve the raw stdout frame in metadata so provider decoder gaps can be fixed from host logs.
        append(.diagnostic(AgentDiagnosticEvent(
            code: .providerDecodeFailed,
            severity: .error,
            message: message,
            metadata: [
                "decoder_error": .string(error.localizedDescription),
                "raw_stdout_line": .string(line),
                "stderr_tail": .string(tail)
            ]
        )), source: .runtime, conversationId: conversationId)
    }

    private func shouldAppendProviderEvent(_ event: AgentEvent, conversationId: AgentConversationID) -> Bool {
        guard var state = states[conversationId], var gate = state.providerResumeReplayGate else {
            return true
        }
        // Suppressed replay events must not re-trigger deferred-stop handling or pending interactions.
        let shouldSuppress = gate.shouldSuppress(event)
        state.providerResumeReplayGate = gate.isFinished ? nil : gate
        states[conversationId] = state
        return !shouldSuppress
    }

    private func stopProcessAfterDeferredToolStop(conversationId: AgentConversationID) {
        // The provider is waiting on host fallback approval. Close stdin so it exits on its own after flushing
        // deferred-tool session records; an immediate kill can race those writes and strip the transcript marker
        // a later resume needs to re-run the deferred tool. `hasDeferredToolStop` already drops trailing stdout.
        guard var state = states[conversationId] else {
            return
        }
        state.hasDeferredToolStop = true
        let stdin = state.stdin
        let processToken = state.processToken
        state.stdin = nil
        state.stdinWriter = nil
        states[conversationId] = state
        try? stdin?.close()
        Task { [weak self] in
            await self?.killDeferredStopProcessAfterGracePeriod(
                conversationId: conversationId,
                processToken: processToken
            )
        }
    }

    private func killDeferredStopProcessAfterGracePeriod(
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        await sleep(deferredStopKillGraceNanoseconds)
        // Escalate only for the same process; a replaced or already exited process must not be touched.
        guard let state = states[conversationId], state.processToken == processToken else {
            return
        }
        forceKill(state.process)
    }

    private func isDeferredToolStop(_ event: AgentEvent) -> Bool {
        guard case let .usage(usage) = event else {
            return false
        }
        return usage.stopReason == "tool_deferred" || usage.metadata["stop_reason"] == .string("tool_deferred")
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
            states[conversationId]?.providerEventTasks.forEach { $0.cancel() }
            states[conversationId]?.providerEventTasks = []
            // Cancellation publishes while the process may still be running; publish again
            // from the termination callback so hosts clear cached process-running flags.
            publishStatus(conversationId: conversationId)
            await current.adapter.processDidTerminate(processToken: processToken)
            return
        case .starting, .running, nil:
            break
        }
        for pump in current.outputPumps {
            await pump.waitUntilDrained(timeoutNanoseconds: outputDrainTimeoutNanoseconds, sleep: sleep)
        }
        guard let latest = states[conversationId], latest.processToken == processToken else {
            return
        }
        let state: AgentLifecycleState = latest.hasDeferredToolStop || exitCode == 0 ? .exited : .failed
        emitFailedContextCompactionsForTerminalProcess(
            conversationId: conversationId,
            reason: state.rawValue,
            message: "Context compaction did not finish before the provider process ended."
        )
        emitFailedSubAgentsForTerminalProcess(
            conversationId: conversationId,
            reason: state.rawValue,
            message: "Sub-agent did not finish before the provider process ended."
        )
        emitLifecycle(state, conversationId: conversationId, exitCode: exitCode)
        states[conversationId]?.stdin = nil
        states[conversationId]?.stdinWriter = nil
        states[conversationId]?.providerEventTasks.forEach { $0.cancel() }
        states[conversationId]?.providerEventTasks = []
        await latest.adapter.processDidTerminate(processToken: processToken)
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
            let isWaitingOnDeferredInteraction = states[conversationId]?.hasDeferredToolStop == true &&
                states[conversationId]?.waitingState != .idle
            if !isWaitingOnDeferredInteraction {
                states[conversationId]?.inputAvailability = .blocked(reason: "The provider process is \(state.rawValue).")
                states[conversationId]?.waitingState = .idle
            }
        }
        publishStatus(conversationId: conversationId)
    }

    func emitDiagnostic(
        code: AgentDiagnosticCode? = nil,
        severity: AgentDiagnosticSeverity,
        message: String,
        metadata: [String: JSONValue] = [:],
        source: AgentEventSource,
        conversationId: AgentConversationID
    ) {
        append(
            .diagnostic(AgentDiagnosticEvent(code: code, severity: severity, message: message, metadata: metadata)),
            source: source,
            conversationId: conversationId
        )
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
        case .forked:
            "Forked provider session."
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
        guard shouldAppendEvent(event, state: state) else {
            states[conversationId] = state
            return
        }
        let event = eventForEnvelope(event, state: &state)
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
        notifyProviderOfStatusSideEffects(for: event, adapter: state.adapter, conversationId: conversationId)
        state.compactReplayBuffer(replayLimit: replayLimit)
        state.subscribers.values.forEach { $0.yield(envelope) }
        states[conversationId] = state
        publishStatus(conversationId: conversationId)
        synthesizePlanModeExitIfNeeded(from: envelope, conversationId: conversationId)
        schedulePendingPlanImplementationDrainIfNeeded(conversationId: conversationId)
    }

    private func eventForEnvelope(_ event: AgentEvent, state: inout ConversationState) -> AgentEvent {
        guard case let .sessionMetadata(metadata) = event else {
            applyStatusSideEffects(for: event, state: &state)
            return event
        }
        applySessionMetadataStatusSideEffects(for: metadata, state: &state)
        return .sessionMetadata(AgentSessionMetadataEvent(
            providerSessionId: metadata.providerSessionId ?? state.providerSessionId,
            name: state.providerSessionName,
            preview: state.providerSessionPreview,
            metadata: metadata.metadata
        ))
    }

    private func shouldAppendEvent(_ event: AgentEvent, state: ConversationState) -> Bool {
        guard case let .interaction(interaction) = event else {
            return true
        }
        // Provider output can replay an interaction after the host already resolved it; keep the runtime monotonic.
        return !state.resolvedInteractions.contains(interaction.id)
    }

    private func notifyProviderOfStatusSideEffects(
        for event: AgentEvent,
        adapter: any AgentProviderAdapter,
        conversationId: AgentConversationID
    ) {
        guard case let .permissionMode(permissionMode) = event else {
            return
        }
        let mode = permissionMode.mode
        Task {
            await adapter.permissionModeDidChange(mode, conversationId: conversationId)
        }
    }

    private func applyStatusSideEffects(for event: AgentEvent, state: inout ConversationState) {
        switch event {
        case let .activity(activity):
            applyActivityStatusSideEffects(for: activity, state: &state)
        case let .permissionMode(permissionMode):
            state.permissionMode = permissionMode.mode
        case let .collaborationMode(collaborationMode):
            state.collaborationMode = collaborationMode.mode
        case .sessionMetadata:
            break
        case let .interaction(interaction):
            applyInteractionStatusSideEffects(for: interaction, state: &state)
        case let .usage(usage):
            if usage.endsActiveTurn {
                state.isTurnActive = false
            }
        case let .lifecycle(lifecycle):
            applyLifecycleStatusSideEffects(for: lifecycle, state: &state)
        default:
            break
        }
    }

    private func applyActivityStatusSideEffects(for activity: AgentActivityEvent, state: inout ConversationState) {
        state.isTurnActive = activity.state == .active
        if activity.state == .idle, state.waitingState == .idle, !state.lifecycleState.isTerminal {
            state.inputAvailability = .available
        }
    }

    private func applyInteractionStatusSideEffects(for interaction: AgentInteractionEvent, state: inout ConversationState) {
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
    }

    private func applyLifecycleStatusSideEffects(for lifecycle: AgentLifecycleEvent, state: inout ConversationState) {
        if lifecycle.state == .running { state.inputAvailability = .available }
        if lifecycle.state.isTerminal { state.isTurnActive = false }
    }
    func publishStatus(conversationId: AgentConversationID) {
        guard let status = states[conversationId]?.status(conversationId: conversationId) else {
            return
        }
        statusSubscribers[conversationId]?.values.forEach { $0.yield(status) }
    }
}

extension AgentUsageEvent {
    var endsActiveTurn: Bool {
        guard !isError, permissionDenials.isEmpty else {
            return true
        }
        guard isTerminal || (stopReason != nil && stopReason != Self.interimUsageStopReason) else {
            return false
        }
        return stopReason != "tool_use" && stopReason != "tool_deferred"
    }
}

import Foundation

/// Reconnects the read stream and reconciles snapshots; it never retries prompt or tool mutations.
extension OpenCodeClient {
    func consume(_ initialStream: AsyncThrowingStream<JSONValue, Error>, processToken: UUID) async {
        var stream = initialStream
        var failures = 0
        while !Task.isCancelled, let state = generations[processToken] {
            do {
                for try await payload in stream {
                    try checkLive(processToken)
                    await receive(payload, state: state)
                    if !["server.connected", "server.heartbeat"].contains(payload[oc: "type"]?.ocString ?? "") {
                        failures = 0
                    }
                }
                try Task.checkCancellation()
            } catch is CancellationError { return } catch { /* Recover authoritative state below. */ }
            guard generations[processToken] === state, !Task.isCancelled else { return }
            failures += 1
            guard failures <= 3 else {
                state.failed = true
                finishTurn(state, error: "OpenCode disconnected. Resume this session to continue; interrupted work was not replayed.")
                emit(.lifecycle(AgentLifecycleEvent(state: .failed, message: "OpenCode server disconnected.")), state: state)
                await state.transport.stop()
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(100 * failures))
                stream = try await state.transport.events()
                do {
                    try await reconcileAfterReconnect(state)
                } catch {
                    state.failed = true
                    finishTurn(state, error: "OpenCode session recovery failed. Resume the session before continuing.")
                    emit(.lifecycle(AgentLifecycleEvent(state: .failed, message: "OpenCode session recovery failed.")), state: state)
                    await state.transport.stop()
                    return
                }
            } catch is CancellationError { return } catch { continue }
        }
    }

    private func reconcileAfterReconnect(_ state: OpenCodeGeneration) async throws {
        for attempt in 0..<3 {
            try checkLive(state.context.processToken)
            do {
                try await reconcile(state)
                return
            } catch {
                if attempt == 2 { throw error }
                try await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            }
        }
    }

    func receive(_ payload: JSONValue, state: OpenCodeGeneration) async {
        guard generations[state.context.processToken] === state else { return }
        let type = payload[oc: "type"]?.ocString ?? ""
        let properties = payload[oc: "properties"] ?? .null
        if type == "session.created", let info = properties[oc: "info"] { state.translator.registerChild(info) }
        let sessionID = properties[oc: "sessionID"]?.ocString
            ?? properties[oc: "info"]?[oc: "sessionID"]?.ocString
            ?? properties[oc: "part"]?[oc: "sessionID"]?.ocString
        if type == "message.updated", sessionID == state.sessionID, let info = properties[oc: "info"] {
            observeMessage(info, state: state)
        }
        let expectedAbort = type == "session.error" && state.interrupted
            && properties[oc: "error"]?[oc: "name"]?.ocString == "MessageAbortedError"
        if !expectedAbort {
            for event in state.translator.translate(payload) { emit(event, state: state) }
        }
        if type == "permission.asked" || type == "question.asked" {
            await interaction(type == "permission.asked" ? "permission" : "question", payload: properties, state: state)
        }
        if ["permission.replied", "question.replied", "question.rejected"].contains(type),
           let id = properties[oc: "requestID"]?.ocString {
            state.pendingInteractions[id] = nil
            state.resolvedInteractions.insert(id)
        }
        observeStatus(type, properties: properties, sessionID: sessionID, state: state)
    }

    private func observeStatus(_ type: String, properties: JSONValue, sessionID: String?, state: OpenCodeGeneration) {
        guard sessionID == state.sessionID else { return }
        switch type {
        case "session.status":
            state.nativeStatus = properties[oc: "status"]?[oc: "type"]?.ocString
            if properties[oc: "status"]?[oc: "type"]?.ocString == "busy" {
                if !state.active {
                    state.active = true
                    emit(.activity(AgentActivityEvent(state: .active)), state: state)
                }
            } else if properties[oc: "status"]?[oc: "type"]?.ocString == "idle" { finishIfComplete(state) }
        case "session.idle":
            state.nativeStatus = "idle"
            finishIfComplete(state)
        case "session.error": observeError(properties, state: state)
        case "session.compacted": finishManualCompactionIfComplete(state)
        default: break
        }
    }

    private func observeError(_ properties: JSONValue, state: OpenCodeGeneration) {
        let name = properties[oc: "error"]?[oc: "name"]?.ocString
        if name == "MessageAbortedError", state.interrupted {
            finishTurn(state)
        } else if name != "ContextOverflowError" {
            finishTurn(state, error: "OpenCode could not complete the turn.")
        }
    }

    func observeMessage(_ info: JSONValue, state: OpenCodeGeneration) {
        observeModel(info, state: state)
        guard let id = info[oc: "id"]?.ocString else { return }
        if info[oc: "role"]?.ocString == "user" {
            state.pendingMessageIDs.remove(id)
            if state.active, id >= (state.currentMessageID ?? "") {
                state.currentMessageID = id
                observeCollaborationMode(info, state: state)
            }
            if let message = state.steering.removeValue(forKey: id) {
                var metadata = message.metadata
                metadata[AgentSteeringMetadata.signal] = .string(AgentSteeringMetadata.signalRuntimeInputAccepted)
                metadata["opencode_message_id"] = .string(id)
                emit(.message(AgentMessageEvent(role: .user, text: message.text, metadata: metadata)), state: state)
            }
        } else if info[oc: "time"]?[oc: "completed"] != nil {
            // A denied tool can end an idle turn with finish=tool-calls. Completion is decided
            // by native idle plus the latest user parent, never by a model finish reason alone.
            state.lastFinishedParentID = info[oc: "parentID"]?.ocString
            let error = info[oc: "error"]
            state.lastCompletionError = error == nil || error == .null ? nil
                : error?[oc: "data"]?[oc: "message"]?.ocString ?? "OpenCode could not complete the turn."
        }
    }

    private func observeModel(_ info: JSONValue, state: OpenCodeGeneration) {
        if let provider = info[oc: "providerID"]?.ocString, let model = info[oc: "modelID"]?.ocString {
            state.translator.contextWindow = state.providers[oc: "all"]?.ocArray?
                .first { $0[oc: "id"]?.ocString == provider }?[oc: "models"]?[oc: model]?[oc: "limit"]?[oc: "context"]?.ocInt
        }
    }

    private func observeCollaborationMode(_ info: JSONValue, state: OpenCodeGeneration) {
        guard let agent = info[oc: "agent"]?.ocString, ["build", "plan"].contains(agent) else { return }
        let mode: AgentCollaborationMode = agent == "plan" ? .plan : .default
        guard mode != state.collaborationMode else { return }
        state.collaborationMode = mode
        emit(.collaborationMode(AgentCollaborationModeEvent(mode: mode)), state: state)
    }

    func reconcile(_ state: OpenCodeGeneration, includeHistory: Bool = true) async throws {
        let sessionIDs = try await discoverSessions(state)
        if includeHistory {
            for id in sessionIDs {
                try Self.validateID(id)
                let messages = try await state.transport.request(method: "GET", path: "/session/\(id)/message", body: nil)
                if id == state.sessionID {
                    for message in messages.ocArray ?? [] {
                        if let info = message[oc: "info"] { observeMessage(info, state: state) }
                    }
                }
                for event in state.translator.reconcile(messages: messages.ocArray ?? []) { emit(event, state: state) }
            }
        }
        try await reconcileInteractions(state)
        let statuses = try await state.transport.request(method: "GET", path: "/session/status", body: nil)
        let status = statuses[oc: state.sessionID]?[oc: "type"]?.ocString
        state.nativeStatus = status
        if status == nil || status == "idle" { finishIfComplete(state) }
    }

    func discoverSessions(_ state: OpenCodeGeneration) async throws -> [String] {
        var sessionIDs = [state.sessionID]
        var seen: Set<String> = [state.sessionID]
        var index = 0
        while index < sessionIDs.count {
            let id = sessionIDs[index]
            index += 1
            try Self.validateID(id)
            let children = try await state.transport.request(method: "GET", path: "/session/\(id)/children", body: nil)
            for child in children.ocArray ?? [] {
                state.translator.registerChild(child)
                if let childID = child[oc: "id"]?.ocString, seen.insert(childID).inserted { sessionIDs.append(childID) }
            }
        }
        return sessionIDs
    }

    private func reconcileInteractions(_ state: OpenCodeGeneration) async throws {
        for kind in ["permission", "question"] {
            let pending = try await state.transport.request(method: "GET", path: "/\(kind)", body: nil)
            let requests = (pending.ocArray ?? []).filter { state.translator.contains(sessionID: $0[oc: "sessionID"]?.ocString ?? "") }
            let ids = Set(requests.compactMap { $0[oc: "id"]?.ocString })
            for (id, interaction) in state.pendingInteractions where interaction.kind == kind && !ids.contains(id) {
                state.pendingInteractions[id] = nil
                state.resolvedInteractions.insert(id)
            }
            for request in requests { await interaction(kind, payload: request, state: state) }
        }
    }

    func finishIfComplete(_ state: OpenCodeGeneration) {
        guard state.active, state.pendingMessageIDs.isEmpty, state.pendingInteractions.isEmpty else { return }
        if state.compacting {
            finishManualCompactionIfComplete(state)
            if !state.interrupted { return }
        }
        if state.interrupted || (state.currentMessageID != nil && state.lastFinishedParentID == state.currentMessageID) {
            finishTurn(state, error: state.interrupted ? nil : state.lastCompletionError)
        }
    }

    private func finishManualCompactionIfComplete(_ state: OpenCodeGeneration) {
        guard state.compacting, let compaction = state.translator.compactions[state.sessionID],
              compaction.id != state.priorManualCompactionID,
              state.translator.completedCompactions.contains(compaction.id) else { return }
        state.compacting = false
        finishTurn(state, error: state.lastCompletionError)
    }

    func finishTurn(_ state: OpenCodeGeneration, error: String? = nil) {
        guard state.active else { return }
        state.active = false
        state.currentMessageID = nil
        state.pendingMessageIDs.removeAll()
        state.steering.removeAll()
        for event in state.translator.finishCompaction(sessionID: state.sessionID, error: error ?? "Compaction was interrupted.") {
            emit(event, state: state)
        }
        state.compacting = false
        emit(.usage(AgentUsageEvent(
            model: nil, inputTokens: nil, outputTokens: nil,
            stopReason: error == nil ? "end_turn" : "error", isTerminal: true, isError: error != nil
        )), state: state)
        emit(.activity(AgentActivityEvent(state: .idle)), state: state)
        // Native model errors precede final transcript cleanup; only an unusable generation should stop its server.
        if let error, state.failed { emit(.lifecycle(AgentLifecycleEvent(state: .failed, message: error)), state: state) }
    }
}

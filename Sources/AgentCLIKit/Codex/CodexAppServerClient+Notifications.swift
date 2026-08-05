import Foundation

extension CodexAppServerClient {
    func startIncomingPumpIfNeeded(transport: any CodexAppServerTransport) {
        guard incomingTask == nil else {
            return
        }
        let taskID = UUID()
        let stream = transport.incomingMessages()
        incomingTaskID = taskID
        incomingTask = Task {
            for await message in stream {
                self.handleIncomingMessage(message)
            }
            self.incomingPumpDidFinish(taskID)
        }
    }

    func incomingPumpDidFinish(_ taskID: UUID) {
        guard incomingTaskID == taskID else {
            return
        }
        incomingTask = nil
        incomingTaskID = nil
        if !isShutdown {
            isInitialized = false
        }
    }

    func handleIncomingMessage(_ message: CodexAppServerIncomingMessage) {
        switch message {
        case let .notification(notification):
            handleNotification(notification)
        case let .request(request):
            Task {
                await self.handleServerRequest(request)
            }
        }
    }

    func handleNotification(_ notification: CodexAppServerNotification) {
        guard let threadId = notification.threadId,
              let conversationId = conversationByThreadId[AgentSessionID(rawValue: threadId)],
              var binding = bindingsByConversation[conversationId] else {
            return
        }
        let recoveryTurnId = notification.transcriptPlanRecoveryTurnId ?? binding.activeTurnId
        applyTurnLifecycle(notification, to: &binding, conversationId: conversationId)
        let steeringResult = steeringEvent(for: notification, binding: &binding)
        bindingsByConversation[conversationId] = binding
        recordForwardedPlanItemIfNeeded(notification, conversationId: conversationId)
        if notification.shouldRecoverTranscriptPlanItems {
            recoverTranscriptPlanItems(
                conversationId: conversationId,
                expectedThreadId: binding.threadId,
                targetTurnId: recoveryTurnId,
                processToken: binding.processToken
            )
        }
        if let event = steeringResult.event {
            binding.continuation?.yield(event)
        }
        if !steeringResult.suppressesDecodedEvents {
            for event in notificationDecoder.decode(notification) {
                binding.continuation?.yield(event)
            }
        }
        if notification.shouldRecoverTranscriptPlanItems {
            scheduleTranscriptPlanRecovery(
                conversationId: conversationId,
                expectedThreadId: binding.threadId,
                targetTurnId: recoveryTurnId,
                processToken: binding.processToken
            )
        }
    }

    /// Folds a notification's turn start/complete/idle signals into the binding's active-turn tracking.
    func applyTurnLifecycle(
        _ notification: CodexAppServerNotification,
        to binding: inout ConversationBinding,
        conversationId: AgentConversationID
    ) {
        if let startedTurnId = notification.startedTurnId {
            binding.activeTurnId = startedTurnId
            binding.isTurnSteerReady = true
        } else if notification.marksThreadActive, binding.activeTurnId != nil {
            binding.isTurnSteerReady = true
        }
        if let completedTurnId = notification.completedTurnId {
            if binding.activeTurnId == completedTurnId {
                binding.activeTurnId = nil
            }
            binding.isTurnSteerReady = false
            clearPendingServerRequests(conversationId: conversationId, turnId: completedTurnId)
        }
        if notification.marksThreadIdle {
            binding.activeTurnId = nil
            binding.isTurnSteerReady = false
            clearPendingServerRequests(conversationId: conversationId, turnId: nil)
        }
    }

    func pendingSteeringInput(for message: AgentMessageInput) throws -> PendingSteeringInput? {
        guard message.metadata[AgentSteeringMetadata.isSteering] == .bool(true) else {
            return nil
        }
        guard let inputId = message.metadata.steeringStringValue(AgentSteeringMetadata.inputId) else {
            throw AgentCLIError.invalidInput("Codex steering input requires '\(AgentSteeringMetadata.inputId)' metadata.")
        }
        return PendingSteeringInput(inputId: inputId, text: message.text, metadata: message.metadata)
    }

    func steeringEvent(
        for notification: CodexAppServerNotification,
        binding: inout ConversationBinding
    ) -> (event: AgentProviderRuntimeEvent?, suppressesDecodedEvents: Bool) {
        guard let item = CodexSteeringUserMessageItem(notification: notification) else {
            return (nil, false)
        }
        switch item.phase {
        case "started":
            guard let pending = binding.pendingSteeringInputs.removeValue(forKey: item.inputId) else {
                return (nil, false)
            }
            binding.emittedSteeringInputIds.insert(item.inputId)
            return (
                steeringRuntimeEvent(
                    pending: pending,
                    item: item,
                    signal: AgentSteeringMetadata.signalCodexUserMessageStarted
                ),
                false
            )
        case "completed":
            if binding.emittedSteeringInputIds.remove(item.inputId) != nil {
                return (nil, true)
            }
            guard let pending = binding.pendingSteeringInputs.removeValue(forKey: item.inputId) else {
                return (nil, false)
            }
            return (
                steeringRuntimeEvent(
                    pending: pending,
                    item: item,
                    signal: AgentSteeringMetadata.signalCodexUserMessageCompleted
                ),
                true
            )
        default:
            return (nil, false)
        }
    }

    fileprivate func steeringRuntimeEvent(
        pending: PendingSteeringInput,
        item: CodexSteeringUserMessageItem,
        signal: String
    ) -> AgentProviderRuntimeEvent {
        var metadata = pending.metadata
        metadata.merge(item.metadata) { _, new in new }
        metadata[AgentSteeringMetadata.isSteering] = .bool(true)
        metadata[AgentSteeringMetadata.inputId] = .string(pending.inputId)
        metadata[AgentSteeringMetadata.signal] = .string(signal)
        return AgentProviderRuntimeEvent(event: .message(AgentMessageEvent(role: .user, text: pending.text, metadata: metadata)))
    }

    func clearPendingSteeringInput(_ inputId: String, conversationId: AgentConversationID) {
        guard var binding = bindingsByConversation[conversationId] else {
            return
        }
        binding.pendingSteeringInputs.removeValue(forKey: inputId)
        bindingsByConversation[conversationId] = binding
    }

    func scheduleTranscriptPlanRecovery(
        conversationId: AgentConversationID,
        expectedThreadId: AgentSessionID,
        targetTurnId: String?,
        processToken: UUID
    ) {
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.recoverTranscriptPlanItems(
                conversationId: conversationId,
                expectedThreadId: expectedThreadId,
                targetTurnId: targetTurnId,
                processToken: processToken
            )
        }
    }

    func recoverTranscriptPlanItems(
        conversationId: AgentConversationID,
        expectedThreadId: AgentSessionID,
        targetTurnId: String?,
        processToken: UUID
    ) {
        guard let binding = bindingsByConversation[conversationId],
              binding.threadId == expectedThreadId,
              let targetTurnId,
              binding.processToken == processToken,
              let continuation = binding.continuation else {
            return
        }
        let plans = completedTranscriptPlans(threadId: expectedThreadId).filter { $0.turnId == targetTurnId }
        guard !plans.isEmpty else {
            return
        }
        var recoveredPlanKeys = recoveredPlanKeysByConversation[conversationId] ?? []
        for plan in plans where recoveredPlanKeys.insert(plan.recoveryKey).inserted {
            continuation.yield(plan.runtimeEvent)
        }
        recoveredPlanKeysByConversation[conversationId] = recoveredPlanKeys
    }

    func recordForwardedPlanItemIfNeeded(
        _ notification: CodexAppServerNotification,
        conversationId: AgentConversationID
    ) {
        guard let recoveryKey = notification.completedPlanRecoveryKey else {
            return
        }
        recoveredPlanKeysByConversation[conversationId, default: []].insert(recoveryKey)
    }

    func completedTranscriptPlans(threadId: AgentSessionID) -> [CodexSessionTranscriptPlan] {
        if let sessionFileURL = transcriptPlanSessionFileURLsByThreadId[threadId] {
            return transcriptPlanReader.completedPlans(threadId: threadId, sessionFileURL: sessionFileURL)
        }
        guard let sessionFileURL = transcriptPlanReader.sessionFileURL(threadId: threadId) else {
            return []
        }
        transcriptPlanSessionFileURLsByThreadId[threadId] = sessionFileURL
        return transcriptPlanReader.completedPlans(threadId: threadId, sessionFileURL: sessionFileURL)
    }
}

private struct CodexSteeringUserMessageItem {
    let inputId: String
    let phase: String
    let metadata: [String: JSONValue]

    init?(notification: CodexAppServerNotification) {
        guard let params = notification.params?.steeringObjectValue,
              let phase = notification.steeringItemPhase,
              let threadId = params.steeringStringValue("threadId", "thread_id"),
              let item = params["item"]?.steeringObjectValue,
              item.steeringStringValue("type") == "userMessage",
              let itemId = item.steeringStringValue("id"),
              let inputId = item.steeringStringValue(
                "clientUserMessageId",
                "client_user_message_id",
                "clientId",
                "client_id"
              ) else {
            return nil
        }
        var metadata: [String: JSONValue] = [
            "codex_method": .string(notification.method),
            "codex_thread_id": .string(threadId),
            "codex_item_id": .string(itemId),
            "codex_item_type": .string("userMessage"),
            "codex_item_phase": .string(phase),
            "codex_client_user_message_id": .string(inputId)
        ]
        if let turnId = params.steeringStringValue("turnId", "turn_id") {
            metadata["codex_turn_id"] = .string(turnId)
        }
        if let status = item["status"], status != .null {
            metadata["codex_status"] = status
        }
        if let startedAtMs = params.steeringValue("startedAtMs", "started_at_ms") {
            metadata["started_at_ms"] = startedAtMs
        }
        if let completedAtMs = params.steeringValue("completedAtMs", "completed_at_ms") {
            metadata["completed_at_ms"] = completedAtMs
        }
        self.inputId = inputId
        self.phase = phase
        self.metadata = metadata
    }
}

private extension CodexAppServerNotification {
    var steeringItemPhase: String? {
        switch method {
        case "item/started", "item_started":
            "started"
        case "item/completed", "item_completed":
            "completed"
        default:
            nil
        }
    }
}

private extension [String: JSONValue] {
    func steeringStringValue(_ keys: String...) -> String? {
        keys.lazy.compactMap { key -> String? in
            guard case let .string(value)? = self[key], !value.isEmpty else {
                return nil
            }
            return value
        }.first
    }

    func steeringValue(_ keys: String...) -> JSONValue? {
        keys.lazy.compactMap { self[$0] }.first
    }
}

private extension JSONValue {
    var steeringObjectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }
}

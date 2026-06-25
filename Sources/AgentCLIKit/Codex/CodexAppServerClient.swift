import Foundation

struct CodexThreadBootstrap: Sendable {
    let threadId: AgentSessionID
    let name: String?
    let preview: String?
    let forkedFromId: AgentSessionID?
    let continuity: AgentSessionContinuity
    let goal: AgentGoalSnapshot?
}

actor CodexAppServerClient {
    struct PendingSteeringInput {
        let inputId: String
        let text: String
        let metadata: [String: JSONValue]
    }

    struct ConversationBinding {
        let threadId: AgentSessionID
        let processToken: UUID
        var spawnConfig: AgentSpawnConfig
        var activeTurnId: String?
        var isTurnSteerReady = false
        var initialPromptStarted = false
        var pendingSteeringInputs: [String: PendingSteeringInput] = [:]
        var emittedSteeringInputIds: Set<String> = []
        var continuation: AsyncStream<AgentProviderRuntimeEvent>.Continuation?
    }

    let configuration: CodexProviderAdapter.Configuration
    var transport: (any CodexAppServerTransport)?
    private var incomingTask: Task<Void, Never>?
    private var incomingTaskID: UUID?
    private var isInitialized = false
    var bindingsByConversation: [AgentConversationID: ConversationBinding] = [:]
    var conversationByThreadId: [AgentSessionID: AgentConversationID] = [:]
    var pendingServerRequests: [AgentInteractionID: CodexPendingServerRequest] = [:]
    private let notificationDecoder = CodexAppServerNotificationDecoder()
    private let transcriptPlanReader: CodexSessionTranscriptPlanReader
    let serverRequestMapper: CodexAppServerServerRequestMapper
    let resolutionEncoder = CodexInteractionResolutionEncoder()
    private var recoveredPlanKeysByConversation: [AgentConversationID: Set<CodexSessionTranscriptPlanRecoveryKey>] = [:]
    private var transcriptPlanSessionFileURLsByThreadId: [AgentSessionID: URL] = [:]

    init(configuration: CodexProviderAdapter.Configuration) {
        self.configuration = configuration
        self.serverRequestMapper = CodexAppServerServerRequestMapper(
            commandApprovalNormalizationPolicy: configuration.commandApprovalNormalizationPolicy
        )
        self.transcriptPlanReader = CodexSessionTranscriptPlanReader(
            codexHomeDirectory: configuration.codexHomeDirectory ?? CodexConfigStore.defaultCodexHomeDirectoryURL
        )
    }

    func shutdown() async {
        incomingTask?.cancel()
        incomingTask = nil
        incomingTaskID = nil
        bindingsByConversation.values.forEach { $0.continuation?.finish() }
        bindingsByConversation.removeAll()
        conversationByThreadId.removeAll()
        pendingServerRequests.removeAll()
        recoveredPlanKeysByConversation.removeAll()
        transcriptPlanSessionFileURLsByThreadId.removeAll()
        await transport?.shutdown()
        transport = nil
        isInitialized = false
    }

    func runtimeEvents(context: AgentProviderRuntimeContext) -> AsyncStream<AgentProviderRuntimeEvent> {
        let stream = AsyncStream<AgentProviderRuntimeEvent>.makeStream()
        registerRuntimeEvents(context: context, continuation: stream.continuation)
        stream.continuation.onTermination = { _ in
            Task {
                await self.unregisterRuntimeEvents(context: context)
            }
        }
        return stream.stream
    }

    func send(_ input: AgentInput, context: AgentProviderInputContext) async throws {
        switch input {
        case let .userMessage(message):
            try await send(message, context: context)
        case let .interrupt(interruptInput):
            try await interrupt(context: AgentProviderInterruptContext(
                conversationId: context.conversationId,
                processToken: context.processToken,
                providerSessionId: context.providerSessionId,
                spawnConfig: context.spawnConfig,
                reason: interruptInput.reason
            ))
        case let .interactionResolution(resolution):
            try await resolveInteraction(resolution, context: context)
        }
    }

    func interrupt(context: AgentProviderInterruptContext) async throws {
        guard let binding = binding(for: context.conversationId, processToken: context.processToken),
              let activeTurnId = binding.activeTurnId else {
            return
        }
        do {
            let transport = try await initializedTransport()
            _ = try await transport.sendRequest(
                method: "turn/interrupt",
                params: .object([
                    "threadId": .string(binding.threadId.rawValue),
                    "turnId": .string(activeTurnId)
                ])
            )
        } catch let error as CodexAppServerError {
            guard error.isNoActiveTurnInterrupt else {
                throw error
            }
        }
    }

    func reconfigure(context: AgentProviderReconfigureContext) async throws -> AgentProviderReconfigureResult {
        guard var binding = binding(for: context.conversationId, processToken: context.processToken) else {
            return .restartRequired
        }
        guard !context.isTurnActive, binding.activeTurnId == nil else {
            binding.spawnConfig = context.newConfig
            bindingsByConversation[context.conversationId] = binding
            return .nextTurnRequired
        }
        try await updateThreadSettings(threadId: binding.threadId, spawnConfig: context.newConfig)
        binding.spawnConfig = context.newConfig
        bindingsByConversation[context.conversationId] = binding
        return .appliedInPlace
    }

    func initializedTransport() async throws -> any CodexAppServerTransport {
        let transport = try await transport()
        startIncomingPumpIfNeeded(transport: transport)
        guard !isInitialized else {
            return transport
        }
        _ = try await transport.sendRequest(method: "initialize", params: initializeParams())
        try await transport.sendNotification(method: "initialized", params: nil)
        isInitialized = true
        return transport
    }

    private func registerRuntimeEvents(
        context: AgentProviderRuntimeContext,
        continuation: AsyncStream<AgentProviderRuntimeEvent>.Continuation
    ) {
        guard let threadId = context.providerSessionId else {
            continuation.finish()
            return
        }
        let existing = bindingsByConversation[context.conversationId]
        var binding: ConversationBinding
        if let existing, existing.threadId == threadId, existing.processToken == context.processToken {
            binding = existing
        } else {
            if let existing {
                conversationByThreadId[existing.threadId] = nil
                existing.continuation?.finish()
                pendingServerRequests = pendingServerRequests.filter { $0.value.conversationId != context.conversationId }
                if existing.threadId != threadId {
                    recoveredPlanKeysByConversation[context.conversationId] = nil
                }
            }
            binding = ConversationBinding(
                threadId: threadId,
                processToken: context.processToken,
                spawnConfig: context.spawnConfig
            )
        }
        binding.continuation = continuation
        bindingsByConversation[context.conversationId] = binding
        conversationByThreadId[threadId] = context.conversationId
        Task {
            await self.prepareBindingForInitialPrompt(conversationId: context.conversationId)
        }
    }

    private func unregisterRuntimeEvents(context: AgentProviderRuntimeContext) {
        guard let binding = bindingsByConversation[context.conversationId],
              binding.processToken == context.processToken else {
            return
        }
        conversationByThreadId[binding.threadId] = nil
        bindingsByConversation[context.conversationId] = nil
        pendingServerRequests = pendingServerRequests.filter { $0.value.conversationId != context.conversationId }
    }

    private func prepareBindingForInitialPrompt(conversationId: AgentConversationID) async {
        do {
            try await updateBootstrapThreadSettingsIfNeeded(conversationId: conversationId)
            startInitialPromptIfNeeded(conversationId: conversationId)
        } catch {
            emitDiagnostic(
                error,
                conversationId: conversationId,
                message: "Could not apply Codex thread settings before initial prompt."
            )
        }
    }

    private func startInitialPromptIfNeeded(conversationId: AgentConversationID) {
        guard var binding = bindingsByConversation[conversationId],
              !binding.initialPromptStarted,
              let initialPrompt = binding.spawnConfig.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !initialPrompt.isEmpty else {
            return
        }
        binding.initialPromptStarted = true
        bindingsByConversation[conversationId] = binding
        let attachments = binding.spawnConfig.initialPromptAttachments
        let metadata = binding.spawnConfig.initialPromptMetadata
        Task {
            do {
                try await self.startTurn(
                    message: AgentMessageInput(
                        text: initialPrompt,
                        attachments: attachments,
                        metadata: metadata
                    ),
                    conversationId: conversationId
                )
            } catch {
                self.emitDiagnostic(
                    error,
                    conversationId: conversationId,
                    message: "Could not start Codex initial prompt turn."
                )
            }
        }
    }

    private func send(_ message: AgentMessageInput, context: AgentProviderInputContext) async throws {
        guard let binding = binding(for: context.conversationId, processToken: context.processToken) else {
            throw AgentCLIError.invalidInput("Codex App Server thread is unavailable.")
        }
        if !context.isTurnActive, binding.activeTurnId == nil {
            try await startTurn(message: message, conversationId: context.conversationId)
        } else if binding.isTurnSteerReady, binding.activeTurnId != nil {
            try await steerTurn(message: message, conversationId: context.conversationId)
        } else {
            throw AgentCLIError.invalidInput("Codex active turn is not ready for steering yet.")
        }
    }

    private func startTurn(
        message: AgentMessageInput,
        conversationId: AgentConversationID
    ) async throws {
        guard let binding = bindingsByConversation[conversationId] else {
            throw AgentCLIError.invalidInput("Codex App Server thread is unavailable.")
        }
        let transport = try await initializedTransport()
        try await validateAppshotPolicyIfNeeded(message, transport: transport)
        if message.metadata[AgentGoalMetadata.isInitialGoalTransport] == .bool(true),
           case let .string(objective)? = message.metadata[AgentGoalMetadata.objective],
           !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let supportsGoalMode = await configuration.featureSupportChecker.supportsGoalMode(
                configuration: configuration,
                availability: nil
            )
            guard supportsGoalMode else {
                throw AgentCLIError.unsupportedCapability(
                    providerId: CodexProviderAdapter.providerId,
                    capability: "goal mode"
                )
            }
            if let snapshot = try await setThreadGoal(binding.threadId, objective: objective) {
                bindingsByConversation[conversationId]?.continuation?.yield(
                    AgentProviderRuntimeEvent(event: .goal(AgentGoalEvent(snapshot: snapshot)))
                )
            }
        }
        let supportsFastMode = try await speedModeSupportForSettings(spawnConfig: binding.spawnConfig)
        let response = try await transport.sendRequest(
            method: "turn/start",
            params: try turnStartParams(
                message: message,
                binding: binding,
                includeSettings: true,
                supportsFastMode: supportsFastMode
            )
        )
        guard let turnId = response.turnResponseId else {
            return
        }
        updateActiveTurnId(turnId, conversationId: conversationId)
    }

    private func steerTurn(message: AgentMessageInput, conversationId: AgentConversationID) async throws {
        guard var binding = bindingsByConversation[conversationId] else {
            throw AgentCLIError.invalidInput("Codex App Server thread is unavailable.")
        }
        guard let activeTurnId = binding.activeTurnId else {
            throw AgentCLIError.invalidInput("Codex active turn id is unavailable for steering.")
        }
        let transport = try await initializedTransport()
        try await validateAppshotPolicyIfNeeded(message, transport: transport)
        let pendingSteeringInput = try pendingSteeringInput(for: message)
        if let pendingSteeringInput {
            binding.pendingSteeringInputs[pendingSteeringInput.inputId] = pendingSteeringInput
            bindingsByConversation[conversationId] = binding
        }
        var params: [String: JSONValue] = [
            "threadId": .string(binding.threadId.rawValue),
            "expectedTurnId": .string(activeTurnId),
            "input": try userInputArray(message)
        ]
        if let pendingSteeringInput {
            params["clientUserMessageId"] = .string(pendingSteeringInput.inputId)
        }
        let response: JSONValue
        do {
            response = try await transport.sendRequest(method: "turn/steer", params: .object(params))
        } catch {
            if let pendingSteeringInput {
                clearPendingSteeringInput(pendingSteeringInput.inputId, conversationId: conversationId)
            }
            throw error
        }
        if let turnId = response.turnResponseId ?? response.stringValue("turnId") {
            updateActiveTurnId(turnId, conversationId: conversationId)
        }
    }

    private func startIncomingPumpIfNeeded(transport: any CodexAppServerTransport) {
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

    private func incomingPumpDidFinish(_ taskID: UUID) {
        guard incomingTaskID == taskID else {
            return
        }
        incomingTask = nil
        incomingTaskID = nil
    }

    private func handleIncomingMessage(_ message: CodexAppServerIncomingMessage) {
        switch message {
        case let .notification(notification):
            handleNotification(notification)
        case let .request(request):
            Task {
                await self.handleServerRequest(request)
            }
        }
    }

    private func handleNotification(_ notification: CodexAppServerNotification) {
        guard let threadId = notification.threadId,
              let conversationId = conversationByThreadId[AgentSessionID(rawValue: threadId)],
              var binding = bindingsByConversation[conversationId] else {
            return
        }
        let recoveryTurnId = notification.transcriptPlanRecoveryTurnId ?? binding.activeTurnId
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

    private func pendingSteeringInput(for message: AgentMessageInput) throws -> PendingSteeringInput? {
        guard message.metadata[AgentSteeringMetadata.isSteering] == .bool(true) else {
            return nil
        }
        guard let inputId = message.metadata.steeringStringValue(AgentSteeringMetadata.inputId) else {
            throw AgentCLIError.invalidInput("Codex steering input requires '\(AgentSteeringMetadata.inputId)' metadata.")
        }
        return PendingSteeringInput(inputId: inputId, text: message.text, metadata: message.metadata)
    }

    private func steeringEvent(
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

    private func steeringRuntimeEvent(
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

    private func clearPendingSteeringInput(_ inputId: String, conversationId: AgentConversationID) {
        guard var binding = bindingsByConversation[conversationId] else {
            return
        }
        binding.pendingSteeringInputs.removeValue(forKey: inputId)
        bindingsByConversation[conversationId] = binding
    }

    private func scheduleTranscriptPlanRecovery(
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

    private func recoverTranscriptPlanItems(
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

    private func recordForwardedPlanItemIfNeeded(
        _ notification: CodexAppServerNotification,
        conversationId: AgentConversationID
    ) {
        guard let recoveryKey = notification.completedPlanRecoveryKey else {
            return
        }
        recoveredPlanKeysByConversation[conversationId, default: []].insert(recoveryKey)
    }

    private func completedTranscriptPlans(threadId: AgentSessionID) -> [CodexSessionTranscriptPlan] {
        if let sessionFileURL = transcriptPlanSessionFileURLsByThreadId[threadId] {
            return transcriptPlanReader.completedPlans(threadId: threadId, sessionFileURL: sessionFileURL)
        }
        guard let sessionFileURL = transcriptPlanReader.sessionFileURL(threadId: threadId) else {
            return []
        }
        transcriptPlanSessionFileURLsByThreadId[threadId] = sessionFileURL
        return transcriptPlanReader.completedPlans(threadId: threadId, sessionFileURL: sessionFileURL)
    }

    private func binding(for conversationId: AgentConversationID, processToken: UUID) -> ConversationBinding? {
        guard let binding = bindingsByConversation[conversationId],
              binding.processToken == processToken else {
            return nil
        }
        return binding
    }

    private func updateActiveTurnId(_ turnId: String, conversationId: AgentConversationID) {
        guard var binding = bindingsByConversation[conversationId] else {
            return
        }
        binding.activeTurnId = turnId
        bindingsByConversation[conversationId] = binding
    }

    private func clearPendingServerRequests(conversationId: AgentConversationID, turnId: String?) {
        pendingServerRequests = pendingServerRequests.filter { _, pending in
            guard pending.conversationId == conversationId else {
                return true
            }
            if let turnId {
                return pending.turnId != turnId
            }
            return false
        }
    }

    func emitDiagnostic(_ error: Error, conversationId: AgentConversationID, message: String) {
        bindingsByConversation[conversationId]?.continuation?.yield(AgentProviderRuntimeEvent(event: .diagnostic(AgentDiagnosticEvent(
            code: (error as? CodexAppServerError)?.diagnosticCode,
            severity: .error,
            message: "\(message) \(error.localizedDescription)",
            metadata: ["codex_error": .string(error.localizedDescription)]
        ))))
    }

    private func transport() async throws -> any CodexAppServerTransport {
        if let transport {
            return transport
        }
        let resolvedConfiguration = await configuration.resolvingExecutableIfNeeded(for: CodexProviderDefinition.definition)
        let transport = resolvedConfiguration.makeTransport(resolvedConfiguration)
        try await transport.start()
        self.transport = transport
        return transport
    }

    private func initializeParams() -> JSONValue {
        .object([
            "clientInfo": .object([
                "name": .string("AgentCLIKit"),
                "title": .string("AgentCLIKit"),
                "version": .string("0")
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(configuration.experimentalAPIEnabled),
                "requestAttestation": .bool(false)
            ])
        ])
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

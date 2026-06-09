import Foundation

struct CodexThreadBootstrap: Sendable {
    let threadId: AgentSessionID
    let name: String?
    let preview: String?
    let continuity: AgentSessionContinuity
}

actor CodexAppServerClient {
    struct ConversationBinding {
        let threadId: AgentSessionID
        let processToken: UUID
        var spawnConfig: AgentSpawnConfig
        var activeTurnId: String?
        var isTurnSteerReady = false
        var initialPromptStarted = false
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
    let serverRequestMapper = CodexAppServerServerRequestMapper()
    let resolutionEncoder = CodexInteractionResolutionEncoder()

    init(configuration: CodexProviderAdapter.Configuration) {
        self.configuration = configuration
    }

    func shutdown() async {
        incomingTask?.cancel()
        incomingTask = nil
        incomingTaskID = nil
        bindingsByConversation.values.forEach { $0.continuation?.finish() }
        bindingsByConversation.removeAll()
        conversationByThreadId.removeAll()
        pendingServerRequests.removeAll()
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
        Task {
            do {
                try await self.startTurn(
                    message: AgentMessageInput(text: initialPrompt),
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
        guard let binding = bindingsByConversation[conversationId] else {
            throw AgentCLIError.invalidInput("Codex App Server thread is unavailable.")
        }
        guard let activeTurnId = binding.activeTurnId else {
            throw AgentCLIError.invalidInput("Codex active turn id is unavailable for steering.")
        }
        let transport = try await initializedTransport()
        let response = try await transport.sendRequest(
            method: "turn/steer",
            params: .object([
                "threadId": .string(binding.threadId.rawValue),
                "expectedTurnId": .string(activeTurnId),
                "input": userInputArray(message)
            ])
        )
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
        bindingsByConversation[conversationId] = binding
        for event in notificationDecoder.decode(notification) {
            binding.continuation?.yield(event)
        }
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

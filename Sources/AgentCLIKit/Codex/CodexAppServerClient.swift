import Foundation

struct CodexThreadBootstrap: Sendable {
    let threadId: AgentSessionID
    let continuity: AgentSessionContinuity
}

actor CodexAppServerClient {
    private struct ConversationBinding {
        let threadId: AgentSessionID
        let processToken: UUID
        let spawnConfig: AgentSpawnConfig
        var activeTurnId: String?
        var initialPromptStarted = false
        var continuation: AsyncStream<AgentProviderRuntimeEvent>.Continuation?
    }

    private let configuration: CodexProviderAdapter.Configuration
    private var transport: (any CodexAppServerTransport)?
    private var incomingTask: Task<Void, Never>?
    private var incomingTaskID: UUID?
    private var isInitialized = false
    private var bindingsByConversation: [AgentConversationID: ConversationBinding] = [:]
    private var conversationByThreadId: [AgentSessionID: AgentConversationID] = [:]
    private let notificationDecoder = CodexAppServerNotificationDecoder()

    init(configuration: CodexProviderAdapter.Configuration) {
        self.configuration = configuration
    }

    func bootstrapThread(spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?) async throws -> CodexThreadBootstrap {
        let transport = try await initializedTransport()
        let method = resumedSession == nil ? "thread/start" : "thread/resume"
        let response = try await transport.sendRequest(
            method: method,
            params: threadParams(spawnConfig: spawnConfig, resumedSession: resumedSession)
        )
        guard let threadId = response.threadResponseId else {
            throw CodexAppServerError.missingThreadID(method: method)
        }
        return CodexThreadBootstrap(
            threadId: AgentSessionID(rawValue: threadId),
            continuity: resumedSession == nil ? .fresh : .resumed
        )
    }

    func shutdown() async {
        incomingTask?.cancel()
        incomingTask = nil
        incomingTaskID = nil
        bindingsByConversation.values.forEach { $0.continuation?.finish() }
        bindingsByConversation.removeAll()
        conversationByThreadId.removeAll()
        await transport?.shutdown()
        transport = nil
        isInitialized = false
    }

    nonisolated func runtimeEvents(context: AgentProviderRuntimeContext) -> AsyncStream<AgentProviderRuntimeEvent> {
        AsyncStream { continuation in
            Task {
                await self.registerRuntimeEvents(context: context, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.unregisterRuntimeEvents(context: context)
                }
            }
        }
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
        case .interactionResolution:
            throw AgentCLIError.invalidInput("Codex interaction resolution is not implemented yet.")
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

    private func initializedTransport() async throws -> any CodexAppServerTransport {
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
        startInitialPromptIfNeeded(conversationId: context.conversationId)
    }

    private func unregisterRuntimeEvents(context: AgentProviderRuntimeContext) {
        guard let binding = bindingsByConversation[context.conversationId],
              binding.processToken == context.processToken else {
            return
        }
        conversationByThreadId[binding.threadId] = nil
        bindingsByConversation[context.conversationId] = nil
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
                    conversationId: conversationId,
                    isInitialPrompt: true
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
        if context.isTurnActive || binding.activeTurnId != nil {
            try await steerTurn(message: message, conversationId: context.conversationId)
        } else {
            try await startTurn(message: message, conversationId: context.conversationId, isInitialPrompt: false)
        }
    }

    private func startTurn(
        message: AgentMessageInput,
        conversationId: AgentConversationID,
        isInitialPrompt: Bool
    ) async throws {
        guard let binding = bindingsByConversation[conversationId] else {
            throw AgentCLIError.invalidInput("Codex App Server thread is unavailable.")
        }
        let transport = try await initializedTransport()
        let response = try await transport.sendRequest(
            method: "turn/start",
            params: turnStartParams(message: message, binding: binding, includeSettings: !isInitialPrompt)
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
            handleUnsupportedServerRequest(request)
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
        }
        if let completedTurnId = notification.completedTurnId,
           binding.activeTurnId == completedTurnId {
            binding.activeTurnId = nil
        }
        if notification.marksThreadIdle {
            binding.activeTurnId = nil
        }
        bindingsByConversation[conversationId] = binding
        for event in notificationDecoder.decode(notification) {
            binding.continuation?.yield(event)
        }
    }

    private func handleUnsupportedServerRequest(_ request: CodexAppServerRequest) {
        guard let threadId = request.threadId,
              let conversationId = conversationByThreadId[AgentSessionID(rawValue: threadId)],
              let continuation = bindingsByConversation[conversationId]?.continuation else {
            return
        }
        continuation.yield(AgentProviderRuntimeEvent(event: .diagnostic(AgentDiagnosticEvent(
            code: .codexAppServerResponseFailure,
            severity: .warning,
            message: "Codex App Server request '\(request.method)' is not implemented yet.",
            metadata: [
                "codex_method": .string(request.method),
                "codex_thread_id": .string(threadId)
            ]
        ))))
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

    private func emitDiagnostic(_ error: Error, conversationId: AgentConversationID, message: String) {
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
        let transport = configuration.makeTransport(configuration)
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

    private func threadParams(spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(spawnConfig.workingDirectory.path)
        ]
        if let resumedSession {
            params["threadId"] = .string(resumedSession.providerSessionId.rawValue)
        } else {
            params["ephemeral"] = .bool(false)
        }
        if let model = spawnConfig.model {
            params["model"] = .string(model)
        }
        if let permissionMode = spawnConfig.permissionMode {
            params["approvalPolicy"] = .string(permissionMode)
        }
        if let effort = spawnConfig.effort {
            params["config"] = .object(["model_reasoning_effort": .string(effort)])
        }
        return .object(params)
    }

    private func turnStartParams(message: AgentMessageInput, binding: ConversationBinding, includeSettings: Bool) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(binding.threadId.rawValue),
            "input": userInputArray(message)
        ]
        if includeSettings {
            params["cwd"] = .string(binding.spawnConfig.workingDirectory.path)
            if let model = binding.spawnConfig.model {
                params["model"] = .string(model)
            }
            if let permissionMode = binding.spawnConfig.permissionMode {
                params["approvalPolicy"] = .string(permissionMode)
            }
            if let effort = binding.spawnConfig.effort {
                params["effort"] = .string(effort)
            }
        }
        return .object(params)
    }

    private func userInputArray(_ message: AgentMessageInput) -> JSONValue {
        .array([.object([
            "type": .string("text"),
            "text": .string(message.text),
            "text_elements": .array([])
        ])])
    }
}

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
    struct TransportStartOperation {
        let id: UUID
        let task: Task<any CodexAppServerTransport, Error>
    }

    struct InitializationOperation {
        let id: UUID
        let task: Task<any CodexAppServerTransport, Error>
    }

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
    var transportStartOperation: TransportStartOperation?
    var initializationOperation: InitializationOperation?
    var incomingTask: Task<Void, Never>?
    var incomingTaskID: UUID?
    var isInitialized = false
    var isShutdown = false
    var isShutdownComplete = false
    var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    var bindingsByConversation: [AgentConversationID: ConversationBinding] = [:]
    var conversationByThreadId: [AgentSessionID: AgentConversationID] = [:]
    var pendingServerRequests: [AgentInteractionID: CodexPendingServerRequest] = [:]
    var notificationDecoder = CodexAppServerNotificationDecoder()
    let transcriptPlanReader: CodexSessionTranscriptPlanReader
    let serverRequestMapper: CodexAppServerServerRequestMapper
    let resolutionEncoder = CodexInteractionResolutionEncoder()
    var recoveredPlanKeysByConversation: [AgentConversationID: Set<CodexSessionTranscriptPlanRecoveryKey>] = [:]
    var transcriptPlanSessionFileURLsByThreadId: [AgentSessionID: URL] = [:]

    init(configuration: CodexProviderAdapter.Configuration) {
        self.configuration = configuration
        self.serverRequestMapper = CodexAppServerServerRequestMapper(
            commandApprovalNormalizationPolicy: configuration.commandApprovalNormalizationPolicy
        )
        self.transcriptPlanReader = CodexSessionTranscriptPlanReader(
            codexHomeDirectory: configuration.codexHomeDirectory ?? CodexConfigStore.defaultCodexHomeDirectoryURL
        )
    }

    func runtimeEvents(context: AgentProviderRuntimeContext) -> AsyncStream<AgentProviderRuntimeEvent> {
        let stream = AsyncStream<AgentProviderRuntimeEvent>.makeStream()
        guard !isShutdown else {
            stream.continuation.finish()
            return stream.stream
        }
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
        if context.currentConfig.hostTools != context.newConfig.hostTools ||
            context.currentConfig.hostToolServer != context.newConfig.hostToolServer ||
            context.currentConfig.additionalWorkspaceRoots != context.newConfig.additionalWorkspaceRoots {
            return context.isTurnActive || binding.activeTurnId != nil ? .nextTurnRequired : .restartRequired
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

    func clearPendingServerRequests(conversationId: AgentConversationID, turnId: String?) {
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

}

import Foundation

extension DefaultAgentRuntime {
    func start(conversationId: AgentConversationID, config: AgentSpawnConfig, fresh: Bool) async throws {
        let startToken = try claimStart(conversationId: conversationId)
        let processToken = UUID()
        defer {
            releaseStart(conversationId: conversationId, startToken: startToken)
            untrackInFlightStart(conversationId: conversationId, processToken: processToken)
        }

        let prepared = try await prepareStart(
            conversationId: conversationId,
            config: config,
            fresh: fresh,
            startToken: startToken,
            processToken: processToken
        )
        try await installPreparedProcess(prepared, startToken: startToken)
        untrackInFlightStart(conversationId: conversationId, processToken: processToken)
        try await ensureStartIsCurrent(prepared, startToken: startToken)

        emitInitialPromptPreviewIfNeeded(prepared)
        emitLifecycle(.running, conversationId: conversationId)
        emitSessionContinuity(
            prepared.launch.sessionContinuity,
            providerSessionId: prepared.launch.providerSessionId ?? prepared.resumedSession?.providerSessionId,
            conversationId: conversationId
        )
        try await sendInitialPromptOverStdinIfNeeded(prepared)
        pump(
            prepared.preparedProcess.stdout.fileHandleForReading,
            source: .stdout,
            conversationId: conversationId,
            processToken: prepared.stateInput.processToken
        )
        pump(
            prepared.preparedProcess.stderr.fileHandleForReading,
            source: .stderr,
            conversationId: conversationId,
            processToken: prepared.stateInput.processToken
        )
        installTerminationHandler(
            prepared.preparedProcess.process,
            conversationId: conversationId,
            processToken: prepared.stateInput.processToken
        )
        await startProviderRuntimeEvents(conversationId: conversationId, processToken: prepared.stateInput.processToken)
        try await ensureStartIsCurrent(prepared, startToken: startToken)
    }

    func cancelStart(conversationId: AgentConversationID) {
        if let startToken = startTokens[conversationId] {
            cancelledStartTokens.insert(startToken)
            // Explicit destruction must remain authoritative over an earlier recoverable listener failure.
            startCancellationErrors[startToken] = nil
        }
    }

    func cancelAllStarts() {
        let activeStartTokens = startTokens.values
        cancelledStartTokens.formUnion(activeStartTokens)
        activeStartTokens.forEach { startCancellationErrors[$0] = nil }
    }

    func cancelStartForHostToolFailure(
        conversationId: AgentConversationID,
        reason: String
    ) {
        guard let startToken = startTokens[conversationId],
              !cancelledStartTokens.contains(startToken) else {
            // Never convert a host-requested cancellation into a retryable integration failure.
            return
        }
        cancelledStartTokens.insert(startToken)
        startCancellationErrors[startToken] = .hostToolsUnavailable(reason: reason)
    }
}

extension DefaultAgentRuntime {
    func prepareStart(
        conversationId: AgentConversationID,
        config: AgentSpawnConfig,
        fresh: Bool,
        startToken: UUID,
        processToken: UUID
    ) async throws -> PreparedStart {
        guard let adapter = adapters[config.providerId] else {
            throw AgentCLIError.providerNotRegistered(config.providerId)
        }

        let previous = states[conversationId]
        let generation = fresh ? (previous?.generation ?? 0) + 1 : max(previous?.generation ?? 0, 1)
        let resumedSession = fresh ? nil : try await sessionStore.record(conversationId: conversationId, providerId: config.providerId)
        trackInFlightStart(conversationId: conversationId, adapter: adapter, processToken: processToken)
        let launchInput = BaseLaunchInput(
            conversationId: conversationId,
            config: config,
            adapter: adapter,
            resumedSession: resumedSession,
            processToken: processToken,
            startToken: startToken
        )
        let baseLaunch = try await makeBaseLaunch(input: launchInput)

        let launch = try await prepareLaunch(
            baseLaunch,
            adapter: adapter,
            config: config,
            conversationId: conversationId,
            processToken: processToken
        )
        try await ensureStartIsCurrent(
            conversationId: conversationId,
            startToken: startToken,
            adapter: adapter,
            processToken: processToken
        )

        return makePreparedStart(
            launch: launch,
            previous: previous,
            generation: generation,
            fresh: fresh,
            input: launchInput
        )
    }

    func makeBaseLaunch(input: BaseLaunchInput) async throws -> AgentLaunchConfiguration {
        try ensureStartIsCurrent(conversationId: input.conversationId, startToken: input.startToken)
        try input.config.validateAdditionalWorkspaceRoots()
        let endpoint = try await registerHostToolsIfNeeded(
            conversationId: input.conversationId,
            config: input.config,
            processToken: input.processToken
        )
        registerSensitiveValues(endpoint.map { [$0.bearerToken] } ?? [], processToken: input.processToken)
        let launch: AgentLaunchConfiguration
        do {
            launch = try await input.adapter.makeLaunchConfiguration(context: AgentProviderLaunchContext(
                conversationId: input.conversationId,
                processToken: input.processToken,
                spawnConfig: input.config,
                resumedSession: input.resumedSession,
                hostToolEndpoint: endpoint
            ))
        } catch {
            await invalidateTrackedStartResources(
                conversationId: input.conversationId,
                adapter: input.adapter,
                processToken: input.processToken
            )
            throw error
        }
        try await ensureStartIsCurrent(
            conversationId: input.conversationId,
            startToken: input.startToken,
            adapter: input.adapter,
            processToken: input.processToken
        )
        return launch
    }

    func makePreparedStart(
        launch: AgentLaunchConfiguration,
        previous: ConversationState?,
        generation: Int,
        fresh: Bool,
        input: BaseLaunchInput
    ) -> PreparedStart {
        let preparedProcess = makeProcess(launch: launch, config: input.config)
        let stateInput = StateInput(
            conversationId: input.conversationId,
            providerId: input.config.providerId,
            generation: generation,
            processToken: input.processToken,
            adapter: input.adapter,
            preparedProcess: preparedProcess,
            spawnConfig: input.config,
            resumedSession: input.resumedSession,
            launchProviderSessionId: launch.providerSessionId,
            fresh: fresh
        )
        return PreparedStart(
            launch: launch,
            preparedProcess: preparedProcess,
            previous: previous,
            stateInput: stateInput,
            adapter: input.adapter,
            resumedSession: input.resumedSession
        )
    }

    func claimStart(conversationId: AgentConversationID) throws -> UUID {
        guard !isShutdown else {
            throw AgentCLIError.invalidInput("Runtime has shut down.")
        }
        guard startTokens[conversationId] == nil else {
            throw AgentCLIError.invalidInput("Start already in progress for conversation '\(conversationId.rawValue)'.")
        }
        let startToken = UUID()
        startTokens[conversationId] = startToken
        return startToken
    }

    func releaseStart(conversationId: AgentConversationID, startToken: UUID) {
        guard startTokens[conversationId] == startToken else {
            return
        }
        startTokens.removeValue(forKey: conversationId)
        cancelledStartTokens.remove(startToken)
        startCancellationErrors[startToken] = nil
    }

    func ensureStartIsCurrent(conversationId: AgentConversationID, startToken: UUID) throws {
        guard isStartCurrent(conversationId: conversationId, startToken: startToken) else {
            throw startCancelledError(conversationId: conversationId, startToken: startToken)
        }
    }

    func ensureStartIsCurrent(
        conversationId: AgentConversationID,
        startToken: UUID,
        adapter: any AgentProviderAdapter,
        processToken: UUID,
        process: Process? = nil
    ) async throws {
        guard isStartCurrent(conversationId: conversationId, startToken: startToken) else {
            forceKill(process)
            await invalidateTrackedStartResources(
                conversationId: conversationId,
                adapter: adapter,
                processToken: processToken
            )
            throw startCancelledError(conversationId: conversationId, startToken: startToken)
        }
    }

    func ensureStartIsCurrent(_ prepared: PreparedStart, startToken: UUID) async throws {
        try await ensureStartIsCurrent(
            conversationId: prepared.stateInput.conversationId,
            startToken: startToken,
            adapter: prepared.adapter,
            processToken: prepared.stateInput.processToken,
            process: prepared.preparedProcess.process
        )
    }

    func startCancelledError(
        conversationId: AgentConversationID,
        startToken: UUID
    ) -> AgentCLIError {
        startCancellationErrors[startToken]
            ?? AgentCLIError.invalidInput("Start was cancelled for conversation '\(conversationId.rawValue)'.")
    }

    func isStartCurrent(conversationId: AgentConversationID, startToken: UUID) -> Bool {
        startTokens[conversationId] == startToken && !cancelledStartTokens.contains(startToken)
    }

    func prepareLaunch(
        _ launch: AgentLaunchConfiguration,
        adapter: any AgentProviderAdapter,
        config: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        do {
            return try await adapter.prepareLaunchConfiguration(
                launch,
                spawnConfig: config,
                conversationId: conversationId,
                processToken: processToken
            )
        } catch {
            await invalidateTrackedStartResources(
                conversationId: conversationId,
                adapter: adapter,
                processToken: processToken
            )
            // Launch augmentation runs before conversation state exists, so fail rather than silently drop provider-managed resources.
            throw error
        }
    }

}

struct PreparedStart {
    let launch: AgentLaunchConfiguration
    let preparedProcess: PreparedProcess
    let previous: ConversationState?
    let stateInput: StateInput
    let adapter: any AgentProviderAdapter
    let resumedSession: AgentSessionRecord?
}

struct BaseLaunchInput {
    let conversationId: AgentConversationID
    let config: AgentSpawnConfig
    let adapter: any AgentProviderAdapter
    let resumedSession: AgentSessionRecord?
    let processToken: UUID
    let startToken: UUID
}

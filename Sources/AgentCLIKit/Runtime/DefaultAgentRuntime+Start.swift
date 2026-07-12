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
        }
    }

    func cancelAllStarts() {
        cancelledStartTokens.formUnion(startTokens.values)
    }
}

private extension DefaultAgentRuntime {
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
    }

    func ensureStartIsCurrent(conversationId: AgentConversationID, startToken: UUID) throws {
        guard isStartCurrent(conversationId: conversationId, startToken: startToken) else {
            throw startCancelledError(conversationId: conversationId)
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
            throw startCancelledError(conversationId: conversationId)
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

    func startCancelledError(conversationId: AgentConversationID) -> AgentCLIError {
        AgentCLIError.invalidInput("Start was cancelled for conversation '\(conversationId.rawValue)'.")
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

    func installPreparedProcess(_ prepared: PreparedStart, startToken: UUID) async throws {
        try ensureStartIsCurrent(conversationId: prepared.stateInput.conversationId, startToken: startToken)
        if prepared.previous?.process?.isRunning == true {
            try await replaceRunningProcess(prepared, startToken: startToken)
        } else {
            try await installProcessWithoutRunningPrevious(prepared, startToken: startToken)
        }
    }

    func replaceRunningProcess(_ prepared: PreparedStart, startToken: UUID) async throws {
        let process = prepared.preparedProcess.process
        let previous = prepared.previous
        let stateInput = prepared.stateInput
        let adapter = prepared.adapter

        // Keep the current session alive until the replacement process has definitely launched.
        try await runPreparedProcess(process, launch: prepared.launch, stateInput: stateInput, adapter: adapter, recordsFailure: false)
        try await ensureStartIsCurrent(
            conversationId: stateInput.conversationId,
            startToken: startToken,
            adapter: adapter,
            processToken: stateInput.processToken,
            process: process
        )

        // The replacement is now live; delayed save completions from the old process should no longer report diagnostics.
        markProviderSessionSavesStale(conversationId: stateInput.conversationId, processToken: previous?.processToken)
        await waitForPreviousOutputQueuesToBecomeIdle(previous)
        try await ensureStartIsCurrent(
            conversationId: stateInput.conversationId,
            startToken: startToken,
            adapter: adapter,
            processToken: stateInput.processToken,
            process: process
        )
        let latestPrevious = states[stateInput.conversationId] ?? previous
        let oldProcess = latestPrevious?.process

        // Swap tokens before retiring redaction or terminating the previous process so trailing output is ignored.
        states[stateInput.conversationId] = makeState(input: stateInput, previous: latestPrevious)
        untrackInFlightStart(conversationId: stateInput.conversationId, processToken: stateInput.processToken)
        emitLifecycle(.starting, conversationId: stateInput.conversationId)
        forceKill(oldProcess)
        await invalidatePreviousProcessToken(latestPrevious)
    }

    func waitForPreviousOutputQueuesToBecomeIdle(_ previous: ConversationState?) async {
        guard let previous else {
            return
        }
        for pump in previous.outputPumps {
            await pump.waitUntilIdle(timeoutNanoseconds: outputDrainTimeoutNanoseconds, sleep: sleep)
        }
    }

    func installProcessWithoutRunningPrevious(_ prepared: PreparedStart, startToken: UUID) async throws {
        let process = prepared.preparedProcess.process
        let previous = prepared.previous
        let stateInput = prepared.stateInput
        let adapter = prepared.adapter

        let oldProcess = previous?.process
        // Swap tokens before retiring redaction or cleaning up the previous process so trailing output is ignored.
        states[stateInput.conversationId] = makeState(input: stateInput, previous: previous)
        untrackInFlightStart(conversationId: stateInput.conversationId, processToken: stateInput.processToken)
        emitLifecycle(.starting, conversationId: stateInput.conversationId)
        forceKill(oldProcess)
        do {
            try await runPreparedProcess(process, launch: prepared.launch, stateInput: stateInput, adapter: adapter, recordsFailure: true)
        } catch {
            await invalidatePreviousProcessToken(previous)
            throw error
        }
        await invalidatePreviousProcessToken(previous)
    }

    func runPreparedProcess(
        _ process: Process,
        launch: AgentLaunchConfiguration,
        stateInput: StateInput,
        adapter: any AgentProviderAdapter,
        recordsFailure: Bool
    ) async throws {
        do {
            try runProcess(process, launch: launch, conversationId: stateInput.conversationId, recordsFailure: recordsFailure)
        } catch {
            await invalidateProcessResources(adapter: adapter, processToken: stateInput.processToken)
            throw error
        }
    }

    func invalidatePreviousProcessToken(_ previous: ConversationState?) async {
        guard let previous else {
            return
        }
        previous.providerEventTasks.forEach { $0.cancel() }
        await invalidateProcessResources(adapter: previous.adapter, processToken: previous.processToken)
    }

    func makeState(input: StateInput, previous: ConversationState?) -> ConversationState {
        // Fresh generations restart event indexes, so the persisted cursor is only reusable for continued sessions.
        let persistedIndex = input.fresh ? -1 : previous?.persistedIndex ?? -1
        // Claude can replay transcript frames when a deferred tool approval resumes the provider session.
        let providerResumeReplayGate = providerResumeReplayGate(input: input, previous: previous)
        return ConversationState(
            providerId: input.providerId,
            generation: input.generation,
            processToken: input.processToken,
            adapter: input.adapter,
            spawnConfig: input.spawnConfig,
            process: input.preparedProcess.process,
            stdin: input.preparedProcess.stdin.fileHandleForWriting,
            stdinWriter: StdinWriteQueue(),
            events: previous?.events.filter { $0.generation == input.generation } ?? [],
            subscribers: previous?.subscribers ?? pendingSubscribers.removeValue(forKey: input.conversationId) ?? [:],
            stderrTail: [],
            lifecycleState: .starting,
            providerSessionId: input.launchProviderSessionId ?? input.resumedSession?.providerSessionId,
            providerSessionName: normalizedProviderSessionName(input.resumedSession?.providerSessionName),
            providerSessionPreview: normalizedProviderSessionPreview(input.resumedSession?.providerSessionPreview),
            providerSessionRecordMetadata: input.resumedSession?.metadata ?? ["source": .string("runtime")],
            providerSessionCreatedAt: input.resumedSession?.createdAt,
            staleProviderSessionSaveProcessTokens: previous?.staleProviderSessionSaveProcessTokens ?? [],
            permissionMode: nil,
            collaborationMode: input.spawnConfig.collaborationMode,
            goal: seededInitialGoal(from: input) ?? (input.fresh ? nil : previous?.goal),
            isTurnActive: input.spawnConfig.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            waitingState: .idle,
            inputAvailability: .available,
            resolvedInteractions: input.fresh ? [] : previous?.resolvedInteractions ?? [],
            runtimePlanExitInteractions: input.fresh ? [:] : previous?.runtimePlanExitInteractions ?? [:],
            pendingPlanImplementationStart: input.fresh ? nil : previous?.pendingPlanImplementationStart,
            completedPlanImplementationKeys: input.fresh ? [] : previous?.completedPlanImplementationKeys ?? [],
            synthesizedPlanExitProposalKeys: input.fresh ? [] : previous?.synthesizedPlanExitProposalKeys ?? [],
            persistedIndex: persistedIndex,
            hasDeferredToolStop: false,
            providerResumeReplayGate: providerResumeReplayGate,
            contextCompactionStartedIds: Self.contextCompactionStartedIds(from: previous, generation: input.generation),
            contextCompactionOpenIds: Self.contextCompactionOpenIds(from: previous, generation: input.generation),
            contextCompactionTerminalIds: Self.contextCompactionTerminalIds(from: previous, generation: input.generation),
            contextCompactionPhaseKeys: Self.contextCompactionPhaseKeys(from: previous, generation: input.generation),
            subAgentStartedIds: Self.subAgentStartedIds(from: previous, generation: input.generation),
            subAgentOpenIds: Self.subAgentOpenIds(from: previous, generation: input.generation),
            subAgentTerminalIds: Self.subAgentTerminalIds(from: previous, generation: input.generation),
            subAgentPhaseKeys: Self.subAgentPhaseKeys(from: previous, generation: input.generation),
            outputPumps: [],
            providerEventTasks: []
        )
    }

    private func seededInitialGoal(from input: StateInput) -> AgentGoalSnapshot? {
        guard let objective = input.spawnConfig.initialGoal?.trimmingCharacters(in: .whitespacesAndNewlines),
              input.spawnConfig.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              !objective.isEmpty else {
            return nil
        }
        let activeActions = input.adapter.definition.capabilities.supportedGoalActions.filter { $0 != .resume }
        return AgentGoalSnapshot(
            objective: objective,
            status: .active,
            availableActions: activeActions,
            metadata: ["source": .string("initial_goal")]
        )
    }

    func markProviderSessionSavesStale(conversationId: AgentConversationID, processToken: UUID?) {
        guard let processToken else {
            return
        }
        states[conversationId]?.staleProviderSessionSaveProcessTokens.insert(processToken)
    }

    private static func contextCompactionStartedIds(from previous: ConversationState?, generation: Int) -> Set<String> {
        Set(previous?.events.compactMap { envelope -> String? in
            guard envelope.generation == generation,
                  case let .contextCompaction(compaction) = envelope.event,
                  compaction.phase == .started else {
                return nil
            }
            return compaction.id
        } ?? [])
    }

    private static func contextCompactionOpenIds(from previous: ConversationState?, generation: Int) -> Set<String> {
        var openIds = Set<String>()
        for envelope in previous?.events ?? [] {
            guard envelope.generation == generation,
                  case let .contextCompaction(compaction) = envelope.event else {
                continue
            }
            switch compaction.phase {
            case .started:
                openIds.insert(compaction.id)
            case .completed, .failed:
                openIds.remove(compaction.id)
            }
        }
        return openIds
    }

    private static func contextCompactionTerminalIds(from previous: ConversationState?, generation: Int) -> Set<String> {
        Set(previous?.events.compactMap { envelope -> String? in
            guard envelope.generation == generation,
                  case let .contextCompaction(compaction) = envelope.event,
                  compaction.phase.isTerminal else {
                return nil
            }
            return compaction.id
        } ?? [])
    }

    private static func contextCompactionPhaseKeys(from previous: ConversationState?, generation: Int) -> Set<String> {
        Set(previous?.events.compactMap { envelope -> String? in
            guard envelope.generation == generation,
                  case let .contextCompaction(compaction) = envelope.event else {
                return nil
            }
            return Self.contextCompactionPhaseKey(compaction)
        } ?? [])
    }

    private static func subAgentStartedIds(from previous: ConversationState?, generation: Int) -> Set<String> {
        Set(previous?.events.compactMap { envelope -> String? in
            guard envelope.generation == generation,
                  case let .subAgent(subAgent) = envelope.event,
                  subAgent.phase == .started else {
                return nil
            }
            return subAgent.id
        } ?? [])
    }

    private static func subAgentOpenIds(from previous: ConversationState?, generation: Int) -> Set<String> {
        var openIds = Set<String>()
        for envelope in previous?.events ?? [] {
            guard envelope.generation == generation,
                  case let .subAgent(subAgent) = envelope.event else {
                continue
            }
            switch subAgent.phase {
            case .started, .progress:
                openIds.insert(subAgent.id)
            case .terminal:
                openIds.remove(subAgent.id)
            }
        }
        return openIds
    }

    private static func subAgentTerminalIds(from previous: ConversationState?, generation: Int) -> Set<String> {
        Set(previous?.events.compactMap { envelope -> String? in
            guard envelope.generation == generation,
                  case let .subAgent(subAgent) = envelope.event,
                  subAgent.phase.isTerminal else {
                return nil
            }
            return subAgent.id
        } ?? [])
    }

    private static func subAgentPhaseKeys(from previous: ConversationState?, generation: Int) -> Set<String> {
        Set(previous?.events.compactMap { envelope -> String? in
            guard envelope.generation == generation,
                  case let .subAgent(subAgent) = envelope.event else {
                return nil
            }
            return Self.subAgentPhaseKey(subAgent)
        } ?? [])
    }

    func providerResumeReplayGate(input: StateInput, previous: ConversationState?) -> ProviderResumeReplayGate? {
        guard !input.fresh, previous?.hasDeferredToolStop == true, let previous else {
            return nil
        }
        return ProviderResumeReplayGate(previous.events.filter { $0.generation == input.generation })
    }

    func emitInitialPromptPreviewIfNeeded(_ prepared: PreparedStart) {
        guard prepared.resumedSession == nil,
              let initialPrompt = prepared.stateInput.spawnConfig.initialPrompt,
              let preview = AgentSessionPreviewGenerator.preview(fromInitialPrompt: initialPrompt) else {
            return
        }
        append(
            .sessionMetadata(
                providerSessionId: prepared.launch.providerSessionId,
                preview: preview,
                metadata: ["source": .string("initial_prompt")]
            ),
            source: .runtime,
            conversationId: prepared.stateInput.conversationId
        )
    }

    func runProcess(
        _ process: Process,
        launch: AgentLaunchConfiguration,
        conversationId: AgentConversationID,
        recordsFailure: Bool
    ) throws {
        do {
            try process.run()
        } catch {
            if recordsFailure {
                emitLifecycle(.failed, conversationId: conversationId, message: error.localizedDescription)
                states[conversationId]?.process = nil
                states[conversationId]?.stdin = nil
                states[conversationId]?.stdinWriter = nil
            }
            throw AgentCLIError.commandLaunchFailed(executable: launch.executable, reason: error.localizedDescription)
        }
    }

    func installTerminationHandler(
        _ process: Process,
        conversationId: AgentConversationID,
        processToken: UUID
    ) {
        process.terminationHandler = { [weak process] terminatedProcess in
            let exitCode = process?.terminationStatus ?? terminatedProcess.terminationStatus
            Task { await self.processExited(conversationId: conversationId, processToken: processToken, exitCode: exitCode) }
        }
        // A very short-lived process can terminate before its handler is installed.
        if !process.isRunning {
            Task { await self.processExited(conversationId: conversationId, processToken: processToken, exitCode: process.terminationStatus) }
        }
    }

    func sendInitialPromptOverStdinIfNeeded(_ prepared: PreparedStart) async throws {
        guard prepared.launch.sendsInitialPromptOverStdin,
              let initialPrompt = prepared.stateInput.spawnConfig.initialPrompt,
              !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        do {
            let context = AgentProviderInputContext(
                conversationId: prepared.stateInput.conversationId,
                processToken: prepared.stateInput.processToken,
                providerSessionId: prepared.launch.providerSessionId ?? prepared.resumedSession?.providerSessionId,
                spawnConfig: prepared.stateInput.spawnConfig,
                isTurnActive: true
            )
            let data = try await prepared.adapter.encodeInput(
                .userMessage(initialPromptInput(initialPrompt, spawnConfig: prepared.stateInput.spawnConfig)),
                context: context
            )
            try writeInputData(
                data,
                conversationId: prepared.stateInput.conversationId,
                processToken: prepared.stateInput.processToken,
                marksTurnActive: false
            )
        } catch {
            emitLifecycle(
                .failed,
                conversationId: prepared.stateInput.conversationId,
                message: "Could not write initial provider input: \(error.localizedDescription)"
            )
            states[prepared.stateInput.conversationId]?.stdin = nil
            states[prepared.stateInput.conversationId]?.stdinWriter = nil
            forceKill(prepared.preparedProcess.process)
            await invalidateProcessResources(adapter: prepared.adapter, processToken: prepared.stateInput.processToken)
            throw error
        }
    }

    private func initialPromptInput(_ initialPrompt: String, spawnConfig: AgentSpawnConfig) -> AgentMessageInput {
        var metadata = spawnConfig.initialPromptMetadata
        if let goal = spawnConfig.initialGoal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            metadata[AgentGoalMetadata.isInitialGoalTransport] = .bool(true)
            metadata[AgentGoalMetadata.objective] = .string(goal)
        }
        return AgentMessageInput(
            text: initialPrompt,
            attachments: spawnConfig.initialPromptAttachments,
            metadata: metadata
        )
    }

}

private struct PreparedStart {
    let launch: AgentLaunchConfiguration
    let preparedProcess: PreparedProcess
    let previous: ConversationState?
    let stateInput: StateInput
    let adapter: any AgentProviderAdapter
    let resumedSession: AgentSessionRecord?
}

private struct BaseLaunchInput {
    let conversationId: AgentConversationID
    let config: AgentSpawnConfig
    let adapter: any AgentProviderAdapter
    let resumedSession: AgentSessionRecord?
    let processToken: UUID
    let startToken: UUID
}

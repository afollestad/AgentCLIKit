import Foundation

extension DefaultAgentRuntime {
    func start(conversationId: AgentConversationID, config: AgentSpawnConfig, fresh: Bool) async throws {
        let startToken = try claimStart(conversationId: conversationId)
        defer {
            releaseStart(conversationId: conversationId, startToken: startToken)
        }

        let prepared = try await prepareStart(
            conversationId: conversationId,
            config: config,
            fresh: fresh,
            startToken: startToken
        )
        try await installPreparedProcess(prepared, startToken: startToken)
        try await ensureStartIsCurrent(prepared, startToken: startToken)

        emitLifecycle(.running, conversationId: conversationId)
        emitSessionContinuity(
            prepared.launch.sessionContinuity,
            providerSessionId: prepared.launch.providerSessionId ?? prepared.resumedSession?.providerSessionId,
            conversationId: conversationId
        )
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
    }

    func cancelStart(conversationId: AgentConversationID) {
        startTokens.removeValue(forKey: conversationId)
    }

    func cancelAllStarts() {
        startTokens.removeAll()
    }
}

private extension DefaultAgentRuntime {
    func prepareStart(
        conversationId: AgentConversationID,
        config: AgentSpawnConfig,
        fresh: Bool,
        startToken: UUID
    ) async throws -> PreparedStart {
        guard let adapter = adapters[config.providerId] else {
            throw AgentCLIError.providerNotRegistered(config.providerId)
        }

        let previous = states[conversationId]
        let generation = fresh ? (previous?.generation ?? 0) + 1 : max(previous?.generation ?? 0, 1)
        let resumedSession = fresh ? nil : try await sessionStore.record(conversationId: conversationId, providerId: config.providerId)
        let processToken = UUID()
        try ensureStartIsCurrent(conversationId: conversationId, startToken: startToken)

        let baseLaunch = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: resumedSession)
        try ensureStartIsCurrent(conversationId: conversationId, startToken: startToken)

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

        let preparedProcess = makeProcess(launch: launch, config: config)
        let stateInput = StateInput(
            conversationId: conversationId,
            providerId: config.providerId,
            generation: generation,
            processToken: processToken,
            adapter: adapter,
            preparedProcess: preparedProcess,
            spawnConfig: config,
            resumedSession: resumedSession,
            launchProviderSessionId: launch.providerSessionId,
            fresh: fresh
        )
        return PreparedStart(
            launch: launch,
            preparedProcess: preparedProcess,
            previous: previous,
            stateInput: stateInput,
            adapter: adapter,
            resumedSession: resumedSession
        )
    }

    func claimStart(conversationId: AgentConversationID) throws -> UUID {
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
    }

    func ensureStartIsCurrent(conversationId: AgentConversationID, startToken: UUID) throws {
        guard startTokens[conversationId] == startToken else {
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
        guard startTokens[conversationId] == startToken else {
            forceKill(process)
            await adapter.processDidTerminate(processToken: processToken)
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
            await adapter.processDidTerminate(processToken: processToken)
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
        await invalidatePreviousProcessToken(latestPrevious)
        try await ensureStartIsCurrent(
            conversationId: stateInput.conversationId,
            startToken: startToken,
            adapter: adapter,
            processToken: stateInput.processToken,
            process: process
        )

        // Swap tokens before terminating the previous process so its exit handler is ignored.
        states[stateInput.conversationId] = makeState(input: stateInput, previous: latestPrevious)
        emitLifecycle(.starting, conversationId: stateInput.conversationId)
        forceKill(oldProcess)
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
        await invalidatePreviousProcessToken(previous)
        try await ensureStartIsCurrent(
            conversationId: stateInput.conversationId,
            startToken: startToken,
            adapter: adapter,
            processToken: stateInput.processToken
        )

        // Swap tokens before cleaning up any previous process so delayed callbacks are ignored.
        states[stateInput.conversationId] = makeState(input: stateInput, previous: previous)
        emitLifecycle(.starting, conversationId: stateInput.conversationId)
        forceKill(oldProcess)
        try await runPreparedProcess(process, launch: prepared.launch, stateInput: stateInput, adapter: adapter, recordsFailure: true)
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
            await adapter.processDidTerminate(processToken: stateInput.processToken)
            throw error
        }
    }

    func invalidatePreviousProcessToken(_ previous: ConversationState?) async {
        guard let previous else {
            return
        }
        previous.providerEventTasks.forEach { $0.cancel() }
        await previous.adapter.processDidTerminate(processToken: previous.processToken)
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
            providerSessionRecordMetadata: input.resumedSession?.metadata ?? ["source": .string("runtime")],
            providerSessionCreatedAt: input.resumedSession?.createdAt,
            permissionMode: nil,
            collaborationMode: input.spawnConfig.collaborationMode,
            isTurnActive: input.spawnConfig.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            waitingState: .idle,
            inputAvailability: .available,
            resolvedInteractions: input.fresh ? [] : previous?.resolvedInteractions ?? [],
            persistedIndex: persistedIndex,
            hasDeferredToolStop: false,
            providerResumeReplayGate: providerResumeReplayGate,
            contextCompactionStartedIds: Self.contextCompactionStartedIds(from: previous, generation: input.generation),
            contextCompactionOpenIds: Self.contextCompactionOpenIds(from: previous, generation: input.generation),
            contextCompactionTerminalIds: Self.contextCompactionTerminalIds(from: previous, generation: input.generation),
            contextCompactionPhaseKeys: Self.contextCompactionPhaseKeys(from: previous, generation: input.generation),
            outputPumps: [],
            providerEventTasks: []
        )
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

    func providerResumeReplayGate(input: StateInput, previous: ConversationState?) -> ProviderResumeReplayGate? {
        guard !input.fresh, previous?.hasDeferredToolStop == true, let previous else {
            return nil
        }
        return ProviderResumeReplayGate(previous.events.filter { $0.generation == input.generation })
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
}

private struct PreparedStart {
    let launch: AgentLaunchConfiguration
    let preparedProcess: PreparedProcess
    let previous: ConversationState?
    let stateInput: StateInput
    let adapter: any AgentProviderAdapter
    let resumedSession: AgentSessionRecord?
}

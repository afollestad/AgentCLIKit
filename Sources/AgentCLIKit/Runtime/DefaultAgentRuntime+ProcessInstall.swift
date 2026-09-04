import Foundation

/// Installing a prepared process: swapping out any previous process, wiring termination, and
/// sending the initial prompt once the new process is live.
extension DefaultAgentRuntime {
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
        let providerSession = providerSessionSeed(input: input)
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
            providerSessionId: providerSession.providerSessionId,
            providerSessionName: providerSession.name,
            providerSessionPreview: providerSession.preview,
            providerSessionRecordMetadata: providerSession.metadata,
            providerSessionCreatedAt: providerSession.createdAt,
            retiredSupersededSessionIds: previous?.retiredSupersededSessionIds ?? [],
            staleProviderSessionSaveProcessTokens: previous?.staleProviderSessionSaveProcessTokens ?? [],
            permissionMode: nil,
            collaborationMode: input.spawnConfig.collaborationMode,
            goal: seededInitialGoal(from: input) ?? (input.fresh ? nil : previous?.goal),
            isTurnActive: input.spawnConfig.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            // Background tasks die with their process and Claude announces nothing at startup, so every spawn starts empty.
            backgroundTasks: BackgroundTaskTracking(),
            providerInitiatedTurnId: nil,
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

    /// Provider-session values seeded into a new `ConversationState` at launch.
    struct ProviderSessionSeed {
        let providerSessionId: AgentSessionID?
        let name: String?
        let preview: String?
        let metadata: [String: JSONValue]
        let createdAt: Date?
    }

    /// Seeds provider-session state for a launch, distinguishing a plain resume from a replacement session.
    ///
    /// A launch may hand back a provider session that is not the one it resumed — Codex forks a thread whenever a
    /// resumed runtime needs a fresh host-tool route. Inheriting `createdAt` there would make the replacement look
    /// like an already-persisted session to `providerSessionStateUpdate`, so its record would never be written and
    /// the conversation would stay bound to the session it just replaced. Name and preview still carry over: a fork
    /// holds the same content, so the resumed labels describe it correctly until the provider reports its own.
    private func providerSessionSeed(input: StateInput) -> ProviderSessionSeed {
        let resumedSession = input.resumedSession
        let metadata = resumedSession?.metadata ?? ["source": .string("runtime")]
        let name = normalizedProviderSessionName(resumedSession?.providerSessionName)
        let preview = normalizedProviderSessionPreview(resumedSession?.providerSessionPreview)
        guard let resumedSession,
              let launchProviderSessionId = input.launchProviderSessionId,
              launchProviderSessionId != resumedSession.providerSessionId else {
            return ProviderSessionSeed(
                providerSessionId: input.launchProviderSessionId ?? resumedSession?.providerSessionId,
                name: name,
                preview: preview,
                metadata: metadata,
                createdAt: resumedSession?.createdAt
            )
        }
        return ProviderSessionSeed(
            providerSessionId: launchProviderSessionId,
            name: name,
            preview: preview,
            metadata: AgentSessionRecord.appendingSupersededProviderSessionId(
                resumedSession.providerSessionId,
                to: metadata
            ),
            createdAt: nil
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

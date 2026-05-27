import Darwin
import Foundation

/// Default process-backed implementation of `AgentRuntime`.
public actor DefaultAgentRuntime: AgentRuntime {
    let adapters: [AgentProviderID: any AgentProviderAdapter]
    let sessionStore: any AgentSessionStore
    let replayLimit: Int
    var states: [AgentConversationID: ConversationState] = [:]
    var pendingSubscribers: [AgentConversationID: [UUID: AsyncStream<AgentEventEnvelope>.Continuation]] = [:]
    var statusSubscribers: [AgentConversationID: [UUID: AsyncStream<AgentRuntimeStatus>.Continuation]] = [:]

    /// Creates a default runtime.
    /// - Parameters:
    ///   - adapters: Provider adapters keyed by their definitions. Duplicate provider IDs prefer the later adapter.
    ///   - sessionStore: Store used to resume provider sessions.
    ///   - replayLimit: Number of acknowledged events retained as replay history. Values below one are clamped to one.
    public init(
        adapters: [any AgentProviderAdapter],
        sessionStore: any AgentSessionStore = InMemoryAgentSessionStore(),
        replayLimit: Int = 500
    ) {
        self.adapters = Dictionary(adapters.map { ($0.definition.id, $0) }, uniquingKeysWith: { _, new in new })
        self.sessionStore = sessionStore
        self.replayLimit = max(1, replayLimit)
    }

    /// Spawns or replaces the provider process for a conversation.
    public func spawn(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws {
        try await start(conversationId: conversationId, config: config, fresh: false)
    }

    /// Subscribes to events after a previously persisted event index.
    public func subscribe(conversationId: AgentConversationID, afterIndex: Int?) async -> AgentEventSubscription {
        let stream = AsyncStream<AgentEventEnvelope>.makeStream()
        // Register while still isolated so callers can immediately spawn or reconfigure without missing fast events.
        addSubscriber(stream.continuation, conversationId: conversationId, afterIndex: afterIndex)
        let generation = states[conversationId]?.generation ?? 1
        return AgentEventSubscription(generation: generation, events: stream.stream)
    }

    /// Subscribes to runtime status snapshots for a conversation.
    public func statusUpdates(conversationId: AgentConversationID) async -> AsyncStream<AgentRuntimeStatus> {
        let stream = AsyncStream<AgentRuntimeStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        statusSubscribers[conversationId, default: [:]][id] = stream.continuation
        stream.continuation.onTermination = { _ in
            Task { await self.removeStatusSubscriber(id, conversationId: conversationId) }
        }
        if let status = states[conversationId]?.status(conversationId: conversationId) {
            stream.continuation.yield(status)
        }
        return stream.stream
    }

    /// Marks events as persisted by the host so replay buffers can be compacted.
    public func markPersisted(conversationId: AgentConversationID, generation: Int, upTo index: Int) async {
        guard var state = states[conversationId], state.generation == generation else {
            return
        }
        // Hosts acknowledge asynchronously; never compact beyond events this runtime has actually emitted.
        let acknowledgedIndex = min(index, state.events.last?.index ?? -1)
        guard acknowledgedIndex >= 0 else {
            return
        }
        state.persistedIndex = max(state.persistedIndex, acknowledgedIndex)
        state.compactReplayBuffer(replayLimit: replayLimit)
        states[conversationId] = state
    }

    /// Sends input to the provider process.
    public func send(_ input: AgentInput, conversationId: AgentConversationID) async throws {
        try ensureInputIsAvailable(input, conversationId: conversationId)
        guard let state = states[conversationId], let stdinWriter = state.stdinWriter else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        let adapter = state.adapter
        let processToken = state.processToken
        try await stdinWriter.enqueue {
            let data = try await adapter.encodeInput(input)
            try await self.writeInputData(data, conversationId: conversationId, processToken: processToken)
        }
    }

    /// Resolves a pending interaction and sends the resolution to the provider process.
    public func resolveInteraction(_ resolution: AgentInteractionResolution, conversationId: AgentConversationID) async throws {
        guard states[conversationId]?.stdinWriter != nil else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        guard states[conversationId]?.resolvedInteractions.contains(resolution.id) != true else {
            return
        }
        let previousWaitingState = states[conversationId]?.waitingState ?? .idle
        let previousInputAvailability = states[conversationId]?.inputAvailability ?? .available
        states[conversationId]?.waitingState = .idle
        states[conversationId]?.inputAvailability = .available
        publishStatus(conversationId: conversationId)
        do {
            try await send(.interactionResolution(resolution), conversationId: conversationId)
            states[conversationId]?.resolvedInteractions.insert(resolution.id)
        } catch {
            states[conversationId]?.waitingState = previousWaitingState
            states[conversationId]?.inputAvailability = previousInputAvailability
            publishStatus(conversationId: conversationId)
            throw error
        }
    }

    private func ensureInputIsAvailable(_ input: AgentInput, conversationId: AgentConversationID) throws {
        guard case .userMessage = input,
              let state = states[conversationId],
              case let .blocked(reason) = state.inputAvailability else {
            return
        }
        throw AgentCLIError.invalidInput("Input is blocked for conversation '\(conversationId.rawValue)': \(reason)")
    }

    private func writeInputData(_ data: Data, conversationId: AgentConversationID, processToken: UUID) throws {
        guard let state = states[conversationId], state.processToken == processToken, let stdin = state.stdin else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        do {
            try stdin.write(contentsOf: data)
        } catch {
            throw AgentCLIError.invalidInput("Could not write provider input: \(error.localizedDescription)")
        }
    }

    /// Sends an interrupt request and terminates the provider process.
    public func cancel(conversationId: AgentConversationID) async {
        guard shouldAcceptCancellation(conversationId: conversationId) else {
            return
        }
        emitLifecycle(.cancelled, conversationId: conversationId, exitCode: nil, message: "Cancelled by host.")
        states[conversationId]?.stdin = nil
        states[conversationId]?.stdinWriter = nil
        states[conversationId]?.process?.terminate()
    }

    /// Immediately kills the provider process.
    public func kill(conversationId: AgentConversationID) async {
        guard shouldAcceptKill(conversationId: conversationId) else {
            return
        }
        let process = states[conversationId]?.process
        states[conversationId]?.stdin = nil
        states[conversationId]?.stdinWriter = nil
        forceKill(process)
    }

    /// Destroys runtime state for a conversation.
    public func destroy(conversationId: AgentConversationID) async {
        let removedState = states.removeValue(forKey: conversationId)
        let removedPendingSubscribers = pendingSubscribers.removeValue(forKey: conversationId)
        removedState?.subscribers.values.forEach { $0.finish() }
        removedPendingSubscribers?.values.forEach { $0.finish() }
        statusSubscribers.removeValue(forKey: conversationId)?.values.forEach { $0.finish() }
        removedState?.outputPumps.forEach { $0.cancel() }
        if let removedState {
            await removedState.adapter.processDidTerminate(processToken: removedState.processToken)
        }
        // Remove runtime state before killing so the process termination callback cannot publish stale lifecycle events.
        forceKill(removedState?.process)
    }

    /// Shuts down runtime-owned shared resources.
    public func shutdown() async {
        for state in states.values {
            state.outputPumps.forEach { $0.cancel() }
            state.subscribers.values.forEach { $0.finish() }
            await state.adapter.processDidTerminate(processToken: state.processToken)
            forceKill(state.process)
        }
        states.removeAll()
        pendingSubscribers.values.flatMap(\.values).forEach { $0.finish() }
        pendingSubscribers.removeAll()
        statusSubscribers.values.flatMap(\.values).forEach { $0.finish() }
        statusSubscribers.removeAll()
        for adapter in adapters.values {
            await adapter.shutdownProviderResources()
        }
    }

    /// Reconfigures a conversation by spawning a replacement process.
    public func reconfigure(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws {
        try await start(conversationId: conversationId, config: config, fresh: false)
    }

    /// Starts a fresh generation for the conversation.
    public func freshSession(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws {
        try await start(conversationId: conversationId, config: config, fresh: true)
    }

    /// Returns current runtime status for a conversation.
    public func status(conversationId: AgentConversationID) async -> AgentRuntimeStatus? {
        states[conversationId]?.status(conversationId: conversationId)
    }

    private func shouldAcceptCancellation(conversationId: AgentConversationID) -> Bool {
        guard let state = states[conversationId] else {
            return false
        }
        // Host commands can race with process exit callbacks; cancellation must not rewrite terminal status.
        return !state.lifecycleState.isTerminal
    }

    private func shouldAcceptKill(conversationId: AgentConversationID) -> Bool {
        guard let state = states[conversationId] else {
            return false
        }
        // Allow kill to escalate an already cancelled process, but avoid acting on completed sessions.
        return state.lifecycleState != .exited && state.lifecycleState != .failed
    }

    private func forceKill(_ process: Process?) {
        guard let process, process.isRunning else {
            return
        }
        process.interrupt()
        process.terminate()
        // SIGINT/SIGTERM are advisory; SIGKILL makes `kill` reliable for providers that trap softer signals.
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func start(conversationId: AgentConversationID, config: AgentSpawnConfig, fresh: Bool) async throws {
        guard let adapter = adapters[config.providerId] else {
            throw AgentCLIError.providerNotRegistered(config.providerId)
        }

        let previous = states[conversationId]
        let generation = fresh ? (previous?.generation ?? 0) + 1 : max(previous?.generation ?? 0, 1)
        let resumedSession = fresh ? nil : try await sessionStore.record(conversationId: conversationId, providerId: config.providerId)
        let processToken = UUID()
        let launch = try await prepareLaunch(
            try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: resumedSession),
            adapter: adapter,
            config: config,
            conversationId: conversationId,
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
            fresh: fresh
        )

        try await installPreparedProcess(
            preparedProcess.process,
            launch: launch,
            previous: previous,
            stateInput: stateInput,
            adapter: adapter
        )

        emitLifecycle(.running, conversationId: conversationId)
        emitSessionContinuity(
            launch.sessionContinuity,
            providerSessionId: resumedSession?.providerSessionId,
            conversationId: conversationId
        )
        pump(preparedProcess.stdout.fileHandleForReading, source: .stdout, conversationId: conversationId, processToken: processToken)
        pump(preparedProcess.stderr.fileHandleForReading, source: .stderr, conversationId: conversationId, processToken: processToken)
        installTerminationHandler(
            preparedProcess.process,
            conversationId: conversationId,
            processToken: processToken
        )
    }

    private func makeProcess(launch: AgentLaunchConfiguration, config: AgentSpawnConfig) -> PreparedProcess {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(config.environment) { _, new in new }
        environment.merge(launch.environment) { _, new in new }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.includesSpawnArguments ? launch.arguments : launch.arguments + config.arguments
        process.currentDirectoryURL = launch.workingDirectory ?? config.workingDirectory
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        return PreparedProcess(process: process, stdout: stdout, stderr: stderr, stdin: stdin)
    }

    private func prepareLaunch(
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

    private func installPreparedProcess(
        _ process: Process,
        launch: AgentLaunchConfiguration,
        previous: ConversationState?,
        stateInput: StateInput,
        adapter: any AgentProviderAdapter
    ) async throws {
        if previous?.process?.isRunning == true {
            // Keep the current session alive until the replacement process has definitely launched.
            try await runPreparedProcess(process, launch: launch, stateInput: stateInput, adapter: adapter, recordsFailure: false)
            let latestPrevious = states[stateInput.conversationId] ?? previous
            let oldProcess = previous?.process
            await invalidatePreviousProcessToken(previous)
            // Swap tokens before terminating the previous process so its exit handler is ignored.
            states[stateInput.conversationId] = makeState(input: stateInput, previous: latestPrevious)
            emitLifecycle(.starting, conversationId: stateInput.conversationId)
            forceKill(oldProcess)
        } else {
            let oldProcess = previous?.process
            await invalidatePreviousProcessToken(previous)
            // Swap tokens before cleaning up any previous process so delayed callbacks are ignored.
            states[stateInput.conversationId] = makeState(input: stateInput, previous: previous)
            emitLifecycle(.starting, conversationId: stateInput.conversationId)
            forceKill(oldProcess)
            try await runPreparedProcess(process, launch: launch, stateInput: stateInput, adapter: adapter, recordsFailure: true)
        }
    }

    private func runPreparedProcess(
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

    private func invalidatePreviousProcessToken(_ previous: ConversationState?) async {
        guard let previous else {
            return
        }
        await previous.adapter.processDidTerminate(processToken: previous.processToken)
    }

    private func makeState(input: StateInput, previous: ConversationState?) -> ConversationState {
        // Fresh generations restart event indexes, so the persisted cursor is only reusable for continued sessions.
        let persistedIndex = input.fresh ? -1 : previous?.persistedIndex ?? -1
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
            providerSessionId: input.resumedSession?.providerSessionId,
            providerSessionCreatedAt: input.resumedSession?.createdAt,
            permissionMode: nil,
            waitingState: .idle,
            inputAvailability: .available,
            resolvedInteractions: input.fresh ? [] : previous?.resolvedInteractions ?? [],
            persistedIndex: persistedIndex,
            outputPumps: []
        )
    }

    private func runProcess(
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

    private func installTerminationHandler(
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

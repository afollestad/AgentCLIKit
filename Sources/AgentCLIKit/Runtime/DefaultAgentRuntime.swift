import Darwin
import Foundation

/// Default process-backed implementation of `AgentRuntime`.
public actor DefaultAgentRuntime: AgentRuntime {
    let adapters: [AgentProviderID: any AgentProviderAdapter]
    let sessionStore: any AgentSessionStore
    let replayLimit: Int
    let subscriberBufferLimit: Int
    let processFactory: AgentRuntimeProcessFactory
    let now: @Sendable () -> Date
    let sleep: AgentRuntimeSleep
    let outputDrainTimeoutNanoseconds: UInt64
    var states: [AgentConversationID: ConversationState] = [:]
    var startTokens: [AgentConversationID: UUID] = [:]
    var pendingSubscribers: [AgentConversationID: [UUID: AsyncStream<AgentEventEnvelope>.Continuation]] = [:]
    var statusSubscribers: [AgentConversationID: [UUID: AsyncStream<AgentRuntimeStatus>.Continuation]] = [:]

    /// Creates a default runtime with a provider adapter set.
    /// - Parameters:
    ///   - adapterSet: Provider adapters and matching definitions available to this runtime.
    ///   - sessionStore: Store used to resume provider sessions.
    ///   - replayLimit: Number of acknowledged events retained as replay history. Values below one are clamped to one.
    ///   - subscriberBufferLimit: Maximum live events buffered per subscriber while the host is not consuming. Values below one
    ///     are clamped to one; replay remains available through `subscribe(conversationId:afterIndex:)`.
    public init(
        adapterSet: AgentProviderAdapterSet = .default,
        sessionStore: any AgentSessionStore = InMemoryAgentSessionStore(),
        replayLimit: Int = 500,
        subscriberBufferLimit: Int = 1_000
    ) {
        self.init(
            adapters: adapterSet.adapters,
            sessionStore: sessionStore,
            replayLimit: replayLimit,
            subscriberBufferLimit: subscriberBufferLimit,
            processFactory: defaultAgentRuntimeProcessFactory,
            now: Date.init,
            sleep: defaultAgentRuntimeSleep,
            outputDrainTimeoutNanoseconds: 500_000_000
        )
    }

    /// Creates a default runtime.
    /// - Parameters:
    ///   - adapters: Provider adapters keyed by their definitions. Duplicate provider IDs prefer the later adapter.
    ///   - sessionStore: Store used to resume provider sessions.
    ///   - replayLimit: Number of acknowledged events retained as replay history. Values below one are clamped to one.
    ///   - subscriberBufferLimit: Maximum live events buffered per subscriber while the host is not consuming. Values below one
    ///     are clamped to one; replay remains available through `subscribe(conversationId:afterIndex:)`.
    public init(
        adapters: [any AgentProviderAdapter],
        sessionStore: any AgentSessionStore = InMemoryAgentSessionStore(),
        replayLimit: Int = 500,
        subscriberBufferLimit: Int = 1_000
    ) {
        self.init(
            adapters: adapters,
            sessionStore: sessionStore,
            replayLimit: replayLimit,
            subscriberBufferLimit: subscriberBufferLimit,
            processFactory: defaultAgentRuntimeProcessFactory,
            now: Date.init,
            sleep: defaultAgentRuntimeSleep,
            outputDrainTimeoutNanoseconds: 500_000_000
        )
    }

    init(
        adapters: [any AgentProviderAdapter],
        sessionStore: any AgentSessionStore = InMemoryAgentSessionStore(),
        replayLimit: Int = 500,
        subscriberBufferLimit: Int = 1_000,
        processFactory: @escaping AgentRuntimeProcessFactory = defaultAgentRuntimeProcessFactory,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping AgentRuntimeSleep = defaultAgentRuntimeSleep,
        outputDrainTimeoutNanoseconds: UInt64 = 500_000_000
    ) {
        self.adapters = Dictionary(adapters.map { ($0.definition.id, $0) }, uniquingKeysWith: { _, new in new })
        self.sessionStore = sessionStore
        self.replayLimit = max(1, replayLimit)
        self.subscriberBufferLimit = max(1, subscriberBufferLimit)
        self.processFactory = processFactory
        self.now = now
        self.sleep = sleep
        self.outputDrainTimeoutNanoseconds = outputDrainTimeoutNanoseconds
    }

    /// Spawns or replaces the provider process for a conversation.
    public func spawn(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws {
        try await start(conversationId: conversationId, config: config, fresh: false)
    }

    /// Subscribes to events after a previously persisted event index.
    public func subscribe(conversationId: AgentConversationID, afterIndex: Int?) async -> AgentEventSubscription {
        let stream = AsyncStream<AgentEventEnvelope>.makeStream(
            bufferingPolicy: bufferingPolicy(conversationId: conversationId, afterIndex: afterIndex)
        )
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
        let marksTurnActive = input.isUserMessage
        try await stdinWriter.enqueue {
            let data = try await adapter.encodeInput(input)
            try await self.writeInputData(
                data,
                conversationId: conversationId,
                processToken: processToken,
                marksTurnActive: marksTurnActive
            )
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
        let previousResolvedInteractions = states[conversationId]?.resolvedInteractions ?? []
        // Mark before awaiting provider I/O so actor reentrancy cannot publish the same prompt as pending again.
        states[conversationId]?.resolvedInteractions.insert(resolution.id)
        states[conversationId]?.waitingState = .idle
        states[conversationId]?.inputAvailability = .available
        publishStatus(conversationId: conversationId)
        do {
            try await send(.interactionResolution(resolution), conversationId: conversationId)
        } catch {
            states[conversationId]?.resolvedInteractions = previousResolvedInteractions
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

    private func writeInputData(
        _ data: Data,
        conversationId: AgentConversationID,
        processToken: UUID,
        marksTurnActive: Bool
    ) throws {
        guard let state = states[conversationId], state.processToken == processToken, let stdin = state.stdin else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        let markedTurnActive = marksTurnActive && !state.isTurnActive
        if markedTurnActive {
            states[conversationId]?.isTurnActive = true
            publishStatus(conversationId: conversationId)
        }
        do {
            try stdin.write(contentsOf: data)
        } catch {
            if markedTurnActive {
                states[conversationId]?.isTurnActive = false
                publishStatus(conversationId: conversationId)
            }
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
        cancelStart(conversationId: conversationId)
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
        cancelAllStarts()
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

    private func bufferingPolicy(
        conversationId: AgentConversationID,
        afterIndex: Int?
    ) -> AsyncStream<AgentEventEnvelope>.Continuation.BufferingPolicy {
        let cursor = afterIndex ?? -1
        let replayCount = states[conversationId]?.events.filter { $0.index > cursor }.count ?? 0
        return replayCount > subscriberBufferLimit ? .unbounded : .bufferingNewest(subscriberBufferLimit)
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

    func forceKill(_ process: Process?) {
        guard let process, process.isRunning else {
            return
        }
        process.interrupt()
        process.terminate()
        // SIGINT/SIGTERM are advisory; SIGKILL makes `kill` reliable for providers that trap softer signals.
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

private extension AgentInput {
    var isUserMessage: Bool {
        if case .userMessage = self {
            return true
        }
        return false
    }
}

import Darwin
import Foundation

/// Default process-backed implementation of `AgentRuntime`.
public actor DefaultAgentRuntime: AgentRuntime {
    private let adapters: [AgentProviderID: any AgentProviderAdapter]
    private let sessionStore: any AgentSessionStore
    private let replayLimit: Int
    private var states: [AgentConversationID: ConversationState] = [:]
    private var pendingSubscribers: [AgentConversationID: [UUID: AsyncStream<AgentEventEnvelope>.Continuation]] = [:]

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
        // Remove runtime state before killing so the process termination callback cannot publish stale lifecycle events.
        forceKill(removedState?.process)
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
        let launch = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: resumedSession)

        let preparedProcess = makeProcess(launch: launch, config: config)
        let processToken = UUID()
        let stateInput = StateInput(
            conversationId: conversationId,
            providerId: config.providerId,
            generation: generation,
            processToken: processToken,
            adapter: adapter,
            preparedProcess: preparedProcess,
            resumedSession: resumedSession,
            fresh: fresh
        )

        if previous?.process?.isRunning == true {
            // Keep the current session alive until the replacement process has definitely launched.
            try runProcess(preparedProcess.process, launch: launch, conversationId: conversationId, recordsFailure: false)
            let latestPrevious = states[conversationId] ?? previous
            let oldProcess = previous?.process
            // Swap tokens before terminating the previous process so its exit handler is ignored.
            states[conversationId] = makeState(input: stateInput, previous: latestPrevious)
            emitLifecycle(.starting, conversationId: conversationId)
            forceKill(oldProcess)
        } else {
            let oldProcess = previous?.process
            // Swap tokens before cleaning up any previous process so delayed callbacks are ignored.
            states[conversationId] = makeState(input: stateInput, previous: previous)
            emitLifecycle(.starting, conversationId: conversationId)
            forceKill(oldProcess)
            try runProcess(preparedProcess.process, launch: launch, conversationId: conversationId, recordsFailure: true)
        }

        emitLifecycle(.running, conversationId: conversationId)
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
        process.arguments = launch.arguments + config.arguments
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

    private func makeState(input: StateInput, previous: ConversationState?) -> ConversationState {
        // Fresh generations restart event indexes, so the persisted cursor is only reusable for continued sessions.
        let persistedIndex = input.fresh ? -1 : previous?.persistedIndex ?? -1
        return ConversationState(
            providerId: input.providerId,
            generation: input.generation,
            processToken: input.processToken,
            adapter: input.adapter,
            process: input.preparedProcess.process,
            stdin: input.preparedProcess.stdin.fileHandleForWriting,
            stdinWriter: StdinWriteQueue(),
            events: previous?.events.filter { $0.generation == input.generation } ?? [],
            subscribers: previous?.subscribers ?? pendingSubscribers.removeValue(forKey: input.conversationId) ?? [:],
            stderrTail: [],
            lifecycleState: .starting,
            providerSessionId: input.resumedSession?.providerSessionId,
            providerSessionCreatedAt: input.resumedSession?.createdAt,
            persistedIndex: persistedIndex
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
            processExited(conversationId: conversationId, processToken: processToken, exitCode: process.terminationStatus)
        }
    }
}

private extension DefaultAgentRuntime {
    private func addSubscriber(
        _ continuation: AsyncStream<AgentEventEnvelope>.Continuation,
        conversationId: AgentConversationID,
        afterIndex: Int?
    ) {
        guard var state = states[conversationId] else {
            let id = UUID()
            pendingSubscribers[conversationId, default: [:]][id] = continuation
            continuation.onTermination = { _ in Task { await self.removeSubscriber(id, conversationId: conversationId) } }
            return
        }
        let id = UUID()
        state.subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeSubscriber(id, conversationId: conversationId) } }
        let cursor = afterIndex ?? -1
        state.events.filter { $0.index > cursor }.forEach { continuation.yield($0) }
        states[conversationId] = state
    }

    private func removeSubscriber(_ id: UUID, conversationId: AgentConversationID) {
        states[conversationId]?.subscribers[id] = nil
        pendingSubscribers[conversationId]?[id] = nil
    }

    private func pump(
        _ fileHandle: FileHandle,
        source: AgentEventSource,
        conversationId: AgentConversationID,
        processToken: UUID
    ) {
        Task {
            do {
                for try await line in fileHandle.bytes.lines {
                    await self.consumeLine(line, source: source, conversationId: conversationId, processToken: processToken)
                }
            } catch {
                self.emitStreamReadFailure(
                    error,
                    source: source,
                    conversationId: conversationId,
                    processToken: processToken
                )
            }
        }
    }

    private func emitStreamReadFailure(
        _ error: Error,
        source: AgentEventSource,
        conversationId: AgentConversationID,
        processToken: UUID
    ) {
        // Stream pumps can report read failures after replacement teardown; keep those diagnostics with the process that caused them.
        guard states[conversationId]?.processToken == processToken else {
            return
        }
        emitDiagnostic(
            severity: .warning,
            message: "Provider stream read failed: \(error.localizedDescription)",
            source: source,
            conversationId: conversationId
        )
    }

    private func consumeLine(
        _ line: String,
        source: AgentEventSource,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        // Stream pumps can outlive a replaced process; the token prevents stale output from entering the new session.
        guard let state = states[conversationId], state.processToken == processToken else {
            return
        }
        if source == .stderr {
            appendStderr(line, conversationId: conversationId)
            append(.diagnostic(AgentDiagnosticEvent(severity: .info, message: line)), source: .stderr, conversationId: conversationId)
            return
        }
        do {
            let events = try await state.adapter.decodeStdoutLine(line)
            // Decoders can suspend, so re-check the token before accepting output for a replaced process.
            guard states[conversationId]?.processToken == processToken else {
                return
            }
            for event in events {
                await recordProviderSessionIfNeeded(from: event, conversationId: conversationId, processToken: processToken)
                guard states[conversationId]?.processToken == processToken else {
                    return
                }
                append(event, source: .stdout, conversationId: conversationId)
            }
        } catch {
            // Stdout and stderr are pumped independently; a short grace period lets earlier stderr lines reach the tail.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard states[conversationId]?.processToken == processToken else {
                return
            }
            let tail = states[conversationId]?.stderrTail.joined(separator: "\n") ?? ""
            let message = tail.isEmpty ? error.localizedDescription : "\(error.localizedDescription)\nRecent stderr:\n\(tail)"
            append(.diagnostic(AgentDiagnosticEvent(severity: .error, message: message)), source: .runtime, conversationId: conversationId)
        }
    }

    private func recordProviderSessionIfNeeded(
        from event: AgentEvent,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        guard
            var state = states[conversationId],
            state.processToken == processToken,
            let providerSessionId = state.adapter.sessionID(from: event)
        else {
            return
        }
        guard state.providerSessionId != providerSessionId else {
            return
        }

        // Session IDs are discovered from provider output; update runtime status before awaiting durable storage.
        state.providerSessionId = providerSessionId
        let createdAt = state.providerSessionCreatedAt ?? Date()
        state.providerSessionCreatedAt = createdAt
        states[conversationId] = state

        let record = AgentSessionRecord(
            conversationId: conversationId,
            providerId: state.providerId,
            providerSessionId: providerSessionId,
            generation: state.generation,
            createdAt: createdAt,
            metadata: ["source": .string("runtime")]
        )
        do {
            try await sessionStore.save(record)
        } catch {
            guard states[conversationId]?.processToken == processToken else {
                return
            }
            emitDiagnostic(
                severity: .warning,
                message: "Could not persist provider session: \(error.localizedDescription)",
                source: .runtime,
                conversationId: conversationId
            )
        }
    }

    private func processExited(conversationId: AgentConversationID, processToken: UUID, exitCode: Int32) {
        // Termination handlers may race with reconfigure/freshSession; ignore callbacks from older processes.
        guard states[conversationId]?.processToken == processToken else {
            return
        }
        switch states[conversationId]?.lifecycleState {
        case .cancelled, .exited, .failed:
            states[conversationId]?.stdin = nil
            states[conversationId]?.stdinWriter = nil
            return
        case .starting, .running, nil:
            break
        }
        let state: AgentLifecycleState = exitCode == 0 ? .exited : .failed
        emitLifecycle(state, conversationId: conversationId, exitCode: exitCode)
        states[conversationId]?.stdin = nil
        states[conversationId]?.stdinWriter = nil
    }

    private func emitLifecycle(
        _ state: AgentLifecycleState,
        conversationId: AgentConversationID,
        exitCode: Int32? = nil,
        message: String? = nil
    ) {
        append(.lifecycle(AgentLifecycleEvent(state: state, exitCode: exitCode, message: message)), source: .process, conversationId: conversationId)
        states[conversationId]?.lifecycleState = state
    }

    private func emitDiagnostic(
        severity: AgentDiagnosticSeverity,
        message: String,
        source: AgentEventSource,
        conversationId: AgentConversationID
    ) {
        append(.diagnostic(AgentDiagnosticEvent(severity: severity, message: message)), source: source, conversationId: conversationId)
    }

    private func appendStderr(_ line: String, conversationId: AgentConversationID) {
        guard var state = states[conversationId] else {
            return
        }
        state.stderrTail.append(line)
        if state.stderrTail.count > 20 {
            state.stderrTail.removeFirst(state.stderrTail.count - 20)
        }
        states[conversationId] = state
    }

    private func append(_ event: AgentEvent, source: AgentEventSource, conversationId: AgentConversationID) {
        guard var state = states[conversationId] else {
            return
        }
        let envelope = AgentEventEnvelope(
            generation: state.generation,
            index: (state.events.last?.index ?? -1) + 1,
            providerId: state.providerId,
            conversationId: conversationId,
            providerSessionId: state.providerSessionId,
            source: source,
            event: event
        )
        state.events.append(envelope)
        state.compactReplayBuffer(replayLimit: replayLimit)
        state.subscribers.values.forEach { $0.yield(envelope) }
        states[conversationId] = state
    }
}

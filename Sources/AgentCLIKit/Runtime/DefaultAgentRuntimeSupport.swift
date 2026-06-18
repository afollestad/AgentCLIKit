import Foundation

typealias AgentRuntimeProcessFactory = (AgentLaunchConfiguration, AgentSpawnConfig) -> PreparedProcess
typealias AgentRuntimeSleep = @Sendable (UInt64) async -> Void

func defaultAgentRuntimeProcessFactory(launch: AgentLaunchConfiguration, config: AgentSpawnConfig) -> PreparedProcess {
    DefaultAgentRuntime.defaultProcessFactory(launch: launch, config: config)
}

func defaultAgentRuntimeSleep(nanoseconds: UInt64) async {
    await DefaultAgentRuntime.defaultSleep(nanoseconds: nanoseconds)
}

func normalizedProviderSessionName(_ name: String?) -> String? {
    guard let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines),
          !normalized.isEmpty else {
        return nil
    }
    return normalized
}

func normalizedProviderSessionPreview(_ preview: String?) -> String? {
    normalizedProviderSessionName(preview)
}

struct ConversationState {
    let providerId: AgentProviderID
    let generation: Int
    let processToken: UUID
    let adapter: any AgentProviderAdapter
    var spawnConfig: AgentSpawnConfig
    var process: Process?
    var stdin: FileHandle?
    var stdinWriter: StdinWriteQueue?
    var events: [AgentEventEnvelope]
    var subscribers: [UUID: AsyncStream<AgentEventEnvelope>.Continuation]
    var stderrTail: [String]
    var lifecycleState: AgentLifecycleState
    var providerSessionId: AgentSessionID?
    var providerSessionName: String?
    var providerSessionPreview: String?
    var providerSessionRecordMetadata: [String: JSONValue]
    var providerSessionCreatedAt: Date?
    var staleProviderSessionSaveProcessTokens: Set<UUID>
    var permissionMode: String?
    var collaborationMode: AgentCollaborationMode?
    var isTurnActive: Bool
    var waitingState: AgentRuntimeWaitingState
    var inputAvailability: AgentInputAvailability
    var resolvedInteractions: Set<AgentInteractionID>
    var runtimePlanExitInteractions: [AgentInteractionID: RuntimePlanExitInteraction]
    var pendingPlanImplementationStart: PendingPlanImplementationStart?
    var completedPlanImplementationKeys: Set<String>
    var synthesizedPlanExitProposalKeys: Set<String>
    var persistedIndex: Int
    var hasDeferredToolStop: Bool
    var providerResumeReplayGate: ProviderResumeReplayGate?
    var contextCompactionStartedIds: Set<String>
    var contextCompactionOpenIds: Set<String>
    var contextCompactionTerminalIds: Set<String>
    var contextCompactionPhaseKeys: Set<String>
    var subAgentStartedIds: Set<String>
    var subAgentOpenIds: Set<String>
    var subAgentTerminalIds: Set<String>
    var subAgentPhaseKeys: Set<String>
    var outputPumps: [OutputLinePump]
    var providerEventTasks: [Task<Void, Never>]

    mutating func compactReplayBuffer(replayLimit: Int) {
        // Acknowledged events can be trimmed to a small tail; unacknowledged events stay available for host recovery.
        let retainedGeneration = generation
        let oldestRetainedIndex = persistedIndex - replayLimit
        events.removeAll { $0.generation == retainedGeneration && $0.index <= oldestRetainedIndex }
    }

    func status(conversationId: AgentConversationID) -> AgentRuntimeStatus {
        AgentRuntimeStatus(
            conversationId: conversationId,
            providerId: providerId,
            generation: generation,
            state: lifecycleState,
            lastEventIndex: events.last?.index ?? -1,
            providerSessionId: providerSessionId,
            providerSessionName: providerSessionName,
            providerSessionPreview: providerSessionPreview,
            permissionMode: permissionMode,
            collaborationMode: collaborationMode,
            isTurnActive: isTurnActive,
            inputAvailability: inputAvailability,
            waitingState: waitingState,
            processIdentifier: process?.isRunning == true ? process?.processIdentifier : nil,
            isProcessRunning: process?.isRunning == true,
            canCancel: lifecycleState == .starting || lifecycleState == .running
        )
    }
}

struct RuntimePlanExitInteraction: Sendable {
    let id: AgentInteractionID
    let proposalId: String
    let planMarkdown: String
}

struct PendingPlanImplementationStart: Sendable {
    let interactionId: AgentInteractionID
    let implementationKey: String
    let proposalId: String
    let planMarkdown: String
    let prompt: String
    let targetConfig: AgentSpawnConfig
}

extension DefaultAgentRuntime {
    static func contextCompactionPhaseKey(_ compaction: AgentContextCompactionEvent) -> String {
        "\(compaction.id)\u{1F}\(compaction.phase.rawValue)"
    }

}

struct ProviderResumeReplayGate {
    private var replayEvents: [ProviderResumeReplayFingerprint]
    private var replayIndex = 0
    private(set) var isActive = true

    init?(_ envelopes: [AgentEventEnvelope]) {
        let replayEvents = envelopes.compactMap { envelope -> ProviderResumeReplayFingerprint? in
            guard envelope.source == .stdout, envelope.event.isProviderResumeReplayCandidate else {
                return nil
            }
            return ProviderResumeReplayFingerprint(envelope.event)
        }
        guard !replayEvents.isEmpty else {
            return nil
        }
        self.replayEvents = Self.expandedReplayEvents(from: replayEvents)
    }

    mutating func shouldSuppress(_ event: AgentEvent) -> Bool {
        guard isActive, let fingerprint = ProviderResumeReplayFingerprint(event) else {
            return false
        }
        guard replayIndex < replayEvents.count else {
            isActive = false
            return false
        }

        // Claude resumes can replay a retained suffix rather than the entire retained
        // provider transcript. Keep the gate active while the new stream is still
        // matching any remaining retained frame, then stop at the first unmatched frame.
        guard let matchedIndex = replayEvents[replayIndex...].firstIndex(where: { $0.matchesReplay(of: fingerprint) }) else {
            isActive = false
            return false
        }
        replayIndex = replayEvents.index(after: matchedIndex)
        return true
    }

    var isFinished: Bool {
        !isActive || replayIndex >= replayEvents.count
    }

    private static func expandedReplayEvents(
        from replayEvents: [ProviderResumeReplayFingerprint]
    ) -> [ProviderResumeReplayFingerprint] {
        var expanded: [ProviderResumeReplayFingerprint] = []
        var pendingDeltaMessage: PendingReplayDeltaMessage?

        for replayEvent in replayEvents {
            if case let .messageDelta(role, text, metadata) = replayEvent {
                if pendingDeltaMessage?.canAppend(role: role, metadata: metadata) == true {
                    pendingDeltaMessage?.text.append(text)
                } else {
                    appendPendingDeltaMessage(&pendingDeltaMessage, to: &expanded)
                    pendingDeltaMessage = PendingReplayDeltaMessage(role: role, text: text, metadata: metadata)
                }
                expanded.append(replayEvent)
            } else {
                appendPendingDeltaMessage(&pendingDeltaMessage, to: &expanded)
                expanded.append(replayEvent)
            }
        }

        appendPendingDeltaMessage(&pendingDeltaMessage, to: &expanded)
        return expanded
    }

    private static func appendPendingDeltaMessage(
        _ pendingDeltaMessage: inout PendingReplayDeltaMessage?,
        to expanded: inout [ProviderResumeReplayFingerprint]
    ) {
        guard let message = pendingDeltaMessage, !message.text.isEmpty else {
            return
        }
        // Claude may retain an assistant response as streaming deltas, then replay
        // it after approval as the equivalent completed message frame.
        expanded.append(.message(
            role: message.role,
            text: message.text,
            metadata: message.metadata
        ))
        pendingDeltaMessage = nil
    }
}

private struct PendingReplayDeltaMessage {
    let role: AgentMessageRole
    var text: String
    let metadata: [ProviderResumeMetadataEntry]

    func canAppend(role: AgentMessageRole, metadata: [ProviderResumeMetadataEntry]) -> Bool {
        self.role == role && self.metadata == metadata
    }
}

extension AgentEvent {
    var isProviderResumeReplayCandidate: Bool {
        switch self {
        case .message, .messageDelta, .reasoning, .toolCall, .toolResult, .usage, .rateLimit, .permissionMode,
             .collaborationMode, .task, .subAgent, .contextCompaction, .interaction, .rawOutput:
            true
        case .activity, .sessionMetadata, .sessionContinuity, .lifecycle, .diagnostic:
            false
        }
    }
}

final class OutputLinePump: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let lineQueue: OutputLineQueue

    private var buffer = Data()
    private var isFinishing = false
    private var hasFinished = false

    init(handle: FileHandle, onLine: @escaping @Sendable (String) async -> Void) {
        self.handle = handle
        self.lineQueue = OutputLineQueue(onLine: onLine)
    }

    deinit {
        cancel()
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            self?.handleReadable(handle)
        }
    }

    func cancel() {
        finish(flushPendingLine: false)
        lineQueue.cancel()
    }

    func waitUntilDrained(timeoutNanoseconds: UInt64, sleep: AgentRuntimeSleep) async {
        let sleepNanoseconds: UInt64 = 5_000_000
        let attempts = max(1, Int(timeoutNanoseconds / sleepNanoseconds))
        for _ in 0..<attempts {
            if isFinished, lineQueue.isIdle {
                return
            }
            await sleep(sleepNanoseconds)
        }
    }

    func waitUntilIdle(timeoutNanoseconds: UInt64, sleep: AgentRuntimeSleep) async {
        let sleepNanoseconds: UInt64 = 5_000_000
        let attempts = max(1, Int(timeoutNanoseconds / sleepNanoseconds))
        var idleChecks = 0
        for _ in 0..<attempts {
            await sleep(sleepNanoseconds)
            if lineQueue.isIdle {
                idleChecks += 1
                if idleChecks >= 2 {
                    return
                }
            } else {
                idleChecks = 0
            }
        }
    }

    private var isFinished: Bool {
        lock.withLock {
            hasFinished
        }
    }

    private func handleReadable(_ handle: FileHandle) {
        let chunk = handle.availableData
        if chunk.isEmpty {
            finish(flushPendingLine: true)
            return
        }

        schedule(appendAndTakeLines(from: chunk))
    }

    private func appendAndTakeLines(from chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        guard !hasFinished, !isFinishing else {
            return []
        }

        buffer.append(chunk)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineData = Data(buffer[..<newlineIndex])
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            lines.append(String(data: lineData, encoding: .utf8) ?? "")
            buffer.removeSubrange(...newlineIndex)
        }
        return lines
    }

    private func finish(flushPendingLine: Bool) {
        let pendingLine: String?

        lock.lock()
        guard !hasFinished, !isFinishing else {
            lock.unlock()
            return
        }

        isFinishing = true
        handle.readabilityHandler = nil
        if flushPendingLine, !buffer.isEmpty {
            let pendingData = buffer.last == 0x0D ? Data(buffer.dropLast()) : buffer
            pendingLine = String(data: pendingData, encoding: .utf8)
        } else {
            pendingLine = nil
        }
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        if let pendingLine, !pendingLine.isEmpty {
            schedule([pendingLine])
        }

        lock.withLock {
            hasFinished = true
            isFinishing = false
        }
    }

    private func schedule(_ lines: [String]) {
        guard !lines.isEmpty else {
            return
        }
        lineQueue.enqueue(lines)
    }
}

private final class OutputLineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: @Sendable (String) async -> Void
    private var pendingLines: [String] = []
    private var nextLineIndex = 0
    private var isProcessing = false
    private var isCancelled = false

    init(onLine: @escaping @Sendable (String) async -> Void) {
        self.onLine = onLine
    }

    func enqueue(_ lines: [String]) {
        lock.lock()
        guard !isCancelled, !lines.isEmpty else {
            lock.unlock()
            return
        }
        pendingLines.append(contentsOf: lines)
        guard !isProcessing else {
            lock.unlock()
            return
        }

        isProcessing = true
        lock.unlock()
        Task { await drain() }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            pendingLines.removeAll()
            nextLineIndex = 0
        }
    }

    var isIdle: Bool {
        lock.withLock {
            !isProcessing && pendingLines.isEmpty
        }
    }

    private func drain() async {
        while let line = nextLine() {
            await onLine(line)
        }
    }

    private func nextLine() -> String? {
        lock.withLock {
            guard !isCancelled, nextLineIndex < pendingLines.count else {
                isProcessing = false
                pendingLines.removeAll(keepingCapacity: true)
                nextLineIndex = 0
                return nil
            }
            let line = pendingLines[nextLineIndex]
            nextLineIndex += 1
            if nextLineIndex > 1_024, nextLineIndex * 2 > pendingLines.count {
                pendingLines.removeFirst(nextLineIndex)
                nextLineIndex = 0
            }
            return line
        }
    }
}

extension AgentLifecycleState {
    var isTerminal: Bool {
        switch self {
        case .cancelled, .exited, .failed:
            true
        case .starting, .running:
            false
        }
    }
}

struct StateInput {
    let conversationId: AgentConversationID
    let providerId: AgentProviderID
    let generation: Int
    let processToken: UUID
    let adapter: any AgentProviderAdapter
    let preparedProcess: PreparedProcess
    let spawnConfig: AgentSpawnConfig
    let resumedSession: AgentSessionRecord?
    let launchProviderSessionId: AgentSessionID?
    let fresh: Bool
}

actor StdinWriteQueue {
    private var tail: (id: UUID, task: Task<Void, Error>)?

    func enqueue(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail?.task
        let id = UUID()
        let task = Task {
            // Preserve send order across async encoders without making one failed input poison later writes.
            if let previous {
                _ = try? await previous.value
            }
            try Task.checkCancellation()
            try await operation()
        }
        tail = (id, task)
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if tail?.id == id {
                tail = nil
            }
            throw error
        }
        if tail?.id == id {
            tail = nil
        }
    }
}

struct PreparedProcess {
    let process: Process
    let stdout: Pipe
    let stderr: Pipe
    let stdin: Pipe
}

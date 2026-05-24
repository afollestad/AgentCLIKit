import Foundation

struct ConversationState {
    let providerId: AgentProviderID
    let generation: Int
    let processToken: UUID
    let adapter: any AgentProviderAdapter
    let spawnConfig: AgentSpawnConfig
    var process: Process?
    var stdin: FileHandle?
    var stdinWriter: StdinWriteQueue?
    var events: [AgentEventEnvelope]
    var subscribers: [UUID: AsyncStream<AgentEventEnvelope>.Continuation]
    var stderrTail: [String]
    var lifecycleState: AgentLifecycleState
    var providerSessionId: AgentSessionID?
    var providerSessionCreatedAt: Date?
    var permissionMode: String?
    var waitingState: AgentRuntimeWaitingState
    var inputAvailability: AgentInputAvailability
    var resolvedInteractions: Set<AgentInteractionID>
    var persistedIndex: Int
    var outputPumps: [OutputLinePump]

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
            permissionMode: permissionMode,
            inputAvailability: inputAvailability,
            waitingState: waitingState
        )
    }
}

final class OutputLinePump: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let lineQueue: OutputLineQueue

    private var buffer = Data()
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

        guard !hasFinished else {
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
        guard !hasFinished else {
            lock.unlock()
            return
        }

        hasFinished = true
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

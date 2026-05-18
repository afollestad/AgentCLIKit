import Foundation

struct ConversationState {
    let providerId: AgentProviderID
    let generation: Int
    let processToken: UUID
    let adapter: any AgentProviderAdapter
    var process: Process?
    var stdin: FileHandle?
    var stdinWriter: StdinWriteQueue?
    var events: [AgentEventEnvelope]
    var subscribers: [UUID: AsyncStream<AgentEventEnvelope>.Continuation]
    var stderrTail: [String]
    var lifecycleState: AgentLifecycleState
    var providerSessionId: AgentSessionID?
    var providerSessionCreatedAt: Date?
    var persistedIndex: Int

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
            providerSessionId: providerSessionId
        )
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

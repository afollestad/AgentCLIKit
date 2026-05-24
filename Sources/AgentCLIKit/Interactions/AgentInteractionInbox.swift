import Foundation

/// Host-facing pending interaction API that publishes restorable approvals and prompts.
public protocol AgentInteractionInbox: Sendable {
    /// Saves or replaces a pending interaction and notifies subscribers.
    func publish(_ record: AgentInteractionRecord) async
    /// Resolves a pending interaction and notifies subscribers.
    func resolve(_ resolution: AgentInteractionResolution) async
    /// Returns the current pending actions for a conversation.
    func pendingActions(conversationId: AgentConversationID) async -> [AgentPendingAction]
    /// Subscribes to ordered pending-action snapshots for a conversation.
    func subscribe(conversationId: AgentConversationID) async -> AsyncStream<[AgentPendingAction]>
}

/// Restorable host action derived from an interaction record.
public enum AgentPendingAction: Codable, Equatable, Sendable, Identifiable {
    /// Tool or plan approval awaiting a host decision.
    case approval(AgentApprovalRequest)
    /// Provider prompt awaiting a user answer.
    case prompt(AgentPromptRequest)

    /// Interaction identifier.
    public var id: AgentInteractionID {
        switch self {
        case let .approval(request):
            request.id
        case let .prompt(request):
            request.id
        }
    }

    /// Conversation that owns the action.
    public var conversationId: AgentConversationID {
        switch self {
        case let .approval(request):
            request.conversationId
        case let .prompt(request):
            request.conversationId
        }
    }
}

/// Maps provider-specific interaction payloads into provider-neutral pending actions.
public protocol AgentInteractionMapping: Sendable {
    /// Returns a pending action for a stored interaction record, or `nil` when the record is not host actionable.
    func pendingAction(from record: AgentInteractionRecord) async -> AgentPendingAction?
}

/// Default interaction mapper for records already stored in provider-neutral form.
public struct DefaultAgentInteractionMapping: AgentInteractionMapping {
    /// Creates a default mapper.
    public init() {}

    /// Maps approval and prompt records to pending actions.
    public func pendingAction(from record: AgentInteractionRecord) async -> AgentPendingAction? {
        if let request = record.promptRequest {
            return .prompt(request)
        }
        if let request = record.approvalRequest {
            return .approval(request)
        }
        return nil
    }
}

/// In-memory interaction inbox backed by an `AgentInteractionStore`.
public actor InMemoryAgentInteractionInbox: AgentInteractionInbox {
    private let store: any AgentInteractionStore
    private let mapper: any AgentInteractionMapping
    private var subscribers: [AgentConversationID: [UUID: AsyncStream<[AgentPendingAction]>.Continuation]] = [:]

    /// Creates an interaction inbox.
    public init(
        store: any AgentInteractionStore = InMemoryAgentInteractionStore(),
        mapper: any AgentInteractionMapping = DefaultAgentInteractionMapping()
    ) {
        self.store = store
        self.mapper = mapper
    }

    /// Saves or replaces a pending interaction and notifies subscribers.
    public func publish(_ record: AgentInteractionRecord) async {
        await store.save(record)
        await publishSnapshot(conversationId: record.conversationId)
    }

    /// Resolves a pending interaction and notifies subscribers.
    public func resolve(_ resolution: AgentInteractionResolution) async {
        guard let record = await store.record(id: resolution.id) else {
            return
        }
        await store.resolve(resolution, updatedAt: Date())
        await publishSnapshot(conversationId: record.conversationId)
    }

    /// Returns the current pending actions for a conversation.
    public func pendingActions(conversationId: AgentConversationID) async -> [AgentPendingAction] {
        await actions(conversationId: conversationId)
    }

    /// Subscribes to pending-action snapshots, yielding the current snapshot first.
    public func subscribe(conversationId: AgentConversationID) async -> AsyncStream<[AgentPendingAction]> {
        let stream = AsyncStream<[AgentPendingAction]>.makeStream()
        let id = UUID()
        subscribers[conversationId, default: [:]][id] = stream.continuation
        stream.continuation.onTermination = { _ in
            Task { await self.removeSubscriber(id, conversationId: conversationId) }
        }
        stream.continuation.yield(await actions(conversationId: conversationId))
        return stream.stream
    }

    private func removeSubscriber(_ id: UUID, conversationId: AgentConversationID) {
        subscribers[conversationId]?[id] = nil
    }

    private func publishSnapshot(conversationId: AgentConversationID) async {
        let snapshot = await actions(conversationId: conversationId)
        subscribers[conversationId]?.values.forEach { $0.yield(snapshot) }
    }

    private func actions(conversationId: AgentConversationID) async -> [AgentPendingAction] {
        let records = await store.pending(conversationId: conversationId)
        var actions: [AgentPendingAction] = []
        for record in records {
            if let action = await mapper.pendingAction(from: record) {
                actions.append(action)
            }
        }
        return actions
    }
}

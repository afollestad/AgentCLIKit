import Foundation

/// Provider background tasks outlive the turn that started them, so the runtime tracks them separately from
/// `isTurnActive`: the live set feeds `AgentRuntimeStatus.liveBackgroundTaskCount`, and a dequeued notification for a
/// task this process announced becomes a provider-initiated turn so hosts see the follow-up response as a real turn.
struct BackgroundTaskTracking {
    /// Tasks from the provider's latest live-set announcement; replaced wholesale on every announcement.
    private(set) var live: [AgentBackgroundTask] = []
    /// Tasks the provider dropped from the live set before their terminal notification arrived. Claude announces the
    /// shrunken set first, then the notification, then the follow-up turn; counting these keeps the process alive
    /// across that gap. They leave when the notification arrives or the process ends.
    private(set) var awaitingNotification: [AgentBackgroundTask] = []
    /// Every task id this process has announced. Notifications for ids never announced here (resume drains of an
    /// earlier process's orphans) do not start a provider-initiated turn.
    private(set) var knownIDs: Set<String> = []
    /// Task ids whose terminal notification has been seen, so a later live-set shrink does not park them as awaiting.
    private var notifiedIDs: Set<String> = []

    var liveCount: Int {
        (live + awaitingNotification).filter { !$0.isAmbient }.count
    }

    mutating func apply(_ event: AgentEvent) {
        switch event {
        case let .backgroundTasks(backgroundTasks):
            replaceLiveSet(with: backgroundTasks.tasks)
        case let .subAgent(subAgent) where subAgent.phase == .terminal:
            guard let taskId = subAgent.backgroundTaskId else {
                return
            }
            notifiedIDs.insert(taskId)
            awaitingNotification.removeAll { $0.id == taskId }
        default:
            break
        }
    }

    mutating func processDidEnd() {
        live = []
        awaitingNotification = []
    }

    private mutating func replaceLiveSet(with tasks: [AgentBackgroundTask]) {
        let announcedIDs = Set(tasks.map(\.id))
        let dropped = live.filter { !announcedIDs.contains($0.id) && !notifiedIDs.contains($0.id) }
        awaitingNotification.removeAll { announcedIDs.contains($0.id) }
        for task in dropped where !awaitingNotification.contains(where: { $0.id == task.id }) {
            awaitingNotification.append(task)
        }
        live = tasks
        knownIDs.formUnion(announcedIDs)
    }
}

extension DefaultAgentRuntime {
    static let providerInitiatedTurnMetadataKey = "provider_initiated"

    /// Synthesizes `.activity(.active)` ahead of a dequeued notification for a task this process announced, when no turn
    /// is active. Claude runs a model turn to consume the notification without any host input, and that turn would
    /// otherwise be invisible to status consumers until its first frame.
    func providerInitiatedTurnStart(for event: AgentEvent, conversationId: AgentConversationID) -> AgentEvent? {
        guard case let .subAgent(subAgent) = event,
              subAgent.phase == .terminal,
              subAgent.metadata[AgentBackgroundTaskMetadata.delivery] == .string(AgentBackgroundTaskMetadata.dequeuedDelivery),
              let taskId = subAgent.backgroundTaskId,
              var state = states[conversationId],
              state.backgroundTasks.knownIDs.contains(taskId),
              !state.isTurnActive,
              state.providerInitiatedTurnId == nil else {
            return nil
        }
        let turnId = "background-task:\(taskId)"
        state.providerInitiatedTurnId = turnId
        states[conversationId] = state
        return .activity(AgentActivityEvent(
            state: .active,
            turnId: turnId,
            metadata: [Self.providerInitiatedTurnMetadataKey: .bool(true)]
        ))
    }

    /// Ends a provider-initiated turn when Claude answers the notification with a no-op result, which the adapter has
    /// downgraded to interim usage so it cannot end a host-started turn.
    func providerInitiatedTurnEnd(for event: AgentEvent, conversationId: AgentConversationID) -> AgentEvent? {
        guard case let .usage(usage) = event,
              usage.metadata[AgentBackgroundTaskMetadata.noOpResult] == .bool(true),
              var state = states[conversationId],
              let turnId = state.providerInitiatedTurnId else {
            return nil
        }
        state.providerInitiatedTurnId = nil
        states[conversationId] = state
        return .activity(AgentActivityEvent(
            state: .idle,
            turnId: turnId,
            metadata: [Self.providerInitiatedTurnMetadataKey: .bool(true)]
        ))
    }
}

private extension AgentSubAgentEvent {
    var backgroundTaskId: String? {
        guard case let .string(taskId)? = metadata[AgentBackgroundTaskMetadata.taskId], !taskId.isEmpty else {
            return nil
        }
        return taskId
    }
}

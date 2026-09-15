import Foundation

/// A harness task that keeps running inside the harness process after the turn that started it ended.
public struct AgentBackgroundTask: Codable, Equatable, Sendable {
    /// Harness task identifier, matched against the `task_id` metadata of the terminal sub-agent event that later reports it.
    public let id: String
    /// Harness task kind, such as `local_agent` or `local_bash`, when reported.
    public let kind: String?
    /// Human-readable task description when reported.
    public let description: String?
    /// Whether the harness marks the task as ambient, such as a long-lived monitor that never reports completion. Ambient
    /// tasks are excluded from `AgentRuntimeStatus.liveBackgroundTaskCount` so they cannot pin a process forever.
    public let isAmbient: Bool

    /// Creates a background task descriptor.
    public init(id: String, kind: String? = nil, description: String? = nil, isAmbient: Bool = false) {
        self.id = id
        self.kind = kind
        self.description = description
        self.isAmbient = isAmbient
    }
}

/// Metadata keys the runtime reads from harness events to track background tasks, so harness adapters and the
/// harness-neutral runtime agree without the runtime importing harness types.
public enum AgentBackgroundTaskMetadata {
    /// Sub-agent metadata key holding the harness task id that `AgentBackgroundTask.id` matches.
    public static let taskId = "task_id"
    /// Terminal sub-agent metadata key telling whether the harness is consuming the notification now (`dequeued`) or
    /// only parking it (`enqueued`). Only `dequeued` starts a harness-initiated turn.
    public static let delivery = "delivery"
    public static let dequeuedDelivery = "dequeued"
    public static let enqueuedDelivery = "enqueued"
    /// Usage metadata key set to `true` on a harness no-op result the adapter downgraded to interim usage, which ends
    /// a harness-initiated turn without ending a host-started one.
    public static let noOpResult = "provider_no_op_result"
}

/// The full set of live harness background tasks. Each event replaces the previous set rather than patching it, and an
/// empty list is a real event meaning nothing is running.
public struct AgentBackgroundTasksEvent: Codable, Equatable, Sendable {
    /// Every task the harness currently reports as live.
    public let tasks: [AgentBackgroundTask]
    /// Harness-specific metadata.
    public let metadata: [String: JSONValue]

    /// Creates a background tasks event.
    public init(tasks: [AgentBackgroundTask], metadata: [String: JSONValue] = [:]) {
        self.tasks = tasks
        self.metadata = metadata
    }

    /// Decodes the event, defaulting metadata for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tasks = try container.decodeIfPresent([AgentBackgroundTask].self, forKey: .tasks) ?? []
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

import Foundation

/// One task row in a provider-neutral task list.
public struct AgentTaskListItem: Codable, Equatable, Identifiable, Sendable {
    /// Task status used by provider task-list tools.
    public enum Status: String, Codable, Hashable, Sendable {
        /// The task has not started.
        case pending
        /// The task is actively being worked.
        case inProgress = "in_progress"
        /// The task is complete.
        case completed
        /// The task was interrupted before it completed.
        case interrupted

        /// Decodes a status, defaulting unknown future provider values to pending.
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            switch rawValue {
            case Self.pending.rawValue:
                self = .pending
            case Self.inProgress.rawValue, "inProgress":
                self = .inProgress
            case Self.completed.rawValue:
                self = .completed
            case Self.interrupted.rawValue, "cancelled", "canceled":
                self = .interrupted
            default:
                self = .pending
            }
        }
    }

    /// Provider-defined task identifier, or a provisional identifier before the provider returns one.
    public let id: String
    /// Short task title suitable for task-list rows.
    public let subject: String
    /// Optional longer task detail.
    public let description: String?
    /// Optional active-progress wording for in-progress display.
    public let activeForm: String?
    /// Current task status.
    public let status: Status

    /// Creates a task-list item.
    public init(
        id: String,
        subject: String,
        description: String? = nil,
        activeForm: String? = nil,
        status: Status = .pending
    ) {
        self.id = id
        self.subject = subject
        self.description = description
        self.activeForm = activeForm
        self.status = status
    }

    /// Decodes an item, defaulting older or partial payloads to pending status.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subject = try container.decode(String.self, forKey: .subject)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        activeForm = try container.decodeIfPresent(String.self, forKey: .activeForm)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .pending
    }
}

/// Current provider-neutral task-list state.
public struct AgentTaskListSnapshot: Codable, Equatable, Identifiable, Sendable {
    /// Stable identifier for this logical task list.
    public let id: String
    /// Ordered task rows in provider order.
    public let items: [AgentTaskListItem]

    /// Whether every task in this snapshot is complete.
    public var isComplete: Bool {
        !items.isEmpty && items.allSatisfy { $0.status == .completed }
    }

    /// Creates a task-list snapshot.
    public init(id: String, items: [AgentTaskListItem]) {
        self.id = id
        self.items = items
    }

    /// Decodes a snapshot, defaulting missing task rows to an empty list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        items = try container.decodeIfPresent([AgentTaskListItem].self, forKey: .items) ?? []
    }
}

/// A task-list state change parsed from provider events.
public struct AgentTaskListMutation: Codable, Equatable, Sendable {
    /// The kind of task-list mutation.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// A task was created from a provider tool call.
        case create
        /// A created task's provider identifier was resolved from a tool result.
        case createResult
        /// A task status was updated.
        case update
        /// The full task list was replaced from provider output.
        case replace
    }

    /// Mutation kind.
    public let kind: Kind
    /// Source tool-call identifier when known.
    public let toolCallId: String?
    /// Created or replacement item when applicable.
    public let item: AgentTaskListItem?
    /// Task identifier targeted by result/update mutations.
    public let itemId: String?
    /// Updated status when applicable.
    public let status: AgentTaskListItem.Status?
    /// Replacement task rows when applicable.
    public let items: [AgentTaskListItem]?

    /// Creates a task-list mutation.
    public init(
        kind: Kind,
        toolCallId: String? = nil,
        item: AgentTaskListItem? = nil,
        itemId: String? = nil,
        status: AgentTaskListItem.Status? = nil,
        items: [AgentTaskListItem]? = nil
    ) {
        self.kind = kind
        self.toolCallId = toolCallId
        self.item = item
        self.itemId = itemId
        self.status = status
        self.items = items
    }

    /// Decodes a mutation, allowing optional payload fields to be absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        item = try container.decodeIfPresent(AgentTaskListItem.self, forKey: .item)
        itemId = try container.decodeIfPresent(String.self, forKey: .itemId)
        status = try container.decodeIfPresent(AgentTaskListItem.Status.self, forKey: .status)
        items = try container.decodeIfPresent([AgentTaskListItem].self, forKey: .items)
    }
}

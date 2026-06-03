import Foundation

/// Stateful reducer that turns provider task-tool events into task-list snapshots.
public struct AgentTaskListReducer: Sendable {
    private static let taskToolNames: Set<String> = ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]
    private var currentSnapshot: AgentTaskListSnapshot?
    private var pendingCreatedItemIdsByToolCallId: [String: String]

    /// Current snapshot, if the reducer has seen task-list events.
    public var snapshot: AgentTaskListSnapshot? {
        currentSnapshot
    }

    /// Creates a reducer, optionally seeded with an existing snapshot.
    public init(snapshot: AgentTaskListSnapshot? = nil) {
        currentSnapshot = snapshot
        pendingCreatedItemIdsByToolCallId = [:]
    }

    /// Returns whether the tool name is part of the provider task-list tool family.
    public static func isTaskToolName(_ name: String) -> Bool {
        taskToolNames.contains(name)
    }

    /// Returns whether an event is a task-only tool discovery call that host transcripts may hide.
    public static func isTaskToolDiscovery(_ envelope: AgentEventEnvelope) -> Bool {
        guard case let .toolCall(tool) = envelope.event,
              tool.name == "ToolSearch",
              case let .object(input) = tool.input,
              case let .string(query)? = input["query"] else {
            return false
        }

        let selectedNames = selectedToolSearchNames(from: query)
        return !selectedNames.isEmpty && selectedNames.allSatisfy(taskToolNames.contains)
    }

    /// Parses a task-list mutation from one event envelope when the envelope carries one.
    public static func mutation(from envelope: AgentEventEnvelope) -> AgentTaskListMutation? {
        switch envelope.event {
        case let .toolCall(tool):
            return mutation(from: tool)
        case let .toolResult(result):
            return mutation(from: result)
        case let .task(task):
            return mutation(from: task)
        default:
            return nil
        }
    }

    /// Applies one envelope and returns an updated snapshot when the envelope changed task-list state.
    @discardableResult
    public mutating func append(_ envelope: AgentEventEnvelope) -> AgentTaskListSnapshot? {
        guard let mutation = Self.mutation(from: envelope) else {
            return nil
        }
        return apply(mutation)
    }

    /// Applies ordered envelopes and returns every snapshot emitted by task-list state changes.
    public mutating func append(contentsOf envelopes: [AgentEventEnvelope]) -> [AgentTaskListSnapshot] {
        envelopes.sorted(by: Self.eventOrder).compactMap { append($0) }
    }
}

private extension AgentTaskListReducer {
    static func mutation(from tool: AgentToolCallEvent) -> AgentTaskListMutation? {
        switch tool.name {
        case "TaskCreate":
            return taskCreateMutation(from: tool)
        case "TaskUpdate":
            return taskUpdateMutation(from: tool)
        default:
            return nil
        }
    }

    static func mutation(from result: AgentToolResultEvent) -> AgentTaskListMutation? {
        if let item = taskItem(from: result.metadata["task"]) {
            return AgentTaskListMutation(
                kind: .createResult,
                toolCallId: result.id,
                item: item,
                itemId: item.id
            )
        }

        if let items = taskItems(from: result.metadata["tasks"]) ?? taskItems(from: result.metadata["todos"]) {
            return AgentTaskListMutation(
                kind: .replace,
                toolCallId: result.id,
                items: items
            )
        }

        if let items = taskItems(fromJSONText: result.content) {
            return AgentTaskListMutation(
                kind: .replace,
                toolCallId: result.id,
                items: items
            )
        }

        guard let parsed = parsedCreatedTaskResult(result.content) else {
            return nil
        }
        return AgentTaskListMutation(
            kind: .createResult,
            toolCallId: result.id,
            item: AgentTaskListItem(id: parsed.id, subject: parsed.subject ?? ""),
            itemId: parsed.id
        )
    }

    static func mutation(from task: AgentTaskEvent) -> AgentTaskListMutation? {
        guard let items = taskItems(from: task.metadata["tasks"]) ?? taskItems(from: task.metadata["todos"]) else {
            return nil
        }
        return AgentTaskListMutation(kind: .replace, toolCallId: task.id, items: items)
    }

    static func taskCreateMutation(from tool: AgentToolCallEvent) -> AgentTaskListMutation? {
        guard case let .object(input) = tool.input,
              let subject = input.nonEmptyString("subject") else {
            return nil
        }

        let item = AgentTaskListItem(
            id: provisionalItemId(forToolCallId: tool.id),
            subject: subject,
            description: input.nonEmptyString("description"),
            activeForm: input.nonEmptyString("activeForm")
        )
        return AgentTaskListMutation(kind: .create, toolCallId: tool.id, item: item)
    }

    static func taskUpdateMutation(from tool: AgentToolCallEvent) -> AgentTaskListMutation? {
        guard case let .object(input) = tool.input,
              let taskId = input.nonEmptyString("taskId") ?? input.nonEmptyString("id"),
              let status = input.taskStatus("status") else {
            return nil
        }

        return AgentTaskListMutation(
            kind: .update,
            toolCallId: tool.id,
            itemId: taskId,
            status: status
        )
    }

    mutating func apply(_ mutation: AgentTaskListMutation) -> AgentTaskListSnapshot? {
        switch mutation.kind {
        case .create:
            return applyCreate(mutation)
        case .createResult:
            return applyCreateResult(mutation)
        case .update:
            return applyUpdate(mutation)
        case .replace:
            return applyReplace(mutation)
        }
    }

    mutating func applyCreate(_ mutation: AgentTaskListMutation) -> AgentTaskListSnapshot? {
        guard let item = mutation.item else {
            return nil
        }

        if currentSnapshot == nil || currentSnapshot?.isComplete == true {
            currentSnapshot = AgentTaskListSnapshot(
                id: "tasks-\(mutation.toolCallId ?? item.id)",
                items: []
            )
            pendingCreatedItemIdsByToolCallId.removeAll()
        }

        var items = currentSnapshot?.items ?? []
        items.append(item)
        currentSnapshot = AgentTaskListSnapshot(id: currentSnapshot?.id ?? "tasks-\(item.id)", items: items)
        if let toolCallId = mutation.toolCallId {
            pendingCreatedItemIdsByToolCallId[toolCallId] = item.id
        }
        return currentSnapshot
    }

    mutating func applyCreateResult(_ mutation: AgentTaskListMutation) -> AgentTaskListSnapshot? {
        guard let toolCallId = mutation.toolCallId,
              let provisionalId = pendingCreatedItemIdsByToolCallId.removeValue(forKey: toolCallId),
              let resolvedId = mutation.itemId,
              let snapshot = currentSnapshot else {
            return nil
        }

        var didUpdate = false
        let items = snapshot.items.map { item in
            guard item.id == provisionalId else {
                return item
            }
            didUpdate = true
            return AgentTaskListItem(
                id: resolvedId,
                subject: item.subject.isEmpty ? (mutation.item?.subject ?? item.subject) : item.subject,
                description: item.description ?? mutation.item?.description,
                activeForm: item.activeForm ?? mutation.item?.activeForm,
                status: item.status
            )
        }
        guard didUpdate else {
            return nil
        }
        currentSnapshot = AgentTaskListSnapshot(id: snapshot.id, items: items)
        return currentSnapshot
    }

    mutating func applyUpdate(_ mutation: AgentTaskListMutation) -> AgentTaskListSnapshot? {
        guard let itemId = mutation.itemId,
              let status = mutation.status,
              let snapshot = currentSnapshot,
              snapshot.items.contains(where: { $0.id == itemId }) else {
            return nil
        }

        let items = snapshot.items.map { item in
            guard item.id == itemId else {
                return item
            }
            return AgentTaskListItem(
                id: item.id,
                subject: item.subject,
                description: item.description,
                activeForm: item.activeForm,
                status: status
            )
        }
        currentSnapshot = AgentTaskListSnapshot(id: snapshot.id, items: items)
        return currentSnapshot
    }

    mutating func applyReplace(_ mutation: AgentTaskListMutation) -> AgentTaskListSnapshot? {
        guard let items = mutation.items, !items.isEmpty else {
            return nil
        }

        if currentSnapshot == nil || currentSnapshot?.isComplete == true {
            currentSnapshot = AgentTaskListSnapshot(
                id: "tasks-\(mutation.toolCallId ?? items[0].id)",
                items: items
            )
        } else if let snapshot = currentSnapshot {
            currentSnapshot = AgentTaskListSnapshot(id: snapshot.id, items: items)
        }

        pendingCreatedItemIdsByToolCallId.removeAll()
        return currentSnapshot
    }

    static func provisionalItemId(forToolCallId toolCallId: String) -> String {
        "pending-\(toolCallId)"
    }

    static func selectedToolSearchNames(from query: String) -> [String] {
        guard query.hasPrefix("select:") else {
            return []
        }
        return query
            .dropFirst("select:".count)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func taskItem(from value: JSONValue?) -> AgentTaskListItem? {
        guard case let .object(object)? = value,
              let id = object.nonEmptyString("id"),
              let subject = object.nonEmptyString("subject") ?? object.nonEmptyString("content") else {
            return nil
        }

        return AgentTaskListItem(
            id: id,
            subject: subject,
            description: object.nonEmptyString("description"),
            activeForm: object.nonEmptyString("activeForm"),
            status: object.taskStatus("status") ?? .pending
        )
    }

    static func taskItems(from value: JSONValue?) -> [AgentTaskListItem]? {
        guard case let .array(values)? = value else {
            return nil
        }
        let items = values.compactMap { taskItem(from: $0) }
        return items.isEmpty ? nil : items
    }

    static func taskItems(fromJSONText text: String) -> [AgentTaskListItem]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        if let items = taskItems(from: value) {
            return items
        }
        guard case let .object(object) = value else {
            return nil
        }
        return taskItems(from: object["tasks"]) ?? taskItems(from: object["todos"])
    }

    static func parsedCreatedTaskResult(_ content: String) -> (id: String, subject: String?)? {
        let prefix = "Task #"
        let marker = " created successfully"
        guard content.hasPrefix(prefix),
              let markerRange = content.range(of: marker) else {
            return nil
        }

        let idStartIndex = content.index(content.startIndex, offsetBy: prefix.count)
        let id = String(content[idStartIndex..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return nil
        }

        let suffix = content[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let subject: String?
        if suffix.hasPrefix(":") {
            let parsedSubject = suffix
                .dropFirst()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            subject = parsedSubject.isEmpty ? nil : parsedSubject
        } else {
            subject = nil
        }
        return (id, subject)
    }

    static func eventOrder(_ lhs: AgentEventEnvelope, _ rhs: AgentEventEnvelope) -> Bool {
        if lhs.generation == rhs.generation {
            return lhs.index < rhs.index
        }
        return lhs.generation < rhs.generation
    }
}

private extension [String: JSONValue] {
    func nonEmptyString(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func taskStatus(_ key: String) -> AgentTaskListItem.Status? {
        guard let value = nonEmptyString(key) else {
            return nil
        }
        if let status = AgentTaskListItem.Status(rawValue: value) {
            return status
        }
        switch value {
        case "inProgress":
            return .inProgress
        default:
            return nil
        }
    }
}

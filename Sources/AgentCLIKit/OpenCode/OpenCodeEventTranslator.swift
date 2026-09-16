import Foundation

/// Reconciles OpenCode v1 SSE with authoritative message snapshots without replaying completed output.
/// Root activity and interactions stay with the adapter, which owns pending HTTP requests and approvals.
struct OpenCodeEventTranslator: Sendable {
    let rootSessionID: String
    var contextWindow: Int?
    var sessionParents: [String: String] = [:]
    var sessionTools: [String: String] = [:]
    var messageInfo: [String: JSONValue] = [:]
    var parts: [String: JSONValue] = [:]
    var partOrder: [String] = []
    var emittedText: [String: String] = [:]
    var completedText = Set<String>()
    var snapshotParts = Set<String>()
    var calledTools = Set<String>()
    var finishedTools = Set<String>()
    var subAgentStates: [String: JSONValue] = [:]
    var usageStates: [String: JSONValue] = [:]
    var todoStates: [String: JSONValue] = [:]
    var compactions: [String: OpenCodeCompactionState] = [:]
    var completedCompactions = Set<String>()
    var lastReasoningPart: [String: String] = [:]
    private var sessionMetadata: JSONValue?
    private var seenEventIDs = Set<String>()
    private var eventOrder: [String] = []

    init(rootSessionID: String, contextWindow: Int? = nil) {
        self.rootSessionID = rootSessionID
        self.contextWindow = contextWindow
    }

    func contains(sessionID: String) -> Bool {
        sessionID == rootSessionID || sessionParents[sessionID] != nil
    }

    /// A child is trusted only after its parent is known; directory-wide SSE includes unrelated sessions.
    mutating func registerChild(_ info: JSONValue) {
        guard let child = info.openCodeValue("id").openCodeString,
              let parent = info.openCodeValue("parentID").openCodeString,
              child != rootSessionID, contains(sessionID: parent) else { return }
        sessionParents[child] = parent
    }

    /// Provider-local tool identifiers can repeat in another message or child session.
    func toolID(sessionID: String, messageID: String, callID: String) -> String {
        "opencode:\(sessionID):\(messageID):\(callID)"
    }

    mutating func translate(_ payload: JSONValue) -> [AgentEvent] {
        let event = payload.openCodeValue("payload").openCodeObject == nil ? payload : payload.openCodeValue("payload")
        guard let type = event.openCodeValue("type").openCodeString else { return [] }
        let properties = event.openCodeValue("properties")
        if type == "session.created" || type == "session.updated" {
            registerChild(properties.openCodeValue("info"))
        }
        guard let sessionID = sessionID(in: properties), contains(sessionID: sessionID) else { return [] }
        if let eventID = event.openCodeValue("id").openCodeString, !admit(eventID: eventID) { return [] }
        return translate(type: type, properties: properties, sessionID: sessionID)
    }

    private mutating func translate(type: String, properties: JSONValue, sessionID: String) -> [AgentEvent] {
        switch type {
        case "message.updated":
            return updateMessage(properties.openCodeValue("info"))
        case "message.part.updated":
            return updatePart(properties.openCodeValue("part"))
        case "message.part.delta":
            return updateDelta(properties)
        case "session.created", "session.updated":
            return updateSession(properties.openCodeValue("info"), sessionID: sessionID)
        case "todo.updated":
            return updateTodos(properties, sessionID: sessionID)
        case "session.compacted":
            return finishCompaction(sessionID: sessionID)
        case "session.error":
            return sessionError(properties, sessionID: sessionID)
        default:
            return []
        }
    }

    /// Hydrates a resumed transcript's deduplication state without publishing its historical output again.
    mutating func seed(messages: [JSONValue]) {
        _ = reconcile(messages: messages)
    }

    mutating func reconcile(messages: [JSONValue]) -> [AgentEvent] {
        var events: [AgentEvent] = []
        for message in messages {
            let info = message.openCodeValue("info")
            guard let sessionID = info.openCodeValue("sessionID").openCodeString,
                  let messageID = info.openCodeValue("id").openCodeString,
                  contains(sessionID: sessionID) else { continue }
            // The role and summary flag must be known before replaying parts, including completed summaries.
            messageInfo[messageKey(sessionID: sessionID, messageID: messageID)] = info
            for part in message.openCodeValue("parts").openCodeArray ?? [] {
                if let partID = part.openCodeValue("id").openCodeString {
                    snapshotParts.insert(partKey(sessionID: sessionID, messageID: messageID, partID: partID))
                }
                events += updatePart(part)
            }
            events += updateMessage(info)
        }
        return events
    }

    mutating func updateMessage(_ info: JSONValue) -> [AgentEvent] {
        guard let sessionID = info.openCodeValue("sessionID").openCodeString,
              let messageID = info.openCodeValue("id").openCodeString,
              contains(sessionID: sessionID) else { return [] }
        let key = messageKey(sessionID: sessionID, messageID: messageID)
        messageInfo[key] = info
        var events: [AgentEvent] = []
        for partID in partOrder where parts[partID]?.openCodeValue("messageID").openCodeString == messageID {
            guard let part = parts[partID], part.openCodeValue("sessionID").openCodeString == sessionID else { continue }
            events += renderPart(part)
        }
        events += usage(info, key: key)
        if info.openCodeValue("summary").openCodeBool == true {
            events += summaryCompaction(info, sessionID: sessionID, messageID: messageID)
        }
        return events
    }

    mutating func updatePart(_ incoming: JSONValue) -> [AgentEvent] {
        guard let sessionID = incoming.openCodeValue("sessionID").openCodeString,
              let messageID = incoming.openCodeValue("messageID").openCodeString,
              let partID = incoming.openCodeValue("id").openCodeString,
              contains(sessionID: sessionID) else { return [] }
        let key = partKey(sessionID: sessionID, messageID: messageID, partID: partID)
        var part = incoming
        if parts[key] == nil { partOrder.append(key) }
        if let previous = parts[key]?.openCodeValue("text").openCodeString,
           let current = incoming.openCodeValue("text").openCodeString,
           previous.hasPrefix(current), previous.count > current.count,
           incoming.openCodeValue("time").openCodeValue("end") == .null {
            // A snapshot requested before a live delta may arrive after it; never roll streaming text backward.
            part = part.openCodeSetting("text", .string(previous))
        }
        parts[key] = part
        return renderPart(part)
    }

    mutating func updateDelta(_ properties: JSONValue) -> [AgentEvent] {
        guard properties.openCodeValue("field").openCodeString == "text",
              let sessionID = properties.openCodeValue("sessionID").openCodeString,
              let messageID = properties.openCodeValue("messageID").openCodeString,
              let partID = properties.openCodeValue("partID").openCodeString,
              let delta = properties.openCodeValue("delta").openCodeString else { return [] }
        let key = partKey(sessionID: sessionID, messageID: messageID, partID: partID)
        // V1 deltas have no text offset. Buffered SSE may already be reflected in a reconnect snapshot;
        // use authoritative part updates for those parts until they finish instead of guessing overlap.
        guard !completedText.contains(key), !snapshotParts.contains(key) else { return [] }
        var part = parts[key] ?? .object([
            "id": .string(partID), "sessionID": .string(sessionID), "messageID": .string(messageID)
        ])
        if parts[key] == nil { partOrder.append(key) }
        part = part.openCodeSetting("text", .string((part.openCodeValue("text").openCodeString ?? "") + delta))
        parts[key] = part
        return renderPart(part)
    }

    mutating func renderPart(_ part: JSONValue) -> [AgentEvent] {
        switch part.openCodeValue("type").openCodeString {
        case "text", "reasoning":
            return textEvents(part)
        case "tool":
            return toolEvents(part)
        case "compaction":
            return startCompaction(part)
        default:
            return []
        }
    }

    func messageKey(sessionID: String, messageID: String) -> String { "\(sessionID):\(messageID)" }

    func partKey(sessionID: String, messageID: String, partID: String) -> String {
        "\(sessionID):\(messageID):\(partID)"
    }

    func metadata(sessionID: String, messageID: String? = nil, partID: String? = nil) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["opencode_session_id": .string(sessionID)]
        if let messageID { result["opencode_message_id"] = .string(messageID) }
        if let partID { result["opencode_part_id"] = .string(partID) }
        if let parent = sessionParents[sessionID] {
            result["opencode_parent_session_id"] = .string(parent)
            // Even before task metadata arrives, child output must never be mistaken for root output.
            result["parent_tool_use_id"] = .string(sessionTools[sessionID] ?? "opencode-child:\(sessionID)")
        }
        return result
    }

    private func sessionID(in properties: JSONValue) -> String? {
        properties.openCodeValue("sessionID").openCodeString
            ?? properties.openCodeValue("info").openCodeValue("sessionID").openCodeString
            ?? properties.openCodeValue("part").openCodeValue("sessionID").openCodeString
            ?? properties.openCodeValue("info").openCodeValue("id").openCodeString
    }

    private mutating func admit(eventID: String) -> Bool {
        guard seenEventIDs.insert(eventID).inserted else { return false }
        eventOrder.append(eventID)
        if eventOrder.count > 4_096 { seenEventIDs.remove(eventOrder.removeFirst()) }
        return true
    }

    private mutating func updateSession(_ info: JSONValue, sessionID: String) -> [AgentEvent] {
        guard sessionID == rootSessionID else { return [] }
        let title = info.openCodeValue("title")
        guard title != sessionMetadata else { return [] }
        sessionMetadata = title
        return [.sessionMetadata(AgentSessionMetadataEvent(
            harnessSessionId: AgentSessionID(rawValue: sessionID),
            name: OpenCodeSessionTitle.meaningful(title.openCodeString),
            metadata: metadata(sessionID: sessionID)
        ))]
    }
}

extension JSONValue {
    func openCodeValue(_ key: String) -> JSONValue { openCodeObject?[key] ?? .null }
    var openCodeObject: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
    var openCodeArray: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }
    var openCodeString: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
    var openCodeBool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
    var openCodeNumber: Double? {
        guard case let .number(value) = self, value.isFinite else { return nil }
        return value
    }
    var openCodeInt: Int? {
        guard let value = openCodeNumber, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }
    func openCodeSetting(_ key: String, _ value: JSONValue) -> JSONValue {
        var object = openCodeObject ?? [:]
        object[key] = value
        return .object(object)
    }
}

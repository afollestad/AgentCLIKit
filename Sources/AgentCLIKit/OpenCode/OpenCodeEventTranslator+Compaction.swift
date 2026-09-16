import Foundation

extension OpenCodeEventTranslator {
    mutating func startCompaction(_ part: JSONValue) -> [AgentEvent] {
        guard let sessionID = part.openCodeValue("sessionID").openCodeString,
              sessionID == rootSessionID,
              let messageID = part.openCodeValue("messageID").openCodeString,
              let partID = part.openCodeValue("id").openCodeString else { return [] }
        let identifier = "opencode-compaction:\(sessionID):\(partID)"
        guard !completedCompactions.contains(identifier), compactions[sessionID]?.id != identifier else { return [] }
        let state = OpenCodeCompactionState(
            id: identifier, parentMessageID: messageID,
            trigger: part.openCodeValue("auto").openCodeBool == true ? "auto" : "manual"
        )
        compactions[sessionID] = state
        return [.contextCompaction(AgentContextCompactionEvent(
            id: identifier, phase: .started, trigger: state.trigger,
            metadata: metadata(sessionID: sessionID, messageID: messageID, partID: partID)
        ))]
    }

    mutating func summaryCompaction(_ info: JSONValue, sessionID: String, messageID: String) -> [AgentEvent] {
        guard sessionID == rootSessionID,
              info.openCodeValue("time").openCodeValue("completed") != .null,
              let state = compactions[sessionID],
              info.openCodeValue("parentID").openCodeString == state.parentMessageID else { return [] }
        let error = info.openCodeValue("error")
        let summary = partOrder.compactMap { key -> String? in
            guard let part = parts[key], part.openCodeValue("sessionID").openCodeString == sessionID,
                  part.openCodeValue("messageID").openCodeString == messageID,
                  part.openCodeValue("type").openCodeString == "text" else { return nil }
            return part.openCodeValue("text").openCodeString
        }.joined(separator: "\n\n")
        return finishCompaction(
            sessionID: sessionID, summary: summary.isEmpty ? nil : summary,
            error: error == .null ? nil : errorText(error)
        )
    }

    mutating func finishCompaction(sessionID: String, summary: String? = nil, error: String? = nil) -> [AgentEvent] {
        guard sessionID == rootSessionID, let state = compactions[sessionID],
              completedCompactions.insert(state.id).inserted else { return [] }
        return [.contextCompaction(AgentContextCompactionEvent(
            id: state.id, phase: error == nil ? .completed : .failed, trigger: state.trigger,
            summary: summary, errorMessage: error,
            metadata: metadata(sessionID: sessionID, messageID: state.parentMessageID)
        ))]
    }

    mutating func sessionError(_ properties: JSONValue, sessionID: String) -> [AgentEvent] {
        let error = properties.openCodeValue("error")
        let message = errorText(error)
        // Ordinary context overflow starts native automatic compaction; only a completed
        // summary carrying that error establishes that compaction itself failed.
        let recoveringOverflow = error.openCodeValue("name").openCodeString == "ContextOverflowError"
        var events = recoveringOverflow ? [] : finishCompaction(sessionID: sessionID, error: message)
        var values = metadata(sessionID: sessionID)
        values["opencode_error"] = error
        let code: AgentDiagnosticCode? = error.openCodeValue("name").openCodeString == "ProviderAuthError"
            ? .harnessAuthenticationRequired : nil
        events.append(.diagnostic(AgentDiagnosticEvent(
            code: code, severity: recoveringOverflow ? .info : .error, message: message, metadata: values
        )))
        return events
    }

    private func errorText(_ error: JSONValue) -> String {
        error.openCodeValue("data").openCodeValue("message").openCodeString
            ?? error.openCodeValue("message").openCodeString
            ?? error.openCodeValue("name").openCodeString
            ?? "OpenCode reported an error."
    }
}

struct OpenCodeCompactionState: Sendable {
    let id: String
    let parentMessageID: String
    let trigger: String
}

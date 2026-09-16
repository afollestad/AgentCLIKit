import Foundation

extension OpenCodeEventTranslator {
    mutating func toolEvents(_ part: JSONValue) -> [AgentEvent] {
        guard let sessionID = part.openCodeValue("sessionID").openCodeString,
              let messageID = part.openCodeValue("messageID").openCodeString,
              let partID = part.openCodeValue("id").openCodeString,
              let callID = part.openCodeValue("callID").openCodeString,
              let name = part.openCodeValue("tool").openCodeString,
              let status = part.openCodeValue("state").openCodeValue("status").openCodeString,
              ["running", "completed", "error"].contains(status) else { return [] }
        let state = part.openCodeValue("state")
        let input = state.openCodeValue("input")
        let identifier = toolID(sessionID: sessionID, messageID: messageID, callID: callID)
        guard !finishedTools.contains(identifier) else { return [] }
        let terminal = status == "completed" || status == "error"
        var values = metadata(sessionID: sessionID, messageID: messageID, partID: partID)
        values["opencode_call_id"] = .string(callID)
        values["opencode_status"] = .string(status)
        values["opencode_tool_metadata"] = state.openCodeValue("metadata")
        values["tool_name"] = .string(name)
        var events: [AgentEvent] = []
        if calledTools.insert(identifier).inserted {
            events.append(.toolCall(AgentToolCallEvent(id: identifier, name: name, input: input, metadata: values)))
        }
        if name == "task" {
            events += subAgentEvents(part, identifier: identifier, metadata: values)
        }
        if terminal, finishedTools.insert(identifier).inserted {
            let content = state.openCodeValue(status == "error" ? "error" : "output").openCodeString ?? ""
            events.append(.toolResult(AgentToolResultEvent(
                id: identifier, isError: status == "error", content: content, metadata: values
            )))
        }
        return events
    }

    private mutating func subAgentEvents(
        _ part: JSONValue,
        identifier: String,
        metadata values: [String: JSONValue]
    ) -> [AgentEvent] {
        let state = part.openCodeValue("state")
        guard let sessionID = part.openCodeValue("sessionID").openCodeString,
              let status = state.openCodeValue("status").openCodeString else { return [] }
        let input = state.openCodeValue("input")
        let child = state.openCodeValue("metadata").openCodeValue("sessionId").openCodeString
        if let child, child != rootSessionID {
            sessionParents[child] = sessionID
            sessionTools[child] = identifier
        }
        let terminal = status == "completed" || status == "error"
        let signature: JSONValue = .object([
            "status": .string(status), "child": child.map(JSONValue.string) ?? .null,
            "input": input, "output": state.openCodeValue("output"), "error": state.openCodeValue("error")
        ])
        guard subAgentStates[identifier] != signature else { return [] }
        let phase: AgentSubAgentPhase = terminal ? .terminal : subAgentStates[identifier] == nil ? .started : .progress
        subAgentStates[identifier] = signature
        let start = state.openCodeValue("time").openCodeValue("start").openCodeInt
        let end = state.openCodeValue("time").openCodeValue("end").openCodeInt
        let duration = start.flatMap { start in end.map { max(0, $0 - start) } }
        return [.subAgent(AgentSubAgentEvent(
            id: identifier,
            phase: phase,
            description: input.openCodeValue("description").openCodeString,
            prompt: input.openCodeValue("prompt").openCodeString,
            agentType: input.openCodeValue("subagent_type").openCodeString,
            input: input,
            status: status,
            result: terminal ? state.openCodeValue(status == "error" ? "error" : "output").openCodeString : nil,
            durationMs: duration,
            parentToolUseId: sessionTools[sessionID],
            parentSessionId: sessionID,
            childSessionIds: child.map { [$0] } ?? [],
            metadata: values
        ))]
    }
}

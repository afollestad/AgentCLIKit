import Foundation

extension OpenCodeEventTranslator {
    mutating func textEvents(_ part: JSONValue) -> [AgentEvent] {
        guard let sessionID = part.openCodeValue("sessionID").openCodeString,
              let messageID = part.openCodeValue("messageID").openCodeString,
              let partID = part.openCodeValue("id").openCodeString,
              let text = part.openCodeValue("text").openCodeString,
              let info = messageInfo[messageKey(sessionID: sessionID, messageID: messageID)],
              let roleName = info.openCodeValue("role").openCodeString,
              let role = AgentMessageRole(rawValue: roleName),
              info.openCodeValue("summary").openCodeBool != true,
              part.openCodeValue("synthetic").openCodeBool != true,
              part.openCodeValue("ignored").openCodeBool != true else { return [] }
        let key = partKey(sessionID: sessionID, messageID: messageID, partID: partID)
        guard !completedText.contains(key) else { return [] }
        let previous = emittedText[key] ?? ""
        let values = metadata(sessionID: sessionID, messageID: messageID, partID: partID)
        let complete = part.openCodeValue("time").openCodeValue("end") != .null
            || info.openCodeValue("time").openCodeValue("completed") != .null || role == .user
        if part.openCodeValue("type").openCodeString == "reasoning" {
            let suffix = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : ""
            emittedText[key] = text
            if complete { completedText.insert(key) }
            guard !suffix.isEmpty else { return [] }
            var events: [AgentEvent] = []
            if let previousPart = lastReasoningPart[sessionID], previousPart != key {
                events.append(.reasoning(AgentReasoningEvent(text: "\n\n", metadata: values)))
            }
            lastReasoningPart[sessionID] = key
            events.append(.reasoning(AgentReasoningEvent(text: suffix, metadata: values)))
            return events
        }
        emittedText[key] = text
        if complete {
            completedText.insert(key)
            guard !text.isEmpty else { return [] }
            return [.message(AgentMessageEvent(role: role, text: text, metadata: values))]
        }
        guard role == .assistant, text.hasPrefix(previous) else { return [] }
        let suffix = String(text.dropFirst(previous.count))
        guard !suffix.isEmpty else { return [] }
        return [.messageDelta(AgentMessageDeltaEvent(role: role, text: suffix, metadata: values))]
    }

    mutating func usage(_ info: JSONValue, key: String) -> [AgentEvent] {
        guard info.openCodeValue("role").openCodeString == "assistant",
              info.openCodeValue("time").openCodeValue("completed") != .null,
              let sessionID = info.openCodeValue("sessionID").openCodeString,
              let messageID = info.openCodeValue("id").openCodeString,
              let tokens = info.openCodeValue("tokens").openCodeObject else { return [] }
        let signature: JSONValue = .object(["tokens": .object(tokens), "cost": info.openCodeValue("cost")])
        guard usageStates[key] == nil else { return [] }
        usageStates[key] = signature
        let input = tokens["input"]?.openCodeInt
        let output = tokens["output"]?.openCodeInt
        let reasoning = tokens["reasoning"]?.openCodeInt
        let cacheRead = tokens["cache"]?.openCodeValue("read").openCodeInt
        let cacheWrite = tokens["cache"]?.openCodeValue("write").openCodeInt
        // OpenCode separates both cache categories from input and reasoning from output (Session.getUsage).
        // Match Claude's noncached-input contract and keep cachedInputTokens unset to avoid double counting.
        let outputWithReasoning = sumTokens([output, reasoning])
        let total = tokens["total"]?.openCodeInt ?? sumTokens([input, output, reasoning, cacheRead, cacheWrite])
        var values = metadata(sessionID: sessionID, messageID: messageID)
        values["opencode_tokens"] = .object(tokens)
        values["opencode_finish"] = info.openCodeValue("finish")
        values["reasoning_output_tokens"] = tokens["reasoning"]
        values["opencode_provider_id"] = info.openCodeValue("providerID")
        if info.openCodeValue("error") != .null { values["opencode_error"] = info.openCodeValue("error") }
        let model = info.openCodeValue("modelID").openCodeString.map { modelID in
            info.openCodeValue("providerID").openCodeString.map { "\($0)/\(modelID)" } ?? modelID
        }
        return [.usage(AgentUsageEvent(
            model: model,
            inputTokens: input,
            outputTokens: outputWithReasoning,
            cacheReadInputTokens: cacheRead,
            cacheCreationInputTokens: cacheWrite,
            totalTokens: total,
            costUSD: info.openCodeValue("cost").openCodeNumber,
            contextWindow: contextWindow,
            stopReason: AgentUsageEvent.interimUsageStopReason,
            isTerminal: false,
            // Generic runtime treats isError as terminal even on interim usage; the client owns root failures.
            isError: false,
            metadata: values
        ))]
    }

    mutating func updateTodos(_ properties: JSONValue, sessionID: String) -> [AgentEvent] {
        let todos = properties.openCodeValue("todos")
        guard let list = todos.openCodeArray, todoStates[sessionID] != todos else { return [] }
        todoStates[sessionID] = todos
        let normalized = list.enumerated().map { index, item -> JSONValue in
            let status = item.openCodeValue("status").openCodeString
            return .object([
                "id": item.openCodeValue("id") == .null ? .string("opencode-todo:\(sessionID):\(index)") : item.openCodeValue("id"),
                "subject": item.openCodeValue("content"),
                "status": .string(status == "in_progress" ? "inProgress" : status ?? "pending")
            ])
        }
        var values = metadata(sessionID: sessionID)
        values["todos"] = .array(normalized)
        values["opencode_todos"] = todos
        return [.task(AgentTaskEvent(
            id: "opencode-todos:\(sessionID)", phase: .progress, description: "Tasks updated",
            taskType: "plan", status: "updated", metadata: values
        ))]
    }

    private func sumTokens(_ counts: [Int?]) -> Int? {
        let known = counts.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        var total = 0
        for count in known {
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

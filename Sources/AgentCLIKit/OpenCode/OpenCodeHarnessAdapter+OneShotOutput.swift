import Foundation

/// Accept final text only from the terminal native model step; tool preambles and incomplete output are not a result.
extension OpenCodeHarnessAdapter {
    /// Parses `run --format json`, rejecting native errors and missing completion even when the process exits successfully.
    public func finalOneShotPromptText(stdout: String, stderr: String, request: AgentOneShotPromptRequest) async throws -> String {
        var state = OpenCodeOneShotOutput()
        // Native JSON records end with ASCII LF; Unicode line separators can occur unescaped inside JSON strings.
        for line in stdout.utf8.split(separator: 0x0A) {
            let value: JSONValue
            do { value = try JSONDecoder().decode(JSONValue.self, from: Data(line)) } catch {
                throw AgentOneShotPromptError.malformedOutput(
                    harnessId: .opencode, message: "Expected a native JSON event.", stdout: stdout, stderr: stderr
                )
            }
            try state.consume(value, stdout: stdout, stderr: stderr)
        }
        guard let terminal = state.terminalMessage, state.finishReason == "stop" else {
            throw AgentOneShotPromptError.malformedOutput(
                harnessId: .opencode, message: "No successful terminal model step was received.", stdout: stdout, stderr: stderr
            )
        }
        return state.parts.filter { $0.messageID == terminal }.map(\.text).joined(separator: "\n")
    }
}

private struct OpenCodeOneShotOutput {
    struct Part {
        let id: String
        let messageID: String
        let text: String
    }
    var sessionID: String?
    var parts: [Part] = []
    var terminalMessage: String?
    var finishReason: String?

    mutating func consume(_ value: JSONValue, stdout: String, stderr: String) throws {
        guard let type = value[oc: "type"]?.ocString else {
            throw malformed("Missing native event type.", stdout: stdout, stderr: stderr)
        }
        if type == "error" {
            let message = value[oc: "error"]?[oc: "data"]?[oc: "message"]?.ocString
                ?? value[oc: "error"]?[oc: "name"]?.ocString ?? "OpenCode reported an error."
            throw AgentOneShotPromptError.harnessReportedError(harnessId: .opencode, message: message, stdout: stdout, stderr: stderr)
        }
        guard let session = value[oc: "sessionID"]?.ocString, !session.isEmpty,
              let part = value[oc: "part"], let message = part[oc: "messageID"]?.ocString else {
            throw malformed("Missing native session or message identity.", stdout: stdout, stderr: stderr)
        }
        if let sessionID, sessionID != session { throw malformed("Mixed native sessions.", stdout: stdout, stderr: stderr) }
        sessionID = session
        try consumePart(part, type: type, message: message, stdout: stdout, stderr: stderr)
    }

    private mutating func consumePart(_ part: JSONValue, type: String, message: String, stdout: String, stderr: String) throws {
        switch type {
        case "step_start":
            terminalMessage = nil
            finishReason = nil
        case "step_finish":
            terminalMessage = message
            finishReason = part[oc: "reason"]?.ocString
        case "text":
            guard let id = part[oc: "id"]?.ocString, let text = part[oc: "text"]?.ocString,
                  part[oc: "time"]?[oc: "end"]?.ocInt != nil else {
                throw malformed("Incomplete native text part.", stdout: stdout, stderr: stderr)
            }
            if let index = parts.firstIndex(where: { $0.id == id }) { parts.remove(at: index) }
            parts.append(Part(id: id, messageID: message, text: text))
        case "tool_use":
            try validateTool(part[oc: "tool"]?.ocString ?? "unknown")
        case "reasoning": break
        default: throw malformed("Unrecognized native event: \(type)", stdout: stdout, stderr: stderr)
        }
    }

    private func validateTool(_ tool: String) throws {
        if tool == "question" { throw AgentOneShotPromptError.promptRequired(harnessId: .opencode, message: "A question was requested.") }
        guard ["read", "glob", "grep"].contains(tool) else {
            throw AgentOneShotPromptError.approvalRequired(harnessId: .opencode, message: "A forbidden tool was requested: \(tool)")
        }
    }

    private func malformed(_ message: String, stdout: String, stderr: String) -> AgentOneShotPromptError {
        .malformedOutput(harnessId: .opencode, message: message, stdout: stdout, stderr: stderr)
    }
}

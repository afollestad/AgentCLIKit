import AgentCLIKit
import Foundation

extension DemoModel {
    static func sessionStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("AgentCLIKitDemo", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    static func prettyJSONString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    static func usageSummary(_ usage: AgentUsageEvent) -> String {
        var parts: [String] = []
        if let model = usage.model {
            parts.append("model: \(model)")
        }
        if let inputTokens = usage.inputTokens {
            parts.append("input: \(inputTokens)")
        }
        if let outputTokens = usage.outputTokens {
            parts.append("output: \(outputTokens)")
        }
        return parts.isEmpty ? "usage" : parts.joined(separator: ", ")
    }

    static func rateLimitSummary(_ rateLimit: AgentRateLimitEvent) -> String {
        var parts = [rateLimit.status.rawValue.replacingOccurrences(of: "_", with: " ")]
        if let limitType = rateLimit.limitType {
            parts.append(limitType)
        }
        if let utilization = rateLimit.utilization {
            parts.append("\(Int((utilization * 100).rounded()))%")
        }
        if let resetDate = rateLimit.resetDate {
            parts.append("resets \(resetDate.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: ", ")
    }

    static func isTerminalUsage(_ usage: AgentUsageEvent) -> Bool {
        usage.isTerminal
    }

    static func taskSummary(_ task: AgentTaskEvent) -> String {
        let label = task.description ?? task.taskType ?? "Task"
        return "\(label): \(task.phase.rawValue)"
    }

    static func statusSummary(_ status: AgentRuntimeStatus, current: DemoTurnState) -> String? {
        if case let .blocked(reason) = status.inputAvailability {
            return reason
        }
        if let streamingText = current.streamingText, !streamingText.isEmpty, status.isProcessRunning {
            return "Streaming"
        }
        var parts = [status.state.rawValue.capitalized]
        if let permissionMode = status.permissionMode {
            parts.append("permission: \(permissionMode)")
        }
        if let processIdentifier = status.processIdentifier, status.isProcessRunning {
            parts.append("pid: \(processIdentifier)")
        }
        return parts.joined(separator: " - ")
    }

    static func providerStatusSummary(_ status: AgentProviderStatus) -> String {
        if !status.isEnabled {
            return "\(status.definition?.displayName ?? status.providerId.rawValue) is disabled."
        }
        if !status.isInstalled {
            return status.diagnostics.first ?? "\(status.definition?.displayName ?? status.providerId.rawValue) is not installed."
        }
        if !status.isSetupReady {
            return status.diagnostics.first ?? "\(status.definition?.displayName ?? status.providerId.rawValue) needs setup."
        }
        if let projectTrust = status.projectTrust, !projectTrust.allowsProviderWork {
            return "Project trust is required for \(status.definition?.displayName ?? status.providerId.rawValue)."
        }
        return "\(status.definition?.displayName ?? status.providerId.rawValue) ready"
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func eventSummary(_ event: AgentEvent) -> String {
        switch event {
        case .message(let message):
            let source = metadataString(message.metadata["claude_event_type"]).map { " source=\($0)" } ?? ""
            return "message role=\(message.role.rawValue) length=\(message.text.count)\(source)"
        case .messageDelta(let delta):
            return "message_delta length=\(delta.text.count)"
        case .reasoning(let reasoning):
            return "reasoning length=\(reasoning.text.count)"
        case .toolCall(let toolCall):
            return "tool_call name=\(toolCall.name)"
        case .toolResult(let toolResult):
            return "tool_result id=\(toolResult.id) error=\(toolResult.isError)"
        case .usage(let usage):
            let stopReason = usage.stopReason ?? "nil"
            return "usage stop_reason=\(stopReason)"
        case .rateLimit(let rateLimit):
            return "rate_limit \(rateLimitSummary(rateLimit))"
        case .activity(let activity):
            let turnId = activity.turnId.map { " turn_id=\($0)" } ?? ""
            return "activity state=\(activity.state.rawValue)\(turnId)"
        case .permissionMode(let permissionMode):
            return "permission_mode mode=\(permissionMode.mode)"
        case .task(let task):
            return "task phase=\(task.phase.rawValue) id=\(task.id)"
        case .contextCompaction(let compaction):
            return "context_compaction phase=\(compaction.phase.rawValue) id=\(compaction.id)"
        case .sessionContinuity(let continuity):
            return "session_continuity continuity=\(continuity.continuity.rawValue)"
        case .interaction(let interaction):
            return "interaction kind=\(interaction.kind.rawValue)"
        case .lifecycle(let lifecycle):
            return "lifecycle state=\(lifecycle.state.rawValue)"
        case .diagnostic(let diagnostic):
            let rawLine = metadataString(diagnostic.metadata["raw_stdout_line"])
            let suffix = rawLine.map { " raw_stdout_line=\(truncated($0))" } ?? ""
            return "diagnostic severity=\(diagnostic.severity.rawValue) message=\(diagnostic.message)\(suffix)"
        case .rawOutput(let rawOutput):
            return "raw_output complete=\(rawOutput.isComplete) length=\(rawOutput.text.count)"
        }
    }

    static func currentTurnStartIndex(in rows: [DemoChatRow]) -> Int {
        guard let userIndex = rows.lastIndex(where: isUserMessage) else {
            return rows.startIndex
        }
        return rows.index(after: userIndex)
    }

    static func isUsageRow(_ row: DemoChatRow) -> Bool {
        if case .usage = row.kind {
            return true
        }
        return false
    }

    static func metadataString(_ value: JSONValue?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    static func contextCompactionSummary(_ compaction: AgentContextCompactionEvent) -> String {
        switch compaction.phase {
        case .started:
            return "Compacting context"
        case .completed:
            return compaction.summary ?? "Context compacted"
        case .failed:
            return compaction.errorMessage ?? "Context compaction failed"
        }
    }

    private static func isUserMessage(_ row: DemoChatRow) -> Bool {
        if case .message(role: .user, text: _) = row.kind {
            return true
        }
        return false
    }

    private static func truncated(_ value: String, limit: Int = 500) -> String {
        guard value.count > limit else {
            return value
        }
        return "\(value.prefix(limit))..."
    }
}

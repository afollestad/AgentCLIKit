import Foundation

struct CodexSessionTranscriptPlan: Equatable, Sendable {
    let itemId: String
    let turnId: String
    let text: String
    let completedAtMs: Int?

    var recoveryKey: CodexSessionTranscriptPlanRecoveryKey {
        Self.recoveryKey(turnId: turnId, itemId: itemId, text: text)
    }

    static func recoveryKey(
        turnId: String,
        itemId: String,
        text: String
    ) -> CodexSessionTranscriptPlanRecoveryKey {
        CodexSessionTranscriptPlanRecoveryKey(turnId: turnId, itemId: itemId, text: text)
    }

    var runtimeEvent: AgentProviderRuntimeEvent {
        var metadata: [String: JSONValue] = [
            AgentPlanProposalMetadata.isProposal: .bool(true),
            AgentPlanProposalMetadata.proposalId: .string(itemId),
            AgentPlanProposalMetadata.planMarkdown: .string(text),
            "codex_method": .string("item_completed"),
            "codex_source": .string("session_transcript"),
            "codex_turn_id": .string(turnId),
            "codex_item_id": .string(itemId),
            "codex_item_type": .string("Plan"),
            "codex_item_phase": .string("completed")
        ]
        if let completedAtMs {
            metadata["completed_at_ms"] = .number(Double(completedAtMs))
        }
        return AgentProviderRuntimeEvent(
            event: .message(AgentMessageEvent(role: .assistant, text: text, metadata: metadata)),
            source: .runtime
        )
    }
}

struct CodexSessionTranscriptPlanRecoveryKey: Hashable, Sendable {
    let turnId: String
    let itemId: String
    let text: String
}

struct CodexSessionTranscriptPlanReader: Sendable {
    private let codexHomeDirectory: URL

    init(codexHomeDirectory: URL) {
        self.codexHomeDirectory = codexHomeDirectory
    }

    func completedPlans(threadId: AgentSessionID) -> [CodexSessionTranscriptPlan] {
        guard let sessionFileURL = sessionFileURL(threadId: threadId) else {
            return []
        }
        return completedPlans(threadId: threadId, sessionFileURL: sessionFileURL)
    }

    func completedPlans(threadId: AgentSessionID, sessionFileURL: URL) -> [CodexSessionTranscriptPlan] {
        guard let contents = try? String(contentsOf: sessionFileURL, encoding: .utf8) else {
            return []
        }
        var seenPlanKeys = Set<CodexSessionTranscriptPlanRecoveryKey>()
        var plans: [CodexSessionTranscriptPlan] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let plan = completedPlan(threadId: threadId, line: String(line)),
                  seenPlanKeys.insert(plan.recoveryKey).inserted else {
                continue
            }
            plans.append(plan)
        }
        return plans
    }

    func sessionFileURL(threadId: AgentSessionID) -> URL? {
        let sessionsDirectory = codexHomeDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let suffix = "\(threadId.rawValue).jsonl"
        var matches: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent.hasSuffix(suffix) {
            matches.append(fileURL)
        }
        return matches.sorted { $0.path > $1.path }.first
    }

    private func completedPlan(threadId: AgentSessionID, line: String) -> CodexSessionTranscriptPlan? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.codexTranscriptObjectValue,
              object.codexTranscriptStringValue("type") == "event_msg",
              let payload = object["payload"]?.codexTranscriptObjectValue,
              payload.codexTranscriptStringValue("type") == "item_completed",
              payload.codexTranscriptStringValue("thread_id", "threadId") == threadId.rawValue,
              let turnId = payload.codexTranscriptStringValue("turn_id", "turnId"),
              let item = payload["item"]?.codexTranscriptObjectValue,
              item.codexTranscriptStringValue("type") == "Plan",
              let itemId = item.codexTranscriptStringValue("id"),
              let text = item.codexTranscriptStringValue("text") else {
            return nil
        }
        return CodexSessionTranscriptPlan(
            itemId: itemId,
            turnId: turnId,
            text: text,
            completedAtMs: payload.codexTranscriptIntValue("completed_at_ms", "completedAtMs")
        )
    }
}

extension CodexAppServerNotification {
    var shouldRecoverTranscriptPlanItems: Bool {
        method == "thread/tokenUsage/updated" || completedTurnId != nil || marksThreadIdle
    }

    var transcriptPlanRecoveryTurnId: String? {
        guard let params = params?.codexTranscriptObjectValue else {
            return nil
        }
        if let turnId = params.codexTranscriptStringValue("turnId", "turn_id") {
            return turnId
        }
        return params["turn"]?.codexTranscriptObjectValue?.codexTranscriptStringValue("id")
    }

    var completedPlanRecoveryKey: CodexSessionTranscriptPlanRecoveryKey? {
        guard method == "item/completed" || method == "item_completed",
              let params = params?.codexTranscriptObjectValue,
              let turnId = params.codexTranscriptStringValue("turnId", "turn_id")
                ?? params["turn"]?.codexTranscriptObjectValue?.codexTranscriptStringValue("id"),
              let item = params["item"]?.codexTranscriptObjectValue,
              item.codexTranscriptStringValue("type") == "Plan",
              let itemId = item.codexTranscriptStringValue("id"),
              let text = item.codexTranscriptStringValue("text") else {
            return nil
        }
        return CodexSessionTranscriptPlan.recoveryKey(turnId: turnId, itemId: itemId, text: text)
    }
}

private extension [String: JSONValue] {
    func codexTranscriptStringValue(_ keys: String...) -> String? {
        keys.lazy.compactMap { key -> String? in
            guard case let .string(value)? = self[key], !value.isEmpty else {
                return nil
            }
            return value
        }.first
    }

    func codexTranscriptIntValue(_ keys: String...) -> Int? {
        keys.lazy.compactMap { key -> Int? in
            guard let value = self[key] else {
                return nil
            }
            switch value {
            case let .number(number):
                return Int(number)
            case let .string(string):
                return Int(string)
            default:
                return nil
            }
        }.first
    }
}

private extension JSONValue {
    var codexTranscriptObjectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }
}

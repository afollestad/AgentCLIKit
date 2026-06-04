import Foundation

actor ClaudeContextCompactionTracker {
    private struct State {
        var counter = 0
        var currentId: String?
        var terminalSeen = false
        var emittedPhaseKeys: Set<String> = []
    }

    private struct HookPayloadDetails {
        let trigger: String?
        let summary: String?
        let compactError: String?
        let compactResult: String?
        let preTokens: Int?
        let postTokens: Int?
        let durationMs: Int?
    }

    private var states: [UUID: State] = [:]

    func normalize(_ events: [AgentEvent], context: AgentProviderOutputContext) -> [AgentEvent] {
        events.flatMap { event -> [AgentEvent] in
            guard case let .contextCompaction(compaction) = event else {
                return [event]
            }
            return normalize(compaction, processToken: context.processToken).map(AgentEvent.contextCompaction)
        }
    }

    func hookEvents(
        hookName: String,
        conversationId: AgentConversationID,
        processToken: UUID,
        payload: JSONValue
    ) -> [AgentProviderRuntimeEvent] {
        guard let phase = AgentContextCompactionPhase(claudeHookName: hookName, payload: payload) else {
            return []
        }
        let details = hookPayloadDetails(from: payload)
        let compaction = AgentContextCompactionEvent(
            id: "claude-context-compaction-\(processToken.uuidString)",
            phase: phase,
            trigger: details.trigger,
            summary: details.summary,
            errorMessage: details.compactError,
            preTokens: details.preTokens,
            postTokens: details.postTokens,
            durationMs: details.durationMs,
            metadata: metadata(
                conversationId: conversationId,
                processToken: processToken,
                values: [
                    "claude_hook_name": .string(hookName),
                    "session_id": payload.compactStringValue("session_id").map(JSONValue.string)
                        ?? payload.compactStringValue("sessionId").map(JSONValue.string),
                    "trigger": details.trigger.map(JSONValue.string),
                    "transcript_path": payload.compactStringValue("transcript_path").map(JSONValue.string),
                    "cwd": payload.compactStringValue("cwd").map(JSONValue.string),
                    "compact_summary": details.summary.map(JSONValue.string),
                    "compact_result": details.compactResult.map(JSONValue.string),
                    "compact_error": details.compactError.map(JSONValue.string),
                    "pre_tokens": details.preTokens.map { .number(Double($0)) },
                    "post_tokens": details.postTokens.map { .number(Double($0)) },
                    "duration_ms": details.durationMs.map { .number(Double($0)) }
                ]
            )
        )
        return normalize(compaction, processToken: processToken).map {
            AgentProviderRuntimeEvent(event: .contextCompaction($0), source: .hook)
        }
    }

    func reset(processToken: UUID) {
        states[processToken] = nil
    }

    private func hookPayloadDetails(from payload: JSONValue) -> HookPayloadDetails {
        let compactMetadata = payload.compactObjectValue("compact_metadata") ?? payload.compactObjectValue("compactMetadata")
        return HookPayloadDetails(
            trigger: payload.compactStringValue("trigger") ?? compactMetadata?.compactStringValue("trigger"),
            summary: payload.compactStringValue("compact_summary")
                ?? payload.compactStringValue("compactSummary")
                ?? payload.compactStringValue("summary"),
            compactError: payload.compactStringValue("compact_error") ?? payload.compactStringValue("compactError"),
            compactResult: payload.compactStringValue("compact_result") ?? payload.compactStringValue("compactResult"),
            preTokens: payload.compactIntValue("pre_tokens")
                ?? payload.compactIntValue("preTokens")
                ?? compactMetadata?.compactIntValue("pre_tokens")
                ?? compactMetadata?.compactIntValue("preTokens"),
            postTokens: payload.compactIntValue("post_tokens")
                ?? payload.compactIntValue("postTokens")
                ?? compactMetadata?.compactIntValue("post_tokens")
                ?? compactMetadata?.compactIntValue("postTokens"),
            durationMs: payload.compactIntValue("duration_ms")
                ?? payload.compactIntValue("durationMs")
                ?? compactMetadata?.compactIntValue("duration_ms")
                ?? compactMetadata?.compactIntValue("durationMs")
        )
    }

    private func normalize(_ compaction: AgentContextCompactionEvent, processToken: UUID) -> [AgentContextCompactionEvent] {
        var state = states[processToken] ?? State()
        if compaction.phase == .started, shouldStartNewCycle(state: state) {
            state.counter += 1
            state.currentId = stableId(processToken: processToken, sessionId: sessionId(from: compaction), counter: state.counter)
            state.terminalSeen = false
        }
        if compaction.phase.isTerminal, state.currentId == nil {
            state.counter += 1
            state.currentId = stableId(processToken: processToken, sessionId: sessionId(from: compaction), counter: state.counter)
        }

        let id = state.currentId ?? stableId(processToken: processToken, sessionId: sessionId(from: compaction), counter: state.counter)
        let normalized = AgentContextCompactionEvent(
            id: id,
            phase: compaction.phase,
            trigger: compaction.trigger,
            summary: compaction.summary,
            errorMessage: compaction.errorMessage,
            preTokens: compaction.preTokens,
            postTokens: compaction.postTokens,
            durationMs: compaction.durationMs,
            metadata: compaction.metadata
        )
        let phaseKey = "\(normalized.id)\u{1F}\(normalized.phase.rawValue)"
        guard !state.emittedPhaseKeys.contains(phaseKey) else {
            states[processToken] = state
            return []
        }
        state.emittedPhaseKeys.insert(phaseKey)
        if normalized.phase == .started {
            state.currentId = normalized.id
        }
        if normalized.phase.isTerminal {
            state.terminalSeen = true
        }
        states[processToken] = state
        return [normalized]
    }

    private func shouldStartNewCycle(state: State) -> Bool {
        guard let currentId = state.currentId else {
            return true
        }
        let startedKey = "\(currentId)\u{1F}\(AgentContextCompactionPhase.started.rawValue)"
        return state.terminalSeen && state.emittedPhaseKeys.contains(startedKey)
    }

    private func stableId(processToken: UUID, sessionId: String?, counter: Int) -> String {
        let sessionPart = sessionId?.isEmpty == false ? sessionId ?? processToken.uuidString : processToken.uuidString
        return "claude-context-compaction-\(sessionPart)-\(counter)"
    }

    private func sessionId(from compaction: AgentContextCompactionEvent) -> String? {
        compaction.metadata.compactStringValue("session_id") ?? compaction.metadata.compactStringValue("sessionId")
    }

    private func metadata(
        conversationId: AgentConversationID,
        processToken: UUID,
        values: [String: JSONValue?]
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "conversation_id": .string(conversationId.rawValue),
            "process_token": .string(processToken.uuidString)
        ]
        for (key, value) in values {
            guard let value, value != .null else {
                continue
            }
            metadata[key] = value
        }
        return metadata
    }
}

private extension AgentContextCompactionPhase {
    init?(claudeHookName: String, payload: JSONValue) {
        switch claudeHookName {
        case "PreCompact":
            self = .started
        case "PostCompact":
            let result = payload.compactStringValue("compact_result") ?? payload.compactStringValue("compactResult")
            let error = payload.compactStringValue("compact_error") ?? payload.compactStringValue("compactError")
            self = result == "failed" || error != nil ? .failed : .completed
        default:
            return nil
        }
    }
}

private extension JSONValue {
    func compactObjectValue(_ key: String) -> [String: JSONValue]? {
        guard case let .object(object) = self,
              case let .object(value)? = object[key] else {
            return nil
        }
        return value
    }

    func compactIntValue(_ key: String) -> Int? {
        guard case let .object(object) = self else {
            return nil
        }
        return object.compactIntValue(key)
    }

    func compactStringValue(_ key: String) -> String? {
        guard case let .object(object) = self,
              case let .string(value)? = object[key],
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension [String: JSONValue] {
    func compactIntValue(_ key: String) -> Int? {
        guard case let .number(value)? = self[key] else {
            return nil
        }
        return Int(value)
    }

    func compactStringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

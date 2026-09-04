import Foundation

/// Keeps Claude's no-op `result` frames from ending a turn.
///
/// After consuming a `<task-notification>` Claude may answer with a synthetic "No response requested." assistant
/// message and a `result` carrying zero usage and no `stop_reason`; on `--resume` it drains several of these for
/// orphaned tasks before touching the real prompt. The decoder marks every `result` terminal, so each drained frame
/// would end the host's turn early. The zero-usage shape alone cannot be the filter: Claude answers an unknown slash
/// command with the same shape, and hosts rely on that result staying terminal. Instead the tracker arms on
/// task-notification traffic (or the synthetic message itself) and rewrites only the no-op results that follow, until
/// real assistant content or a real terminal result disarms it.
actor ClaudeNoOpTurnTracker {
    static let noResponseRequestedText = "No response requested."

    private var armedProcessTokens: Set<UUID> = []

    func normalize(_ events: [AgentEvent], context: AgentProviderOutputContext) -> [AgentEvent] {
        events.compactMap { normalize($0, processToken: context.processToken) }
    }

    func reset(processToken: UUID) {
        armedProcessTokens.remove(processToken)
    }

    private func normalize(_ event: AgentEvent, processToken: UUID) -> AgentEvent? {
        switch event {
        case let .subAgent(subAgent) where subAgent.phase == .terminal
            && subAgent.metadata[AgentBackgroundTaskMetadata.delivery] != nil:
            armedProcessTokens.insert(processToken)
            return event
        case let .message(message) where message.role == .assistant:
            guard message.text.trimmingCharacters(in: .whitespacesAndNewlines) == Self.noResponseRequestedText else {
                armedProcessTokens.remove(processToken)
                return event
            }
            armedProcessTokens.insert(processToken)
            return nil
        case let .messageDelta(delta) where delta.role == .assistant:
            armedProcessTokens.remove(processToken)
            return event
        case .toolCall, .reasoning:
            armedProcessTokens.remove(processToken)
            return event
        case let .usage(usage) where usage.isTerminal:
            guard armedProcessTokens.contains(processToken), usage.isNoOpResult else {
                armedProcessTokens.remove(processToken)
                return event
            }
            return .usage(usage.asInterimNoOpResult)
        default:
            return event
        }
    }
}

private extension AgentUsageEvent {
    var isNoOpResult: Bool {
        !isError
            && stopReason == nil
            && permissionDenials.isEmpty
            && (inputTokens ?? 0) == 0
            && (outputTokens ?? 0) == 0
            && (cacheReadInputTokens ?? 0) == 0
            && (cacheCreationInputTokens ?? 0) == 0
    }

    var asInterimNoOpResult: AgentUsageEvent {
        var metadata = metadata
        metadata[AgentBackgroundTaskMetadata.noOpResult] = .bool(true)
        metadata["stop_reason"] = .string(Self.interimUsageStopReason)
        return AgentUsageEvent(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            totalTokens: totalTokens,
            toolUses: toolUses,
            durationMs: durationMs,
            costUSD: costUSD,
            contextWindow: contextWindow,
            stopReason: Self.interimUsageStopReason,
            isTerminal: false,
            isError: false,
            permissionDenials: [],
            metadata: metadata
        )
    }
}

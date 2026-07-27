extension ClaudeStreamDecoder {
    func streamEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard let event = envelope.event else {
            return []
        }
        switch event.type {
        case "content_block_start":
            return contentBlockStartEvents(from: envelope, event: event)
        case "content_block_delta":
            return contentBlockDeltaEvents(from: envelope, event: event)
        default:
            return []
        }
    }

    /// A new thinking block starts its own reasoning section, so separate it from the previous one.
    /// This also fires for the first thinking block of a turn; hosts drop a leading break.
    private func contentBlockStartEvents(from envelope: ClaudeStreamEnvelope, event: ClaudeStreamEvent) -> [AgentEvent] {
        guard event.contentBlock?.type == "thinking" else {
            return []
        }
        return [.reasoning(AgentReasoningEvent(text: "\n\n", metadata: envelope.parentMetadata))]
    }

    private func contentBlockDeltaEvents(from envelope: ClaudeStreamEnvelope, event: ClaudeStreamEvent) -> [AgentEvent] {
        guard let delta = event.delta else {
            return []
        }
        switch delta.type {
        case "text_delta":
            guard let text = delta.text, !text.isEmpty else {
                return []
            }
            return [.messageDelta(AgentMessageDeltaEvent(role: .assistant, text: text, metadata: envelope.parentMetadata))]
        case "thinking_delta":
            guard let thinking = delta.thinking, !thinking.isEmpty else {
                return []
            }
            return [.reasoning(AgentReasoningEvent(text: thinking, metadata: envelope.parentMetadata))]
        default:
            return []
        }
    }
}

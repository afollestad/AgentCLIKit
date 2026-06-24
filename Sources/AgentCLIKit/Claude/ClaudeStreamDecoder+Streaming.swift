extension ClaudeStreamDecoder {
    func streamEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard envelope.event?.type == "content_block_delta",
              let delta = envelope.event?.delta else {
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

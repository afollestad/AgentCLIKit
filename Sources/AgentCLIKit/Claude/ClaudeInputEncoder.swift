import Foundation

/// Encodes generic host input into Claude stream JSON stdin messages.
public struct ClaudeInputEncoder: Sendable {
    /// Creates a Claude input encoder.
    public init() {}

    /// Encodes one generic input value for Claude stdin.
    ///
    /// Interaction resolutions encode as empty data: the Claude CLI has no stdin message type for them.
    /// Claude interactions resolve through hook decisions and deferred-tool resume instead, so the runtime's
    /// resolution bookkeeping proceeds without writing anything to the provider process.
    public func encode(_ input: AgentInput) throws -> Data {
        let payload: ClaudeInputPayload
        switch input {
        case let .userMessage(message):
            try Self.validateNoAttachments(message)
            payload = ClaudeInputPayload.user(text: message.text)
        case .interrupt:
            payload = ClaudeInputPayload(type: "interrupt", message: nil)
        case .interactionResolution:
            return Data()
        }
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        return data
    }

    private static func validateNoAttachments(_ message: AgentMessageInput) throws {
        guard let attachment = message.attachments.first else {
            return
        }
        throw AgentCLIError.unsupportedInputAttachment(
            providerId: ClaudeProviderAdapter.providerId,
            attachmentId: attachment.id,
            type: attachment.type,
            reason: "Claude input transport is text-only."
        )
    }
}

private struct ClaudeInputPayload: Codable {
    let type: String
    let message: ClaudeInputMessage?

    static func user(text: String) -> ClaudeInputPayload {
        ClaudeInputPayload(
            type: "user",
            message: ClaudeInputMessage(role: "user", content: [ClaudeInputContent(type: "text", text: text)])
        )
    }
}

private struct ClaudeInputMessage: Codable {
    let role: String
    let content: [ClaudeInputContent]
}

private struct ClaudeInputContent: Codable {
    let type: String
    let text: String
}

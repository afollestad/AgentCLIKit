import Foundation

/// Encodes generic host input into Claude stream JSON stdin messages.
public struct ClaudeInputEncoder: Sendable {
    /// Creates a Claude input encoder.
    public init() {}

    /// Encodes one generic input value for Claude stdin.
    public func encode(_ input: AgentInput) throws -> Data {
        let payload: ClaudeInputPayload
        switch input {
        case let .userMessage(message):
            payload = ClaudeInputPayload.user(text: message.text)
        case .interrupt:
            payload = ClaudeInputPayload(type: "interrupt", message: nil, resolution: nil)
        case let .interactionResolution(resolution):
            payload = ClaudeInputPayload.resolution(resolution)
        }
        var data = try JSONEncoder().encode(payload)
        data.append(0x0A)
        return data
    }
}

private struct ClaudeInputPayload: Codable {
    let type: String
    let message: ClaudeInputMessage?
    let resolution: ClaudeInputResolution?

    static func user(text: String) -> ClaudeInputPayload {
        ClaudeInputPayload(
            type: "user",
            message: ClaudeInputMessage(role: "user", content: [ClaudeInputContent(type: "text", text: text)]),
            resolution: nil
        )
    }

    static func resolution(_ resolution: AgentInteractionResolution) -> ClaudeInputPayload {
        ClaudeInputPayload(
            type: "interaction_resolution",
            message: nil,
            resolution: ClaudeInputResolution(
                id: resolution.id.rawValue,
                outcome: resolution.outcome.rawValue,
                responseText: resolution.responseText,
                metadata: resolution.metadata
            )
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

private struct ClaudeInputResolution: Codable {
    let id: String
    let outcome: String
    let responseText: String?
    let metadata: [String: JSONValue]
}

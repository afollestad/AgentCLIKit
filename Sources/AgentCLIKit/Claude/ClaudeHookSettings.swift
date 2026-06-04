import Foundation

/// Claude hook settings payload for registering AgentCLIKit's local hook endpoint.
public struct ClaudeHookSettings: Equatable, Sendable {
    /// Local HTTP endpoint that Claude should call for `PreToolUse`.
    public let endpointURL: URL
    /// Whether `PreToolUse` hook registration should be included.
    public let includePreToolUse: Bool
    /// Local HTTP endpoint that Claude should call for `PreCompact`.
    public let preCompactEndpointURL: URL?
    /// Local HTTP endpoint that Claude should call for `PostCompact`.
    public let postCompactEndpointURL: URL?
    /// Environment variable name that holds the bearer token.
    public let tokenEnvironmentVariable: String
    /// Claude hook timeout in seconds.
    public let timeoutSeconds: Int

    /// Creates Claude hook settings.
    public init(
        endpointURL: URL,
        includePreToolUse: Bool = true,
        preCompactEndpointURL: URL? = nil,
        postCompactEndpointURL: URL? = nil,
        tokenEnvironmentVariable: String = "AGENTCLIKIT_CLAUDE_HOOK_TOKEN",
        timeoutSeconds: Int = ClaudeHookPolicy.defaultHookTimeoutSeconds
    ) {
        self.endpointURL = endpointURL
        self.includePreToolUse = includePreToolUse
        self.preCompactEndpointURL = preCompactEndpointURL
        self.postCompactEndpointURL = postCompactEndpointURL
        self.tokenEnvironmentVariable = tokenEnvironmentVariable
        self.timeoutSeconds = timeoutSeconds
    }

    /// Encodes Claude-compatible settings JSON.
    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private var payload: ClaudeHookSettingsPayload {
        var hooks: [String: [ClaudeHookMatcher]] = [:]
        if includePreToolUse {
            hooks["PreToolUse"] = [
                matcher(ClaudeHookPolicy.preToolUseMatcher, endpointURL: endpointURL)
            ]
        }
        if let preCompactEndpointURL {
            hooks["PreCompact"] = [
                matcher(ClaudeHookPolicy.compactMatcher, endpointURL: preCompactEndpointURL)
            ]
        }
        if let postCompactEndpointURL {
            hooks["PostCompact"] = [
                matcher(ClaudeHookPolicy.compactMatcher, endpointURL: postCompactEndpointURL)
            ]
        }
        return ClaudeHookSettingsPayload(hooks: hooks)
    }

    private func matcher(_ matcher: String, endpointURL: URL) -> ClaudeHookMatcher {
        ClaudeHookMatcher(
            matcher: matcher,
            hooks: [
                ClaudeHookTransport(
                    type: "http",
                    url: endpointURL.absoluteString,
                    timeout: timeoutSeconds,
                    headers: ["Authorization": "Bearer $\(tokenEnvironmentVariable)"],
                    allowedEnvVars: [tokenEnvironmentVariable]
                )
            ]
        )
    }
}

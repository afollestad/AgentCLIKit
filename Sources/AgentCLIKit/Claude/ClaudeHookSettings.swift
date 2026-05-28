import Foundation

/// Claude hook settings payload for registering AgentCLIKit's local hook endpoint.
public struct ClaudeHookSettings: Equatable, Sendable {
    /// Local HTTP endpoint that Claude should call for `PreToolUse`.
    public let endpointURL: URL
    /// Environment variable name that holds the bearer token.
    public let tokenEnvironmentVariable: String
    /// Claude hook timeout in seconds.
    public let timeoutSeconds: Int

    /// Creates Claude hook settings.
    public init(
        endpointURL: URL,
        tokenEnvironmentVariable: String = "AGENTCLIKIT_CLAUDE_HOOK_TOKEN",
        timeoutSeconds: Int = ClaudeHookPolicy.defaultHookTimeoutSeconds
    ) {
        self.endpointURL = endpointURL
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
        ClaudeHookSettingsPayload(hooks: [
            "PreToolUse": [
                ClaudeHookMatcher(
                    matcher: ClaudeHookPolicy.preToolUseMatcher,
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
            ]
        ])
    }
}

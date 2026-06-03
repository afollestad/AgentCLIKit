import Foundation

/// Static Codex provider metadata.
public enum CodexProviderDefinition {
    /// Codex provider identifier.
    public static let providerId: AgentProviderID = .codex

    /// Codex provider definition used by registries and discovery services.
    public static let definition = AgentProviderDefinition(
        id: providerId,
        displayName: "Codex",
        executableNames: ["codex"],
        capabilities: AgentProviderCapabilities(
            supportsSessionResume: true,
            supportsMCP: true,
            supportsApprovals: true,
            supportsUsage: true,
            supportsMidTurnSteering: true,
            supportsToolEvents: true,
            supportsGroupedToolOutput: true,
            supportsPlanMode: true,
            supportsTaskLists: true,
            supportsSubagents: true,
            supportsPromptRequests: true,
            supportsContextWindow: true,
            supportsNativeThreadFork: true,
            supportsPermissionPrompts: true,
            supportsModelListing: true
        ),
        supportedPermissionModes: [
            AgentProviderOption(
                value: "untrusted",
                label: "Untrusted",
                description: "Only known-safe read-only commands run without approval; other commands prompt."
            ),
            AgentProviderOption(
                value: "on-request",
                label: "On request",
                description: "Codex decides when to request approval for higher-risk commands."
            ),
            AgentProviderOption(
                value: "never",
                label: "Never ask",
                description: "Codex never prompts for command approval and returns failures directly to the model."
            )
        ]
    )
}

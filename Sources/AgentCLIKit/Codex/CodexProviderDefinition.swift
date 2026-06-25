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
            supportsGoalMode: true,
            supportsExistingSessionGoalStart: true,
            supportedGoalActions: [.pause, .resume, .delete],
            supportsTaskLists: true,
            supportsSubagents: true,
            supportsPromptRequests: true,
            supportsContextWindow: true,
            supportsContextCompaction: true,
            supportsNativeThreadFork: true,
            supportsPermissionPrompts: true,
            supportsModelOptions: true,
            supportsSessionArchiving: true,
            supportsSessionUnarchiving: true,
            supportsLocalImageInput: true
        ),
        supportedPermissionModes: [
            AgentProviderOption(
                value: "untrusted",
                label: "Ask for approval",
                description: "Always ask to edit external files and use the internet."
            ),
            AgentProviderOption(
                value: "on-request",
                label: "Approve for me",
                description: "Only ask for actions detected as potentially unsafe."
            ),
            AgentProviderOption(
                value: "never",
                label: "Full access",
                description: "Unrestricted access to the internet and any file on your computer."
            )
        ]
    )
}

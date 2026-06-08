import Foundation

/// Static Claude Code provider metadata.
public enum ClaudeProviderDefinition {
    /// Claude provider identifier.
    public static let providerId: AgentProviderID = .claude

    /// Claude provider definition used by registries and runtime adapters.
    public static let definition = AgentProviderDefinition(
        id: providerId,
        displayName: "Claude",
        executableNames: ["claude"],
        capabilities: AgentProviderCapabilities(
            supportsSessionResume: true,
            supportsHooks: true,
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
            supportsContextCompaction: true,
            supportsNativeThreadFork: true,
            supportsPermissionPrompts: true,
            supportsModelOptions: true
        ),
        supportedPermissionModes: [
            AgentProviderOption(
                value: "default",
                label: "Default",
                description: "Ask before file edits and restricted tool actions."
            ),
            AgentProviderOption(
                value: "acceptEdits",
                label: "Accept edits",
                description: "Automatically allow file edits, but ask for other sensitive actions."
            ),
            AgentProviderOption(
                value: "auto",
                label: "Automatic",
                description: "Automatically approve most actions with safety checks."
            )
        ]
    )
}

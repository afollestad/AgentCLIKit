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
                label: "Default permissions",
                description: "Safe default; denied writes return as tool errors in non-interactive mode."
            ),
            AgentProviderOption(
                value: "acceptEdits",
                label: "Accept edits",
                description: "Auto-accept file edits while keeping stronger checks for other actions."
            ),
            AgentProviderOption(
                value: "auto",
                label: "Automatic",
                description: "Auto-approve most actions with safety checks."
            )
        ]
    )
}

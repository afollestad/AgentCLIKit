import Foundation

/// Static Codex harness metadata.
public enum CodexHarnessDefinition {
    /// Codex harness identifier.
    public static let harnessId: AgentHarnessID = .codex

    /// Codex harness definition used by registries and discovery services.
    public static let definition = AgentHarnessDefinition(
        id: harnessId,
        displayName: "Codex",
        executableNames: ["codex"],
        capabilities: AgentHarnessCapabilities(
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
            supportsSessionDeletion: true,
            supportsLocalImageInput: true,
            supportsReadOnlyOneShotPrompts: true,
            supportedIntegrationIsolation: [.nativeIntegrations, .shellNetwork]
        ),
        supportedPermissionModes: [
            AgentHarnessOption(
                value: "untrusted",
                label: "Ask for approval",
                description: "Always ask to edit external files and use the internet."
            ),
            AgentHarnessOption(
                value: "on-request",
                label: "Approve for me",
                description: "Only ask for actions detected as potentially unsafe."
            ),
            AgentHarnessOption(
                value: "never",
                label: "Full access",
                description: "Unrestricted access to the internet and any file on your computer."
            )
        ]
    )
}

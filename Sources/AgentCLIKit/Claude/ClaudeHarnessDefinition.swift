import Foundation

/// Static Claude Code harness metadata.
public enum ClaudeHarnessDefinition {
    /// Claude harness identifier.
    public static let harnessId: AgentHarnessID = .claude

    /// Claude harness definition used by registries and runtime adapters.
    public static let definition = AgentHarnessDefinition(
        id: harnessId,
        displayName: "Claude",
        executableNames: ["claude"],
        capabilities: AgentHarnessCapabilities(
            supportsSessionResume: true,
            supportsHooks: true,
            supportsMCP: true,
            supportsApprovals: true,
            supportsUsage: true,
            supportsMidTurnSteering: true,
            supportsToolEvents: true,
            supportsGroupedToolOutput: true,
            supportsPlanMode: true,
            supportsGoalMode: true,
            supportsExistingSessionGoalStart: true,
            supportedGoalActions: [.delete],
            supportsTaskLists: true,
            supportsSubagents: true,
            supportsPromptRequests: true,
            supportsContextWindow: true,
            supportsContextCompaction: true,
            supportsNativeThreadFork: true,
            supportsPermissionPrompts: true,
            supportsModelOptions: true,
            supportsReadOnlyOneShotPrompts: true
        ),
        supportedPermissionModes: [
            AgentHarnessOption(
                value: "default",
                label: "Default",
                description: "Ask before file edits and restricted tool actions."
            ),
            AgentHarnessOption(
                value: "acceptEdits",
                label: "Accept edits",
                description: "Automatically allow file edits, but ask for other sensitive actions."
            ),
            AgentHarnessOption(
                value: "auto",
                label: "Automatic",
                description: "Automatically approve most actions with safety checks."
            ),
            AgentHarnessOption(
                value: ClaudePermissionModes.bypassPermissions,
                label: "Bypass permissions",
                description: "Bypass all permission checks. Recommended only for sandboxed environments with no internet access."
            )
        ]
    )
}

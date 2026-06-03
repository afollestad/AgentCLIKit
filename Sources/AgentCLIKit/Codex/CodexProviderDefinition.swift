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
        )
    )
}

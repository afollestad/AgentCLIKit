import Foundation

/// Source of selectable harness model options.
public protocol AgentModelOptionSource: Sendable {
    /// Returns model options for the harness.
    func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption]
}

/// Static model option source.
public struct StaticAgentModelOptionSource: AgentModelOptionSource {
    private let optionsByHarness: [AgentHarnessID: [AgentModelOption]]

    /// Creates a static model option source.
    public init(optionsByHarness: [AgentHarnessID: [AgentModelOption]] = [:]) {
        self.optionsByHarness = optionsByHarness
    }

    /// Returns static model options for the harness.
    public func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption] {
        optionsByHarness[harnessId] ?? AgentDefaultModelOptions.harnessDefault(for: harnessId)
    }
}

/// Built-in model option source that routes to harness-specific defaults.
public struct DefaultAgentModelOptionSource: AgentModelOptionSource {
    private let claudeSource: any AgentModelOptionSource
    private let codexSource: (any AgentModelOptionSource)?
    private let openCodeSource: (any AgentModelOptionSource)?

    /// Creates the default model option source.
    /// - Parameters:
    ///   - claudeSource: Source for Claude model options.
    ///   - codexSource: Optional live or host-provided source for Codex model options.
    ///   - openCodeSource: Optional source for OpenCode provider/model options.
    public init(
        claudeSource: any AgentModelOptionSource = ClaudeModelOptionSource(),
        codexSource: (any AgentModelOptionSource)? = nil,
        openCodeSource: (any AgentModelOptionSource)? = nil
    ) {
        self.claudeSource = claudeSource
        self.codexSource = codexSource
        self.openCodeSource = openCodeSource
    }

    /// Returns model options from the matching harness-specific source.
    public func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption] {
        switch harnessId {
        case .claude:
            return await claudeSource.modelOptions(for: harnessId)
        case .codex:
            guard let codexSource else {
                return AgentDefaultModelOptions.staticOptions(for: harnessId)
            }
            return await codexSource.modelOptions(for: harnessId)
        case .opencode:
            return await openCodeSource?.modelOptions(for: harnessId) ?? AgentDefaultModelOptions.staticOptions(for: harnessId)
        }
    }
}

/// Built-in static model options used as safe discovery fallbacks.
public enum AgentDefaultModelOptions {
    /// Returns the static model options a host can show before harness discovery completes.
    ///
    /// For harnesses whose catalog is authored in the package (Claude), this is exactly the list discovery later
    /// reports, so a cold-start UI and a discovered one render the same labels and effort ladders. Harnesses whose
    /// model list requires a live source (Codex or OpenCode) fall back to the single harness-default option.
    public static func staticOptions(for harnessId: AgentHarnessID) -> [AgentModelOption] {
        switch harnessId {
        case .claude:
            return ClaudeModelOptionSource.staticModelOptions
        case .codex:
            return harnessDefault(for: harnessId, description: "Use the Codex default model.")
        case .opencode:
            return harnessDefault(for: harnessId, label: "Use OpenCode default", description: "Use the OpenCode default model.")
        }
    }

    /// Returns a harness-default model option.
    public static func harnessDefault(
        for harnessId: AgentHarnessID,
        label: String = "Harness default",
        description: String? = nil
    ) -> [AgentModelOption] {
        [
            AgentModelOption(
                harnessId: harnessId,
                id: "default",
                model: nil,
                label: label,
                description: description,
                isDefault: true
            )
        ]
    }
}

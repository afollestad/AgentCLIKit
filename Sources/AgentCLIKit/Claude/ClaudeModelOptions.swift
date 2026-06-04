import Foundation

/// Claude model option source backed by built-in Claude CLI model aliases.
public struct ClaudeModelOptionSource: AgentModelOptionSource {
    /// Creates a Claude model option source.
    public init() {}

    /// Returns Claude model options with model-scoped effort metadata.
    public func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption] {
        guard providerId == ClaudeProviderDefinition.providerId else {
            return AgentDefaultModelOptions.providerDefault(for: providerId)
        }
        let defaultEfforts = Self.effortOptions(["low", "medium", "high", "max"])
        let opusEfforts = Self.effortOptions(["low", "medium", "high", "xhigh", "max"])
        return [
            AgentModelOption(
                providerId: providerId,
                id: "default",
                model: nil,
                label: "Provider default",
                description: "Use the Claude CLI default model.",
                isDefault: true,
                supportedEffortOptions: defaultEfforts,
                defaultEffortOption: Self.effortOption("medium")
            ),
            AgentModelOption(
                providerId: providerId,
                id: "sonnet",
                model: "sonnet",
                label: "Sonnet",
                description: "Use Claude's Sonnet model alias.",
                supportedEffortOptions: defaultEfforts,
                defaultEffortOption: Self.effortOption("medium")
            ),
            AgentModelOption(
                providerId: providerId,
                id: "opus",
                model: "opus",
                label: "Opus",
                description: "Use Claude's Opus model alias.",
                supportedEffortOptions: opusEfforts,
                defaultEffortOption: Self.effortOption("xhigh")
            )
        ]
    }

    private static func effortOptions(_ values: [String]) -> [AgentProviderOption] {
        values.map(effortOption)
    }

    private static func effortOption(_ value: String) -> AgentProviderOption {
        AgentProviderOption(
            value: value,
            label: effortLabel(for: value),
            description: "Use \(effortLabel(for: value).lowercased()) reasoning effort."
        )
    }

    private static func effortLabel(for value: String) -> String {
        switch value {
        case "xhigh":
            return "XHigh"
        default:
            return value.capitalized
        }
    }
}

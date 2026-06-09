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
        let sonnetEfforts = Self.effortOptions(ClaudeModelAliases.supportedEfforts(for: ClaudeModelAliases.defaultModel))
        let fableEfforts = Self.effortOptions(ClaudeModelAliases.supportedEfforts(for: "fable"))
        let opusEfforts = Self.effortOptions(ClaudeModelAliases.supportedEfforts(for: "opus"))
        let haikuEfforts = Self.effortOptions(ClaudeModelAliases.supportedEfforts(for: "haiku"))
        return [
            AgentModelOption(
                providerId: providerId,
                id: ClaudeModelAliases.defaultModel,
                model: ClaudeModelAliases.defaultModel,
                label: "Sonnet",
                description: "Use Claude's Sonnet model alias.",
                isDefault: true,
                supportedEffortOptions: sonnetEfforts,
                defaultEffortOption: Self.effortOption("high")
            ),
            AgentModelOption(
                providerId: providerId,
                id: "fable",
                model: "fable",
                label: "Fable",
                description: "Use Claude's Fable model alias.",
                supportedEffortOptions: fableEfforts,
                defaultEffortOption: Self.effortOption("high")
            ),
            AgentModelOption(
                providerId: providerId,
                id: "opus",
                model: "opus",
                label: "Opus",
                description: "Use Claude's Opus model alias.",
                supportedEffortOptions: opusEfforts,
                defaultEffortOption: Self.effortOption("high")
            ),
            AgentModelOption(
                providerId: providerId,
                id: "haiku",
                model: "haiku",
                label: "Haiku",
                description: "Use Claude's Haiku model alias.",
                supportedEffortOptions: haikuEfforts,
                defaultEffortOption: Self.effortOption("medium")
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
            return "Extra High"
        default:
            return value.capitalized
        }
    }
}

enum ClaudeModelAliases {
    static let defaultModel = "sonnet"

    static func normalizedModel(_ model: String?) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isLegacyDefaultModel(model) ? defaultModel : trimmed
    }

    static func normalizedEffort(_ effort: String?, model: String?) -> String? {
        let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedModel = normalizedModel(model)
        if trimmed.isEmpty {
            return defaultEffort(for: normalizedModel)
        }
        if isLegacyDefaultModel(model), trimmed.lowercased() == "medium" {
            return defaultEffort(for: normalizedModel)
        }
        let supportedEfforts = supportedEfforts(for: normalizedModel)
        guard !supportedEfforts.isEmpty else {
            return trimmed
        }
        let normalizedEffort = trimmed.lowercased()
        if supportedEfforts.contains(normalizedEffort) {
            return normalizedEffort
        }
        return defaultEffort(for: normalizedModel)
    }

    static func supportedEfforts(for model: String) -> [String] {
        switch model.lowercased() {
        case "haiku":
            return ["low", "medium", "high"]
        case "fable", "opus":
            return ["low", "medium", "high", "xhigh", "max"]
        case "sonnet":
            return ["low", "medium", "high", "max"]
        default:
            return []
        }
    }

    private static func defaultEffort(for model: String) -> String? {
        switch model.lowercased() {
        case "haiku":
            return "medium"
        case "fable", "opus", "sonnet":
            return "high"
        default:
            return nil
        }
    }

    private static func isLegacyDefaultModel(_ model: String?) -> Bool {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed.lowercased() == "default"
    }
}

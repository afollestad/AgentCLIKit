import Foundation

/// Claude model option source backed by the authored `ClaudeModelCatalog`.
public struct ClaudeModelOptionSource: AgentModelOptionSource {
    /// Creates a Claude model option source.
    public init() {}

    /// Returns Claude model options with model-scoped effort metadata.
    public func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption] {
        guard providerId == ClaudeProviderDefinition.providerId else {
            return AgentDefaultModelOptions.providerDefault(for: providerId)
        }
        return Self.staticModelOptions
    }

    /// Claude's authored model catalog mapped to selectable options.
    ///
    /// Available synchronously because `ClaudeModelCatalog` is static: discovery reports exactly this list for Claude,
    /// so hosts can render it before discovery completes instead of flashing a raw model id.
    public static var staticModelOptions: [AgentModelOption] {
        ClaudeModelCatalog.entries.map { entry in
            AgentModelOption(
                providerId: ClaudeProviderDefinition.providerId,
                id: entry.id,
                model: entry.id,
                label: entry.label,
                shortName: entry.shortName,
                description: "Use Claude's \(entry.label) model.",
                isDefault: entry.isDefault,
                supportedEffortOptions: entry.supportedEfforts.map(effortOption),
                defaultEffortOption: effortOption(entry.defaultEffort)
            )
        }
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

/// Selectable Claude models and their effort metadata.
///
/// The Claude CLI has no model-listing command, so this table is the only source hosts have for the models they can
/// offer. Every entry is a pinned version: the bare family aliases (`sonnet`, `opus`, `fable`, `haiku`) are not options
/// of their own, they survive only as `shortName` on the newest entry of each family. That keeps typed input such as
/// `/model opus` working, keeps a host's already-persisted alias selection resolvable, and keeps effort lookup working
/// for a launch that still passes a bare alias as `--model`.
enum ClaudeModelCatalog {
    /// One selectable Claude model.
    struct Entry {
        /// Value passed to `--model`, and the option id hosts persist.
        let id: String
        /// User-facing label.
        let label: String
        /// Family alias hosts accept as typed input, or `nil` when only `id` names this model.
        let shortName: String?
        /// Effort values offered for this model, in display order.
        let supportedEfforts: [String]
        /// Effort applied when a launch names this model without one.
        let defaultEffort: String
        /// Whether hosts should preselect this model.
        let isDefault: Bool

        init(
            id: String,
            label: String,
            shortName: String? = nil,
            supportedEfforts: [String],
            defaultEffort: String,
            isDefault: Bool = false
        ) {
            self.id = id
            self.label = label
            self.shortName = shortName
            self.supportedEfforts = supportedEfforts
            self.defaultEffort = defaultEffort
            self.isDefault = isDefault
        }
    }

    /// Families run strongest first, newest version first within each. Grouping wins over capability across families,
    /// so an older version of a stronger family still sits above a newer one from a weaker family.
    static let entries: [Entry] = [
        Entry(
            id: "claude-fable-5-1",
            label: "Fable 5.1",
            shortName: "fable",
            supportedEfforts: fullEfforts,
            defaultEffort: "high"
        ),
        Entry(
            id: "claude-fable-5",
            label: "Fable 5",
            supportedEfforts: fullEfforts,
            defaultEffort: "high"
        ),
        Entry(
            id: "claude-opus-5",
            label: "Opus 5",
            shortName: "opus",
            supportedEfforts: fullEfforts,
            defaultEffort: "high"
        ),
        Entry(
            id: "claude-opus-4-8",
            label: "Opus 4.8",
            supportedEfforts: fullEfforts,
            defaultEffort: "high"
        ),
        Entry(
            id: "claude-opus-4-7",
            label: "Opus 4.7",
            supportedEfforts: fullEfforts,
            defaultEffort: "high"
        ),
        Entry(
            id: "claude-opus-4-6",
            label: "Opus 4.6",
            supportedEfforts: effortsBeforeExtraHigh,
            defaultEffort: "high"
        ),
        Entry(
            id: "claude-sonnet-5",
            label: "Sonnet 5",
            shortName: "sonnet",
            supportedEfforts: fullEfforts,
            defaultEffort: "high",
            isDefault: true
        ),
        Entry(
            id: "claude-sonnet-4-6",
            label: "Sonnet 4.6",
            supportedEfforts: effortsBeforeExtraHigh,
            defaultEffort: "high"
        ),
        Entry(
            id: "claude-haiku-4-5",
            label: "Haiku 4.5",
            shortName: "haiku",
            supportedEfforts: haikuEfforts,
            defaultEffort: "medium"
        )
    ]

    /// Resolves a launch `--model` value, which is either a catalog id or a bare family alias.
    static func entry(forModel model: String) -> Entry? {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return nil
        }
        return entries.first { $0.id == normalized || $0.shortName == normalized }
    }

    private static let fullEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// `xhigh` postdates Opus 4.6 and Sonnet 4.6, so their ladders skip it.
    private static let effortsBeforeExtraHigh = ["low", "medium", "high", "max"]
    private static let haikuEfforts = ["low", "medium", "high"]
}

/// Normalizes the model and effort a host supplies into the values Claude's CLI is launched with.
///
/// `ClaudeModelCatalog` owns which models exist; this owns what a launch does with one, including values a host
/// persisted before pinned versions were selectable.
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

    /// Empty for a model outside the catalog, which leaves an explicitly requested effort untouched.
    private static func supportedEfforts(for model: String) -> [String] {
        ClaudeModelCatalog.entry(forModel: model)?.supportedEfforts ?? []
    }

    private static func defaultEffort(for model: String) -> String? {
        ClaudeModelCatalog.entry(forModel: model)?.defaultEffort
    }

    private static func isLegacyDefaultModel(_ model: String?) -> Bool {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed.lowercased() == "default"
    }
}

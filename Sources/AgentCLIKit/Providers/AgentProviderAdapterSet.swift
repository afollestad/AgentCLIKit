import Foundation

/// Runtime-ready provider adapters and their matching static definitions.
public struct AgentProviderAdapterSet: Sendable {
    /// Provider adapters available to a runtime.
    public let adapters: [any AgentProviderAdapter]

    /// Static provider metadata exposed by the same adapter instances used for runtime launches.
    public var definitions: [AgentProviderDefinition] {
        adapters.map(\.definition)
    }

    /// Built-in AgentCLIKit providers using their default configuration.
    public static let `default` = AgentProviderAdapterSet(adapters: [
        ClaudeProviderAdapter()
    ])

    /// Creates the built-in provider set with a custom Claude configuration.
    public static func `default`(claude: ClaudeProviderAdapter.Configuration) -> AgentProviderAdapterSet {
        AgentProviderAdapterSet(adapters: [
            ClaudeProviderAdapter(configuration: claude)
        ])
    }

    /// Creates a provider set from the exact adapters supplied.
    /// Duplicate provider IDs keep the last adapter so override behavior matches `DefaultAgentRuntime(adapters:)`.
    public init(adapters: [any AgentProviderAdapter]) {
        self.adapters = Self.uniqueAdapters(adapters)
    }

    /// Creates a provider set by applying explicit adapters over an existing base set.
    /// Duplicate provider IDs keep the explicit adapter.
    public init(
        base: AgentProviderAdapterSet = .default,
        overriding adapters: [any AgentProviderAdapter]
    ) {
        self.adapters = Self.uniqueAdapters(base.adapters + adapters)
    }

    private static func uniqueAdapters(_ adapters: [any AgentProviderAdapter]) -> [any AgentProviderAdapter] {
        var orderedIds: [AgentProviderID] = []
        var keyedAdapters: [AgentProviderID: any AgentProviderAdapter] = [:]
        for adapter in adapters {
            let id = adapter.definition.id
            if keyedAdapters[id] == nil {
                orderedIds.append(id)
            }
            keyedAdapters[id] = adapter
        }
        return orderedIds.compactMap { keyedAdapters[$0] }
    }
}

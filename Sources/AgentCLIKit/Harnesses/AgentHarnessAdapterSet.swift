import Foundation

/// Runtime-ready harness adapters and their matching static definitions.
public struct AgentHarnessAdapterSet: Sendable {
    /// Harness adapters available to a runtime.
    public let adapters: [any AgentHarnessAdapter]

    /// Static harness metadata exposed by the same adapter instances used for runtime launches.
    public var definitions: [AgentHarnessDefinition] {
        adapters.map(\.definition)
    }

    /// Built-in AgentCLIKit harnesses using their default configuration.
    public static let `default` = AgentHarnessAdapterSet(adapters: [
        ClaudeHarnessAdapter(),
        CodexHarnessAdapter()
    ])

    /// Creates the built-in harness set with custom harness configurations.
    public static func `default`(
        claude: ClaudeHarnessAdapter.Configuration,
        codex: CodexHarnessAdapter.Configuration = CodexHarnessAdapter.Configuration()
    ) -> AgentHarnessAdapterSet {
        AgentHarnessAdapterSet(adapters: [
            ClaudeHarnessAdapter(configuration: claude),
            CodexHarnessAdapter(configuration: codex)
        ])
    }

    /// Creates a harness set from the exact adapters supplied.
    /// Duplicate harness IDs keep the last adapter so override behavior matches `DefaultAgentRuntime(adapters:)`.
    public init(adapters: [any AgentHarnessAdapter]) {
        self.adapters = Self.uniqueAdapters(adapters)
    }

    /// Creates a harness set by applying explicit adapters over an existing base set.
    /// Duplicate harness IDs keep the explicit adapter.
    public init(
        base: AgentHarnessAdapterSet = .default,
        overriding adapters: [any AgentHarnessAdapter]
    ) {
        self.adapters = Self.uniqueAdapters(base.adapters + adapters)
    }

    private static func uniqueAdapters(_ adapters: [any AgentHarnessAdapter]) -> [any AgentHarnessAdapter] {
        var orderedIds: [AgentHarnessID] = []
        var keyedAdapters: [AgentHarnessID: any AgentHarnessAdapter] = [:]
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

import Foundation

/// Runtime-ready harness adapters and their matching static definitions.
public struct AgentHarnessAdapterSet: Sendable {
    /// Harness adapters available to a runtime.
    public let adapters: [any AgentHarnessAdapter]

    /// Static harness metadata exposed by the same adapter instances used for runtime launches.
    public var definitions: [AgentHarnessDefinition] {
        adapters.map(\.definition)
    }

    /// Creates independent built-in adapters; shutting down one runtime must not close another runtime's clients.
    public static var `default`: AgentHarnessAdapterSet {
        AgentHarnessAdapterSet(adapters: [
            ClaudeHarnessAdapter(),
            CodexHarnessAdapter(),
            OpenCodeHarnessAdapter()
        ])
    }

    /// Creates the built-in harness set with custom harness configurations.
    public static func `default`(
        claude: ClaudeHarnessAdapter.Configuration,
        codex: CodexHarnessAdapter.Configuration = CodexHarnessAdapter.Configuration(),
        opencode: OpenCodeHarnessAdapter.Configuration = OpenCodeHarnessAdapter.Configuration()
    ) -> AgentHarnessAdapterSet {
        AgentHarnessAdapterSet(adapters: [
            ClaudeHarnessAdapter(configuration: claude),
            CodexHarnessAdapter(configuration: codex),
            OpenCodeHarnessAdapter(configuration: opencode)
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

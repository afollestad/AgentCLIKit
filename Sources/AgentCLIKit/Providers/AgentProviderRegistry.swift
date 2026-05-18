import Foundation

/// Mutable registry of provider definitions known to a host application.
public actor AgentProviderRegistry {
    private var definitions: [AgentProviderID: AgentProviderDefinition]

    /// Creates a provider registry.
    public init(definitions: [AgentProviderDefinition] = []) {
        self.definitions = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Registers or replaces a provider definition.
    public func register(_ definition: AgentProviderDefinition) {
        definitions[definition.id] = definition
    }

    /// Removes a provider definition.
    public func unregister(_ providerId: AgentProviderID) {
        definitions[providerId] = nil
    }

    /// Returns a provider definition by identifier.
    public func definition(for providerId: AgentProviderID) -> AgentProviderDefinition? {
        definitions[providerId]
    }

    /// Returns all registered provider definitions sorted by identifier.
    public func allDefinitions() -> [AgentProviderDefinition] {
        definitions.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}

/// Read-only provider lookup contract used by services that should not mutate registration.
public protocol AgentProviderLookup: Sendable {
    /// Returns a provider definition by identifier.
    func definition(for providerId: AgentProviderID) async -> AgentProviderDefinition?

    /// Returns all registered provider definitions.
    func allDefinitions() async -> [AgentProviderDefinition]
}

extension AgentProviderRegistry: AgentProviderLookup {}

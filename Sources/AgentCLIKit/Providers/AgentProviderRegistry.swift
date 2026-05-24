import Foundation

/// Mutable registry of provider definitions known to a host application.
public actor AgentProviderRegistry {
    private var definitions: [AgentProviderID: AgentProviderDefinition]
    private var readinessSubscribers: [UUID: AsyncStream<[AgentProviderReadiness]>.Continuation] = [:]

    /// Creates a provider registry.
    public init(definitions: [AgentProviderDefinition] = []) {
        self.definitions = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Registers or replaces a provider definition.
    public func register(_ definition: AgentProviderDefinition) {
        definitions[definition.id] = definition
        publishReadinessSnapshot()
    }

    /// Removes a provider definition.
    public func unregister(_ providerId: AgentProviderID) {
        definitions[providerId] = nil
        publishReadinessSnapshot()
    }

    /// Returns a provider definition by identifier.
    public func definition(for providerId: AgentProviderID) -> AgentProviderDefinition? {
        definitions[providerId]
    }

    /// Returns all registered provider definitions sorted by identifier.
    public func allDefinitions() -> [AgentProviderDefinition] {
        definitions.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Subscribes to provider readiness snapshots derived from registered definitions.
    public func readinessUpdates() -> AsyncStream<[AgentProviderReadiness]> {
        let stream = AsyncStream<[AgentProviderReadiness]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        readinessSubscribers[id] = stream.continuation
        stream.continuation.onTermination = { _ in
            Task { await self.removeReadinessSubscriber(id) }
        }
        stream.continuation.yield(readinessSnapshot())
        return stream.stream
    }

    private func removeReadinessSubscriber(_ id: UUID) {
        readinessSubscribers[id] = nil
    }

    private func publishReadinessSnapshot() {
        let snapshot = readinessSnapshot()
        readinessSubscribers.values.forEach { $0.yield(snapshot) }
    }

    private func readinessSnapshot() -> [AgentProviderReadiness] {
        definitions.values
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { AgentProviderReadiness(providerId: $0.id, availability: nil, setup: .unknown, trust: .unknown) }
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

/// Provider readiness snapshot for host setup and selection UI.
public struct AgentProviderReadiness: Codable, Equatable, Sendable {
    /// Provider represented by this readiness value.
    public let providerId: AgentProviderID
    /// Latest executable availability when detection has run.
    public let availability: AgentProviderAvailability?
    /// Setup readiness for provider-specific prerequisites.
    public let setup: AgentProviderReadinessState
    /// Trust readiness for the selected working directory or project.
    public let trust: AgentProviderReadinessState

    /// Creates a provider readiness snapshot.
    public init(
        providerId: AgentProviderID,
        availability: AgentProviderAvailability? = nil,
        setup: AgentProviderReadinessState = .unknown,
        trust: AgentProviderReadinessState = .unknown
    ) {
        self.providerId = providerId
        self.availability = availability
        self.setup = setup
        self.trust = trust
    }
}

/// Coarse readiness state for provider setup gates.
public enum AgentProviderReadinessState: String, Codable, Hashable, Sendable {
    /// Readiness has not been checked.
    case unknown
    /// The provider is ready for this gate.
    case ready
    /// The provider is missing required setup.
    case needsSetup
    /// The selected project or working directory is not trusted yet.
    case needsTrust
    /// The readiness check failed.
    case failed
}

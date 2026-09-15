import Foundation

/// Mutable registry of harness definitions known to a host application.
public actor AgentHarnessRegistry {
    private var definitions: [AgentHarnessID: AgentHarnessDefinition]
    private var readinessSubscribers: [UUID: AsyncStream<[AgentHarnessReadiness]>.Continuation] = [:]

    /// Creates a harness registry.
    public init(definitions: [AgentHarnessDefinition] = []) {
        self.definitions = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Registers or replaces a harness definition.
    public func register(_ definition: AgentHarnessDefinition) {
        definitions[definition.id] = definition
        publishReadinessSnapshot()
    }

    /// Removes a harness definition.
    public func unregister(_ harnessId: AgentHarnessID) {
        definitions[harnessId] = nil
        publishReadinessSnapshot()
    }

    /// Returns a harness definition by identifier.
    public func definition(for harnessId: AgentHarnessID) -> AgentHarnessDefinition? {
        definitions[harnessId]
    }

    /// Returns all registered harness definitions sorted by identifier.
    public func allDefinitions() -> [AgentHarnessDefinition] {
        definitions.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Subscribes to harness readiness snapshots derived from registered definitions.
    public func readinessUpdates() -> AsyncStream<[AgentHarnessReadiness]> {
        let stream = AsyncStream<[AgentHarnessReadiness]>.makeStream(bufferingPolicy: .bufferingNewest(1))
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

    private func readinessSnapshot() -> [AgentHarnessReadiness] {
        definitions.values
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { AgentHarnessReadiness(harnessId: $0.id, availability: nil, setup: .unknown, trust: .unknown) }
    }
}

public extension AgentHarnessRegistry {
    /// Built-in harness definitions that can be registered without constructing runtime adapters.
    static var builtInDefinitions: [AgentHarnessDefinition] {
        [
            ClaudeHarnessDefinition.definition,
            CodexHarnessDefinition.definition
        ]
    }

    /// Creates a registry preloaded with built-in AgentCLIKit harness definitions.
    static func builtIn() -> AgentHarnessRegistry {
        AgentHarnessRegistry(definitions: builtInDefinitions)
    }
}

/// Read-only harness lookup contract used by services that should not mutate registration.
public protocol AgentHarnessLookup: Sendable {
    /// Returns a harness definition by identifier.
    func definition(for harnessId: AgentHarnessID) async -> AgentHarnessDefinition?

    /// Returns all registered harness definitions.
    func allDefinitions() async -> [AgentHarnessDefinition]
}

extension AgentHarnessRegistry: AgentHarnessLookup {}

/// Harness readiness snapshot for host setup and selection UI.
public struct AgentHarnessReadiness: Codable, Equatable, Sendable {
    /// Harness represented by this readiness value.
    public let harnessId: AgentHarnessID
    /// Latest executable availability when detection has run.
    public let availability: AgentHarnessAvailability?
    /// Setup readiness for harness-specific prerequisites.
    public let setup: AgentHarnessReadinessState
    /// Trust readiness for the selected working directory or project.
    public let trust: AgentHarnessReadinessState

    /// Creates a harness readiness snapshot.
    public init(
        harnessId: AgentHarnessID,
        availability: AgentHarnessAvailability? = nil,
        setup: AgentHarnessReadinessState = .unknown,
        trust: AgentHarnessReadinessState = .unknown
    ) {
        self.harnessId = harnessId
        self.availability = availability
        self.setup = setup
        self.trust = trust
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case harnessId = "providerId"
        case availability
        case setup
        case trust
    }
}

/// Coarse readiness state for harness setup gates.
public enum AgentHarnessReadinessState: String, Codable, Hashable, Sendable {
    /// Readiness has not been checked.
    case unknown
    /// The harness is ready for this gate.
    case ready
    /// The harness is missing required setup.
    case needsSetup
    /// The selected project or working directory is not trusted yet.
    case needsTrust
    /// The readiness check failed.
    case failed
}

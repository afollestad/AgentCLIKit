import Foundation

/// Project trust status for a provider and working directory.
public enum AgentProjectTrustStatus: String, Codable, Hashable, Sendable {
    /// Trust has not been checked yet.
    case unknown
    /// The project is trusted for the provider.
    case trusted
    /// The project is not trusted yet.
    case notTrusted
    /// The provider does not require project trust.
    case notRequired
    /// The trust check failed.
    case failed

    /// Whether this status allows provider work to start for the project.
    public var allowsProviderWork: Bool {
        self == .trusted || self == .notRequired
    }
}

/// Provider setup service for host-controlled preparation before launch.
public protocol AgentProviderSetup: Sendable {
    /// Provider identifier this setup service manages.
    var providerId: AgentProviderID { get }

    /// Returns cached provider setup readiness without disk IO or other refreshing work.
    func cachedSetupReadiness() -> AgentProviderReadinessState

    /// Returns refreshed provider setup readiness.
    func setupReadiness() async -> AgentProviderReadinessState

    /// Returns host-facing provider setup diagnostics.
    func setupDiagnostics() async -> [String]

    /// Returns cached project trust without disk IO or other refreshing work.
    ///
    /// Actor conformers should implement this synchronously using a nonisolated cache so host UI can call it
    /// during rendering without suspension.
    func cachedProjectTrustStatus(for projectURL: URL) -> AgentProjectTrustStatus

    /// Returns refreshed project trust for the provider.
    func projectTrustStatus(for projectURL: URL) async throws -> AgentProjectTrustStatus

    /// Marks a working directory as trusted for the provider when supported.
    func trustProject(at projectURL: URL) async throws
}

public extension AgentProviderSetup {
    /// Returns `.ready` for providers that do not expose additional setup gates.
    func cachedSetupReadiness() -> AgentProviderReadinessState {
        .ready
    }

    /// Returns `.ready` for providers that do not expose additional setup gates.
    func setupReadiness() async -> AgentProviderReadinessState {
        cachedSetupReadiness()
    }

    /// Returns no diagnostics for providers that do not expose additional setup gates.
    func setupDiagnostics() async -> [String] {
        []
    }

    /// Returns `.notRequired` for providers that do not need project trust.
    func cachedProjectTrustStatus(for projectURL: URL) -> AgentProjectTrustStatus {
        .notRequired
    }

    /// Returns `.notRequired` for providers that do not need project trust.
    func projectTrustStatus(for projectURL: URL) async throws -> AgentProjectTrustStatus {
        .notRequired
    }
}

/// Provider-neutral project trust service for host project and thread setup flows.
public protocol AgentProjectTrustService: Sendable {
    /// Returns cached project trust without refreshing provider config.
    func cachedStatus(providerId: AgentProviderID, projectURL: URL) -> AgentProjectTrustStatus

    /// Returns refreshed project trust.
    func status(providerId: AgentProviderID, projectURL: URL) async -> AgentProjectTrustStatus

    /// Marks the project trusted for the provider when supported.
    func trustProject(providerId: AgentProviderID, projectURL: URL) async throws
}

/// Default project trust service backed by provider setup implementations.
public struct DefaultAgentProjectTrustService: AgentProjectTrustService {
    private let setups: [AgentProviderID: any AgentProviderSetup]

    /// Creates a trust service from provider setup implementations.
    public init(setups: [any AgentProviderSetup] = []) {
        self.setups = Dictionary(setups.map { ($0.providerId, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Creates a trust service from an explicit setup map.
    public init(setupMap: [AgentProviderID: any AgentProviderSetup]) {
        self.setups = setupMap
    }

    /// Returns cached project trust without refreshing provider config.
    public func cachedStatus(providerId: AgentProviderID, projectURL: URL) -> AgentProjectTrustStatus {
        setups[providerId]?.cachedProjectTrustStatus(for: projectURL) ?? .notRequired
    }

    /// Returns refreshed project trust, mapping setup failures to `.failed`.
    public func status(providerId: AgentProviderID, projectURL: URL) async -> AgentProjectTrustStatus {
        guard let setup = setups[providerId] else {
            return .notRequired
        }
        do {
            return try await setup.projectTrustStatus(for: projectURL)
        } catch {
            return .failed
        }
    }

    /// Marks the project trusted for the provider when supported.
    public func trustProject(providerId: AgentProviderID, projectURL: URL) async throws {
        try await setups[providerId]?.trustProject(at: projectURL)
    }
}

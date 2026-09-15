import Foundation

/// Project trust status for a harness and working directory.
public enum AgentProjectTrustStatus: String, Codable, Hashable, Sendable {
    /// Trust has not been checked yet.
    case unknown
    /// The project is trusted for the harness.
    case trusted
    /// The project is not trusted yet.
    case notTrusted
    /// The harness does not require project trust.
    case notRequired
    /// The trust check failed.
    case failed

    /// Whether this status allows harness work to start for the project.
    public var allowsHarnessWork: Bool {
        self == .trusted || self == .notRequired
    }
}

/// Harness setup service for host-controlled preparation before launch.
public protocol AgentHarnessSetup: Sendable {
    /// Harness identifier this setup service manages.
    var harnessId: AgentHarnessID { get }

    /// Returns cached harness setup readiness without disk IO or other refreshing work.
    func cachedSetupReadiness() -> AgentHarnessReadinessState

    /// Returns refreshed harness setup readiness.
    func setupReadiness() async -> AgentHarnessReadinessState

    /// Returns host-facing harness setup diagnostics.
    func setupDiagnostics() async -> [String]

    /// Returns cached project trust without disk IO or other refreshing work.
    ///
    /// Actor conformers should implement this synchronously using a nonisolated cache so host UI can call it
    /// during rendering without suspension.
    func cachedProjectTrustStatus(for projectURL: URL) -> AgentProjectTrustStatus

    /// Returns refreshed project trust for the harness.
    func projectTrustStatus(for projectURL: URL) async throws -> AgentProjectTrustStatus

    /// Marks a working directory as trusted for the harness when supported.
    func trustProject(at projectURL: URL) async throws
}

public extension AgentHarnessSetup {
    /// Returns `.ready` for harnesses that do not expose additional setup gates.
    func cachedSetupReadiness() -> AgentHarnessReadinessState {
        .ready
    }

    /// Returns `.ready` for harnesses that do not expose additional setup gates.
    func setupReadiness() async -> AgentHarnessReadinessState {
        cachedSetupReadiness()
    }

    /// Returns no diagnostics for harnesses that do not expose additional setup gates.
    func setupDiagnostics() async -> [String] {
        []
    }

    /// Returns `.notRequired` for harnesses that do not need project trust.
    func cachedProjectTrustStatus(for projectURL: URL) -> AgentProjectTrustStatus {
        .notRequired
    }

    /// Returns `.notRequired` for harnesses that do not need project trust.
    func projectTrustStatus(for projectURL: URL) async throws -> AgentProjectTrustStatus {
        .notRequired
    }
}

/// Harness-neutral project trust service for host project and thread setup flows.
public protocol AgentProjectTrustService: Sendable {
    /// Returns cached project trust without refreshing harness config.
    func cachedStatus(harnessId: AgentHarnessID, projectURL: URL) -> AgentProjectTrustStatus

    /// Returns refreshed project trust.
    func status(harnessId: AgentHarnessID, projectURL: URL) async -> AgentProjectTrustStatus

    /// Marks the project trusted for the harness when supported.
    func trustProject(harnessId: AgentHarnessID, projectURL: URL) async throws
}

/// Default project trust service backed by harness setup implementations.
public struct DefaultAgentProjectTrustService: AgentProjectTrustService {
    private let setups: [AgentHarnessID: any AgentHarnessSetup]

    /// Creates a trust service from harness setup implementations.
    public init(setups: [any AgentHarnessSetup] = []) {
        self.setups = Dictionary(setups.map { ($0.harnessId, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Creates a trust service from an explicit setup map.
    public init(setupMap: [AgentHarnessID: any AgentHarnessSetup]) {
        self.setups = setupMap
    }

    /// Returns cached project trust without refreshing harness config.
    public func cachedStatus(harnessId: AgentHarnessID, projectURL: URL) -> AgentProjectTrustStatus {
        setups[harnessId]?.cachedProjectTrustStatus(for: projectURL) ?? .notRequired
    }

    /// Returns refreshed project trust, mapping setup failures to `.failed`.
    public func status(harnessId: AgentHarnessID, projectURL: URL) async -> AgentProjectTrustStatus {
        guard let setup = setups[harnessId] else {
            return .notRequired
        }
        do {
            return try await setup.projectTrustStatus(for: projectURL)
        } catch {
            return .failed
        }
    }

    /// Marks the project trusted for the harness when supported.
    public func trustProject(harnessId: AgentHarnessID, projectURL: URL) async throws {
        try await setups[harnessId]?.trustProject(at: projectURL)
    }
}

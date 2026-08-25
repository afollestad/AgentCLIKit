import Foundation

/// Claude setup service backed by Claude's native config file and its CLI sign-in state.
public struct ClaudeProviderSetup: AgentProviderSetup {
    /// Claude provider identifier.
    public let providerId = ClaudeProviderAdapter.providerId

    private let configStore: ClaudeConfigStore
    private let authProbe: ClaudeAuthProbe?
    private let authReadinessCache: ClaudeAuthReadinessCache

    /// Creates a Claude provider setup service that reports setup readiness from CLI sign-in state.
    public init(configStore: ClaudeConfigStore, authProbe: ClaudeAuthProbe) {
        self.configStore = configStore
        self.authProbe = authProbe
        self.authReadinessCache = ClaudeAuthReadinessCache()
    }

    /// Creates a Claude provider setup service.
    ///
    /// Reports `.ready` setup readiness unconditionally. Kept for hosts and tests that only need
    /// project trust; pass an `authProbe` to gate readiness on the CLI sign-in state.
    public init(configStore: ClaudeConfigStore) {
        self.configStore = configStore
        self.authProbe = nil
        self.authReadinessCache = ClaudeAuthReadinessCache()
    }

    /// Creates a Claude provider setup service for a Claude config file URL.
    public init(configFileURL: URL) {
        self.configStore = ClaudeConfigStore(fileURL: configFileURL)
        self.authProbe = nil
        self.authReadinessCache = ClaudeAuthReadinessCache()
    }

    /// Returns the last probed Claude setup readiness without spawning.
    ///
    /// Unprobed reads as `.ready` rather than `.unknown`: discovery renders this during setup UI
    /// layout, and reporting a gate the probe has not evaluated yet would flicker every provider card
    /// through a not-ready state on launch.
    public func cachedSetupReadiness() -> AgentProviderReadinessState {
        guard authProbe != nil, let readiness = authReadinessCache.readiness else {
            return .ready
        }
        return Self.readinessState(for: readiness)
    }

    /// Returns refreshed Claude setup readiness from the CLI sign-in state.
    public func setupReadiness() async -> AgentProviderReadinessState {
        guard let readiness = await refreshedAuthReadiness() else {
            return .ready
        }
        return Self.readinessState(for: readiness)
    }

    /// Returns diagnostics describing the readiness `setupReadiness()` last reported.
    ///
    /// Reads the cache rather than probing again, for two reasons: a second spawn per discovery
    /// refresh is pure waste, and an independent probe can disagree with the readiness already
    /// reported, leaving a not-ready badge with no explanation beside it. Probes only when nothing has
    /// been probed yet, so a host that calls this first still gets an answer.
    public func setupDiagnostics() async -> [String] {
        guard authProbe != nil else {
            return []
        }
        if let readiness = authReadinessCache.readiness {
            return readiness.diagnostics
        }
        return await refreshedAuthReadiness()?.diagnostics ?? []
    }

    /// Returns cached Claude project trust without disk IO.
    public func cachedProjectTrustStatus(for projectURL: URL) -> AgentProjectTrustStatus {
        configStore.cachedProjectTrustStatus(projectURL)
    }

    /// Returns refreshed Claude project trust.
    public func projectTrustStatus(for projectURL: URL) async throws -> AgentProjectTrustStatus {
        try await configStore.projectTrustStatus(projectURL)
    }

    /// Marks a project as trusted in Claude config while preserving unrelated config keys.
    public func trustProject(at projectURL: URL) async throws {
        try await configStore.trustProject(projectURL)
    }

    /// Returns freshly probed Claude auth readiness without triggering a login flow, or `nil` when
    /// this setup was created without a probe.
    public func authReadiness() async -> ClaudeAuthReadiness? {
        await refreshedAuthReadiness()
    }
}

private extension ClaudeProviderSetup {
    func refreshedAuthReadiness() async -> ClaudeAuthReadiness? {
        guard let authProbe else {
            return nil
        }
        let readiness = await authProbe.readiness()
        authReadinessCache.update(readiness)
        return readiness
    }

    /// Only a verdict the CLI gave us blocks work; `ClaudeAuthReadiness.allowsProviderWork` owns why
    /// an inconclusive probe still reports ready.
    static func readinessState(for readiness: ClaudeAuthReadiness) -> AgentProviderReadinessState {
        readiness.allowsProviderWork ? .ready : .needsSetup
    }
}

/// Holds the last probed readiness so `cachedSetupReadiness()` can answer synchronously from a
/// nonisolated context, matching how `ClaudeConfigStore` caches its config snapshot.
private final class ClaudeAuthReadinessCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReadiness: ClaudeAuthReadiness?

    var readiness: ClaudeAuthReadiness? {
        lock.withLock {
            storedReadiness
        }
    }

    func update(_ readiness: ClaudeAuthReadiness) {
        lock.withLock {
            storedReadiness = readiness
        }
    }
}

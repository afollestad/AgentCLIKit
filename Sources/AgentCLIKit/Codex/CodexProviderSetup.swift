import Foundation

/// Codex setup service backed by Codex's user-level `config.toml`.
public struct CodexProviderSetup: AgentProviderSetup {
    /// Codex provider identifier.
    public let providerId = CodexProviderAdapter.providerId

    private let configStore: CodexConfigStore
    private let authProbe: CodexAuthProbe
    private let cachedAuthReadiness: CodexAuthReadiness

    /// Creates a Codex provider setup service.
    public init(configStore: CodexConfigStore, authProbe: CodexAuthProbe = CodexAuthProbe()) {
        self.configStore = configStore
        self.authProbe = authProbe
        self.cachedAuthReadiness = authProbe.readiness()
    }

    /// Creates a Codex provider setup service for a Codex config file URL.
    public init(configFileURL: URL) {
        self.configStore = CodexConfigStore(fileURL: configFileURL)
        let authProbe = CodexAuthProbe(authFileURL: configFileURL.deletingLastPathComponent().appendingPathComponent("auth.json"))
        self.authProbe = authProbe
        self.cachedAuthReadiness = authProbe.readiness()
    }

    /// Creates a Codex provider setup service for a Codex home directory.
    public init(codexHomeDirectoryURL: URL = CodexConfigStore.defaultCodexHomeDirectoryURL) {
        self.configStore = CodexConfigStore(codexHomeDirectoryURL: codexHomeDirectoryURL)
        let authProbe = CodexAuthProbe(codexHomeDirectoryURL: codexHomeDirectoryURL)
        self.authProbe = authProbe
        self.cachedAuthReadiness = authProbe.readiness()
    }

    /// Returns cached Codex setup readiness from inspectable auth material.
    public func cachedSetupReadiness() -> AgentProviderReadinessState {
        cachedAuthReadiness.hasCredentialMaterial ? .ready : .needsSetup
    }

    /// Returns refreshed Codex setup readiness from inspectable auth material.
    public func setupReadiness() async -> AgentProviderReadinessState {
        authReadiness().hasCredentialMaterial ? .ready : .needsSetup
    }

    /// Returns Codex auth diagnostics without triggering login or App Server startup.
    public func setupDiagnostics() async -> [String] {
        authReadiness().diagnostics
    }

    /// Returns cached Codex project trust without disk IO.
    public func cachedProjectTrustStatus(for projectURL: URL) -> AgentProjectTrustStatus {
        configStore.cachedProjectTrustStatus(projectURL)
    }

    /// Returns refreshed Codex project trust.
    public func projectTrustStatus(for projectURL: URL) async throws -> AgentProjectTrustStatus {
        try await configStore.projectTrustStatus(projectURL)
    }

    /// Marks a project as trusted in Codex config while preserving unrelated config keys.
    public func trustProject(at projectURL: URL) async throws {
        try await configStore.trustProject(projectURL)
    }

    /// Returns Codex auth readiness without triggering login or App Server startup.
    public func authReadiness() -> CodexAuthReadiness {
        authProbe.readiness()
    }
}

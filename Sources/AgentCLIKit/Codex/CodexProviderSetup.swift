import Foundation

/// Codex setup service backed by Codex's user-level `config.toml`.
public struct CodexProviderSetup: AgentProviderSetup {
    /// Codex provider identifier.
    public let providerId = CodexProviderAdapter.providerId

    private let configStore: CodexConfigStore
    private let authProbe: CodexAuthProbe

    /// Creates a Codex provider setup service.
    public init(configStore: CodexConfigStore, authProbe: CodexAuthProbe = CodexAuthProbe()) {
        self.configStore = configStore
        self.authProbe = authProbe
    }

    /// Creates a Codex provider setup service for a Codex config file URL.
    public init(configFileURL: URL) {
        self.configStore = CodexConfigStore(fileURL: configFileURL)
        self.authProbe = CodexAuthProbe(authFileURL: configFileURL.deletingLastPathComponent().appendingPathComponent("auth.json"))
    }

    /// Creates a Codex provider setup service for a Codex home directory.
    public init(codexHomeDirectoryURL: URL = CodexConfigStore.defaultCodexHomeDirectoryURL) {
        self.configStore = CodexConfigStore(codexHomeDirectoryURL: codexHomeDirectoryURL)
        self.authProbe = CodexAuthProbe(codexHomeDirectoryURL: codexHomeDirectoryURL)
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

import Foundation

/// Authentication readiness state for Codex credential material AgentCLIKit can inspect safely.
public enum CodexAuthReadinessState: String, Codable, Hashable, Sendable {
    /// Credential material was found in the environment or `auth.json`.
    case ready
    /// No inspectable credential material was found.
    case missing
}

/// Inspectable Codex credential material source.
public enum CodexAuthCredentialSource: String, Codable, Hashable, Sendable {
    /// `CODEX_ACCESS_TOKEN` was present in the environment.
    case environmentAccessToken
    /// `CODEX_API_KEY` was present in the environment.
    case environmentAPIKey
    /// `auth.json` exists under `CODEX_HOME`.
    case authJSON
}

/// Result of a Codex auth-readiness probe.
public struct CodexAuthReadiness: Codable, Equatable, Sendable {
    /// Coarse readiness state for inspectable credential material.
    public let state: CodexAuthReadinessState
    /// Credential sources found by the probe.
    public let credentialSources: [CodexAuthCredentialSource]
    /// Auth file path checked by the probe.
    public let authFilePath: String
    /// Host-facing diagnostics that can be surfaced by provider setup UI.
    public let diagnostics: [String]

    /// Whether any inspectable credential material was found.
    public var hasCredentialMaterial: Bool {
        state == .ready
    }

    /// Creates a Codex auth-readiness result.
    public init(
        state: CodexAuthReadinessState,
        credentialSources: [CodexAuthCredentialSource] = [],
        authFilePath: String,
        diagnostics: [String] = []
    ) {
        self.state = state
        self.credentialSources = credentialSources
        self.authFilePath = authFilePath
        self.diagnostics = diagnostics
    }
}

/// Lightweight Codex auth probe that never starts login or the App Server.
public struct CodexAuthProbe: Sendable {
    private let authFileURL: URL
    private let environment: [String: String]

    /// Creates a Codex auth probe for a Codex home directory.
    public init(
        codexHomeDirectoryURL: URL = CodexConfigStore.defaultCodexHomeDirectoryURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.authFileURL = codexHomeDirectoryURL.appendingPathComponent("auth.json")
        self.environment = environment
    }

    /// Creates a Codex auth probe for an explicit auth file URL.
    public init(authFileURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.authFileURL = authFileURL
        self.environment = environment
    }

    /// Returns inspectable Codex auth readiness without triggering login.
    public func readiness() -> CodexAuthReadiness {
        var sources: [CodexAuthCredentialSource] = []
        if environment["CODEX_ACCESS_TOKEN"]?.isEmpty == false {
            sources.append(.environmentAccessToken)
        }
        if environment["CODEX_API_KEY"]?.isEmpty == false {
            sources.append(.environmentAPIKey)
        }
        if FileManager.default.fileExists(atPath: authFileURL.path) {
            sources.append(.authJSON)
        }
        guard sources.isEmpty else {
            return CodexAuthReadiness(state: .ready, credentialSources: sources, authFilePath: authFileURL.path)
        }
        return CodexAuthReadiness(
            state: .missing,
            authFilePath: authFileURL.path,
            diagnostics: [
                "No CODEX_ACCESS_TOKEN, CODEX_API_KEY, or Codex auth.json was found. AgentCLIKit does not trigger codex login."
            ]
        )
    }
}

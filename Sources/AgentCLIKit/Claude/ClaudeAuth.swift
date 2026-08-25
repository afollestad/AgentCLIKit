import Foundation

/// Authentication readiness state for the Claude credential AgentCLIKit can inspect.
public enum ClaudeAuthReadinessState: String, Codable, Hashable, Sendable {
    /// Usable credential material was found.
    case ready
    /// The CLI reported that no account is signed in.
    case signedOut
    /// The probe could not reach a verdict.
    case unknown
}

/// Inspectable source of the Claude credential the probe found.
public enum ClaudeAuthCredentialSource: String, Codable, Hashable, Sendable {
    /// `ANTHROPIC_API_KEY` was present in the environment.
    case environmentAPIKey
    /// `ANTHROPIC_AUTH_TOKEN` was present in the environment.
    case environmentAuthToken
    /// `claude auth status` reported a signed-in account.
    case cliAuthStatus
}

/// Result of a Claude auth-readiness probe.
public struct ClaudeAuthReadiness: Codable, Equatable, Sendable {
    /// Coarse readiness state.
    public let state: ClaudeAuthReadinessState
    /// Credential source found by the probe, when one was.
    public let credentialSource: ClaudeAuthCredentialSource?
    /// Auth method the CLI reported, such as `claude.ai`.
    public let authMethod: String?
    /// Account email the CLI reported.
    public let accountEmail: String?
    /// Host-facing diagnostics that can be surfaced by provider setup UI.
    public let diagnostics: [String]

    /// Whether provider work may start.
    ///
    /// `unknown` counts as permitted on purpose: the probe spawns a subprocess, and a machine where
    /// that spawn fails for an unrelated reason must not be locked out of a CLI that works. Only a
    /// verdict the CLI actually gave us — `signedOut` — blocks work.
    public var allowsProviderWork: Bool {
        state != .signedOut
    }

    /// Creates a Claude auth-readiness result.
    public init(
        state: ClaudeAuthReadinessState,
        credentialSource: ClaudeAuthCredentialSource? = nil,
        authMethod: String? = nil,
        accountEmail: String? = nil,
        diagnostics: [String] = []
    ) {
        self.state = state
        self.credentialSource = credentialSource
        self.authMethod = authMethod
        self.accountEmail = accountEmail
        self.diagnostics = diagnostics
    }
}

/// Claude auth probe backed by `claude auth status --json`.
///
/// Unlike `CodexAuthProbe`, which inspects a file, Claude keeps its OAuth credential in the macOS
/// keychain, so there is nothing on disk to read and the CLI itself has to be asked. That makes this
/// probe a subprocess spawn, which is why it is bounded by a timeout and why an inconclusive result
/// is `unknown` rather than `signedOut`.
///
/// The probe never starts a login flow.
public struct ClaudeAuthProbe: Sendable {
    /// Bound on the `claude auth status` spawn. Measured runs land near 0.25s, so this is slack for a
    /// cold start rather than a budget.
    public static let defaultTimeout: Duration = .seconds(2)

    private let shellRunner: any ShellRunning
    private let environment: [String: String]
    private let timeout: Duration
    private let executablePath: @Sendable () async -> String?

    /// Creates a Claude auth probe.
    ///
    /// - Parameters:
    ///   - shellRunner: Runner used for the `claude auth status` spawn.
    ///   - environment: Environment consulted for API-key credentials and merged into the spawn. A
    ///     host launched from Finder must pass an augmented `PATH` here, or a bare-name lookup fails.
    ///   - timeout: Bound on the spawn.
    ///   - executablePath: Resolves the `claude` executable. Injected because `AgentProviderSetup`
    ///     takes no arguments and so cannot receive the path discovery already resolved.
    public init(
        shellRunner: any ShellRunning = ProcessShellRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = Self.defaultTimeout,
        executablePath: @escaping @Sendable () async -> String? = {
            await DefaultAgentProviderExecutableResolver()
                .resolvedExecutablePath(for: ClaudeProviderDefinition.definition)
        }
    ) {
        self.shellRunner = shellRunner
        self.environment = environment
        self.timeout = timeout
        self.executablePath = executablePath
    }

    /// Returns Claude auth readiness without triggering a login flow.
    public func readiness() async -> ClaudeAuthReadiness {
        if let environmentReadiness = environmentCredentialReadiness() {
            return environmentReadiness
        }
        guard let executable = await executablePath() else {
            return ClaudeAuthReadiness(
                state: .unknown,
                diagnostics: ["No Claude executable was found, so its sign-in state could not be checked."]
            )
        }
        guard let result = await boundedRun(executable: executable) else {
            return ClaudeAuthReadiness(
                state: .unknown,
                diagnostics: ["Checking the Claude sign-in state timed out or could not be started."]
            )
        }
        guard result.exitCode == 0 else {
            return ClaudeAuthReadiness(state: .unknown, diagnostics: [Self.exitDiagnostic(for: result)])
        }
        guard let payload = Self.decodePayload(from: result.stdout) else {
            return ClaudeAuthReadiness(
                state: .unknown,
                diagnostics: ["The Claude sign-in state could not be read from `claude auth status`."]
            )
        }
        return Self.readiness(from: payload)
    }
}

private extension ClaudeAuthProbe {
    /// An API key or auth token bypasses OAuth entirely, so it answers without a spawn. Hosts forward
    /// both variables into provider launches, so a machine using one is genuinely ready.
    func environmentCredentialReadiness() -> ClaudeAuthReadiness? {
        if environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
            return ClaudeAuthReadiness(state: .ready, credentialSource: .environmentAPIKey)
        }
        if environment["ANTHROPIC_AUTH_TOKEN"]?.isEmpty == false {
            return ClaudeAuthReadiness(state: .ready, credentialSource: .environmentAuthToken)
        }
        return nil
    }

    /// Races the spawn against the timeout so a wedged CLI cannot leave a process behind discovery's
    /// background refresh. A thrown run and an expired timeout both surface as `nil`, because both
    /// mean the same thing to the caller: no verdict.
    func boundedRun(executable: String) async -> ShellCommandResult? {
        let command = ShellCommand(
            executable: executable,
            arguments: ["auth", "status", "--json"],
            environment: environment
        )
        let runner = shellRunner
        let bound = timeout
        return await withTaskGroup(of: ShellCommandResult?.self) { group in
            group.addTask {
                try? await runner.run(command)
            }
            group.addTask {
                try? await Task.sleep(for: bound)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func readiness(from payload: ClaudeAuthStatusPayload) -> ClaudeAuthReadiness {
        // An absent `loggedIn` is no verdict, not a negative one: a CLI that renames or drops the key
        // would otherwise lock every host out of a Claude that works.
        guard let isLoggedIn = payload.loggedIn else {
            return ClaudeAuthReadiness(
                state: .unknown,
                diagnostics: ["`claude auth status` did not report a sign-in state."]
            )
        }
        guard isLoggedIn else {
            return ClaudeAuthReadiness(
                state: .signedOut,
                diagnostics: ["Not signed in to Claude. Run `claude auth login` to sign in."]
            )
        }
        return ClaudeAuthReadiness(
            state: .ready,
            credentialSource: .cliAuthStatus,
            authMethod: payload.authMethod,
            accountEmail: payload.email
        )
    }

    static func exitDiagnostic(for result: ShellCommandResult) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return "Checking the Claude sign-in state failed with exit code \(result.exitCode)."
        }
        return "Checking the Claude sign-in state failed: \(detail)"
    }

    /// Decodes the outermost brace-delimited span rather than the whole of stdout, so leading or
    /// trailing noise does not defeat the decode; the CLI is free to print update notices or warnings
    /// alongside its JSON.
    static func decodePayload(from stdout: String) -> ClaudeAuthStatusPayload? {
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"),
              start < end,
              let data = String(stdout[start...end]).data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeAuthStatusPayload.self, from: data)
    }
}

/// The subset of `claude auth status --json` this probe reads. Every field is optional so an added or
/// renamed key upstream degrades to `unknown` instead of failing the whole decode.
struct ClaudeAuthStatusPayload: Decodable {
    let loggedIn: Bool?
    let authMethod: String?
    let email: String?
}

/// Recognizes provider result-error text that means the user must re-authenticate.
///
/// Claude reports this as a plain `result` error string with no machine-readable code, so matching the
/// text is the only way to tell "sign in again" apart from an ordinary turn failure. It lives here,
/// beside the provider that produces the text, so hosts never have to match on it themselves.
enum ClaudeAuthFailureText {
    /// Whether a Claude result-error message means the credential must be renewed.
    ///
    /// Deliberately broad. A false negative restores the dead-end error row this coding exists to
    /// replace, while a false positive only offers a sign-in button on an unrelated failure — so keep
    /// loose markers such as `could not be refreshed` rather than tightening them.
    static func isAuthenticationFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return markers.contains { normalized.contains($0) }
    }

    private static let markers = [
        "oauth session expired",
        "could not be refreshed",
        "failed to authenticate",
        "authentication_error",
        "invalid api key",
        "not logged in",
        "please log in",
        "claude auth login"
    ]
}

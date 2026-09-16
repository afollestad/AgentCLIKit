import Foundation

/// One coherent read-only snapshot shared by setup readiness and the model picker.
public struct OpenCodeDiscoverySnapshot: Equatable, Sendable {
    /// Server version validated against the adapter's supported protocol range.
    public let version: String?
    /// Models exposed by connected providers, excluding the synthetic harness-default option.
    public let models: [AgentModelOption]
    /// Whether a supported server reports connected-provider models; discovery does not run inference.
    public let readiness: AgentHarnessReadinessState
    /// Setup guidance from the same probe that produced readiness.
    public let diagnostics: [String]

    /// Creates an immutable discovery result.
    public init(version: String?, models: [AgentModelOption], readiness: AgentHarnessReadinessState, diagnostics: [String] = []) {
        self.version = version
        self.models = models
        self.readiness = readiness
        self.diagnostics = diagnostics
    }
}

/// Shares a bounded temporary-server probe so setup and model discovery do not launch independent servers.
public actor OpenCodeDiscoveryProbe {
    private let configuration: OpenCodeServerConfiguration
    private let executableResolver: any AgentHarnessExecutableResolving
    private let makeTransport: @Sendable (OpenCodeServerConfiguration) -> any OpenCodeServerTransport
    private let cacheTimeToLive: TimeInterval
    private let now: @Sendable () -> Date
    private let cache = OpenCodeDiscoveryCache()
    private var fetchedAt: Date?
    private var inFlight: Task<OpenCodeDiscoverySnapshot, Never>?

    /// Creates an opt-in live probe; construction performs no process launch or config edit.
    public init(
        configuration: OpenCodeServerConfiguration = OpenCodeServerConfiguration(
            executablePath: "/usr/bin/env", workingDirectory: FileManager.default.homeDirectoryForCurrentUser
        ),
        executableResolver: any AgentHarnessExecutableResolving = DefaultAgentHarnessExecutableResolver(),
        cacheTimeToLive: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() },
        makeTransport: @escaping @Sendable (OpenCodeServerConfiguration) -> any OpenCodeServerTransport = {
            OpenCodeHTTPServerTransport(configuration: $0)
        }
    ) {
        self.configuration = configuration
        self.executableResolver = executableResolver
        self.cacheTimeToLive = cacheTimeToLive
        self.now = now
        self.makeTransport = makeTransport
    }

    /// Reads the last snapshot without disk IO, network IO, or launching OpenCode.
    public nonisolated func cachedSnapshot() -> OpenCodeDiscoverySnapshot {
        cache.snapshot
    }

    /// Refreshes health and provider metadata; no session is created and no config mutation API is called.
    public func refresh(force: Bool = false) async -> OpenCodeDiscoverySnapshot {
        if !force, let fetchedAt, now().timeIntervalSince(fetchedAt) < cacheTimeToLive {
            return cache.snapshot
        }
        if let inFlight { return await inFlight.value }
        let task = Task { [configuration, executableResolver, makeTransport] in
            await Self.probe(configuration: configuration, executableResolver: executableResolver, makeTransport: makeTransport)
        }
        inFlight = task
        let snapshot = await task.value
        cache.update(snapshot)
        fetchedAt = now()
        inFlight = nil
        return snapshot
    }

    private static func probe(
        configuration: OpenCodeServerConfiguration,
        executableResolver: any AgentHarnessExecutableResolving,
        makeTransport: @Sendable (OpenCodeServerConfiguration) -> any OpenCodeServerTransport
    ) async -> OpenCodeDiscoverySnapshot {
        do {
            let resolved = try await resolvedConfiguration(configuration, resolver: executableResolver)
            let transport = makeTransport(resolved)
            do {
                try await transport.start()
                let health = try await transport.request(method: "GET", path: "/global/health", body: nil)
                guard case let .object(values) = health, values["healthy"] == .bool(true),
                      case let .string(version)? = values["version"] else {
                    throw AgentCLIError.invalidInput("OpenCode health response did not report a server version.")
                }
                try OpenCodeVersionSupport.validate(version)
                let providers = try await transport.request(method: "GET", path: "/provider", body: nil)
                let models = try OpenCodeModelOptionSource.parseProviderResponse(providers)
                await transport.stop()
                return OpenCodeDiscoverySnapshot(
                    version: version,
                    models: models,
                    readiness: models.isEmpty ? .needsSetup : .ready,
                    diagnostics: models.isEmpty ? ["Connect a model provider in OpenCode before starting a task."] : []
                )
            } catch {
                await transport.stop()
                throw error
            }
        } catch {
            return OpenCodeDiscoverySnapshot(version: nil, models: [], readiness: .failed, diagnostics: [error.localizedDescription])
        }
    }

    private static func resolvedConfiguration(
        _ configuration: OpenCodeServerConfiguration,
        resolver: any AgentHarnessExecutableResolving
    ) async throws -> OpenCodeServerConfiguration {
        guard configuration.executablePath == "/usr/bin/env" else { return configuration }
        guard let executable = await resolver.resolvedExecutablePath(for: OpenCodeHarnessDefinition.definition) else {
            throw AgentCLIError.harnessUnavailable(.opencode)
        }
        return OpenCodeServerConfiguration(
            executablePath: executable,
            workingDirectory: configuration.workingDirectory,
            environment: configuration.environment,
            startupTimeout: configuration.startupTimeout,
            requestTimeout: configuration.requestTimeout,
            shutdownTimeout: configuration.shutdownTimeout
        )
    }
}

private final class OpenCodeDiscoveryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value = OpenCodeDiscoverySnapshot(version: nil, models: [], readiness: .unknown)

    var snapshot: OpenCodeDiscoverySnapshot { lock.withLock { value } }

    func update(_ snapshot: OpenCodeDiscoverySnapshot) {
        lock.withLock { value = snapshot }
    }
}

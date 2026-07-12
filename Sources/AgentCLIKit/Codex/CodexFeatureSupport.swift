import Foundation

/// Codex feature support checker used by discovery and runtime validation.
public protocol CodexFeatureSupportChecking: Sendable {
    /// Returns whether the configured Codex executable supports fast mode.
    func supportsFastMode(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async -> Bool
    /// Returns whether the configured Codex executable supports native goal mode.
    func supportsGoalMode(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async -> Bool
    /// Returns whether the configured Codex executable supports thread-scoped runtime workspace roots.
    func supportsRuntimeWorkspaceRoots(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async -> Bool
}

public extension CodexFeatureSupportChecking {
    /// Defaults custom feature checkers to unsupported until they positively opt into runtime workspace roots.
    func supportsRuntimeWorkspaceRoots(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async -> Bool {
        false
    }
}

/// Default Codex feature support checker backed by `codex features list`.
public actor DefaultCodexFeatureSupportChecker: CodexFeatureSupportChecking {
    private struct CacheKey: Hashable {
        let executablePath: String
        let version: String
    }

    private struct CacheEntry {
        let supportsFastMode: Bool
        let supportsGoalMode: Bool
        let fetchedAt: Date
    }

    private let shellRunner: any ShellRunning
    private let cacheTimeToLive: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [CacheKey: CacheEntry] = [:]

    /// Creates a Codex feature support checker.
    public init(
        shellRunner: any ShellRunning = ProcessShellRunner(),
        cacheTimeToLive: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.shellRunner = shellRunner
        self.cacheTimeToLive = cacheTimeToLive
        self.now = now
    }

    /// Returns whether the configured Codex executable supports fast mode.
    public func supportsFastMode(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability? = nil
    ) async -> Bool {
        do {
            let resolvedConfiguration = await configuration.resolvingExecutableIfNeeded(
                for: CodexProviderDefinition.definition,
                availability: availability
            )
            let version = try await versionDescription(
                configuration: resolvedConfiguration,
                availability: availability
            )
            let key = CacheKey(executablePath: resolvedConfiguration.executablePath, version: version)
            let currentDate = now()
            if let entry = cache[key], currentDate.timeIntervalSince(entry.fetchedAt) < cacheTimeToLive {
                return entry.supportsFastMode
            }
            let support = try await liveFeatureSupport(configuration: resolvedConfiguration)
            cache[key] = CacheEntry(
                supportsFastMode: support.supportsFastMode,
                supportsGoalMode: support.supportsGoalMode,
                fetchedAt: currentDate
            )
            return support.supportsFastMode
        } catch {
            return false
        }
    }

    /// Returns whether the configured Codex executable supports native goal mode.
    public func supportsGoalMode(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability? = nil
    ) async -> Bool {
        do {
            let resolvedConfiguration = await configuration.resolvingExecutableIfNeeded(
                for: CodexProviderDefinition.definition,
                availability: availability
            )
            let version = try await versionDescription(configuration: resolvedConfiguration, availability: availability)
            let key = CacheKey(executablePath: resolvedConfiguration.executablePath, version: version)
            let currentDate = now()
            if let entry = cache[key], currentDate.timeIntervalSince(entry.fetchedAt) < cacheTimeToLive {
                return entry.supportsGoalMode
            }
            let support = try await liveFeatureSupport(configuration: resolvedConfiguration)
            cache[key] = CacheEntry(
                supportsFastMode: support.supportsFastMode,
                supportsGoalMode: support.supportsGoalMode,
                fetchedAt: currentDate
            )
            return support.supportsGoalMode
        } catch {
            return false
        }
    }

    /// Returns whether Codex is new enough to honor `runtimeWorkspaceRoots` instead of silently ignoring it.
    public func supportsRuntimeWorkspaceRoots(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability? = nil
    ) async -> Bool {
        do {
            let resolvedConfiguration = await configuration.resolvingExecutableIfNeeded(
                for: CodexProviderDefinition.definition,
                availability: availability
            )
            let version = try await versionDescription(configuration: resolvedConfiguration, availability: availability)
            return Self.version(version, isAtLeast: [0, 144, 0])
        } catch {
            return false
        }
    }

    private func versionDescription(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async throws -> String {
        if let version = availability?.versionDescription, !version.isEmpty {
            return version
        }
        let result = try await runFeatureProbeCommand(arguments: ["--version"], configuration: configuration)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return result.exitCode == 0 ? output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private func liveFeatureSupport(configuration: CodexProviderAdapter.Configuration) async throws -> (supportsFastMode: Bool, supportsGoalMode: Bool) {
        let result = try await runFeatureProbeCommand(arguments: ["features", "list"], configuration: configuration)
        guard result.exitCode == 0 else {
            return (false, false)
        }
        let featureNames = Self.parseFeatureNames(from: result.stdout)
        return (featureNames.contains("fast_mode"), featureNames.contains("goals"))
    }

    private func runFeatureProbeCommand(
        arguments: [String],
        configuration: CodexProviderAdapter.Configuration
    ) async throws -> ShellCommandResult {
        let command = ShellCommand(
            executable: configuration.executablePath,
            arguments: featureCommandArguments(arguments, configuration: configuration),
            environment: featureCommandEnvironment(configuration),
            workingDirectory: nil
        )
        return try await run(command, timeout: configuration.probeTimeout)
    }

    private func featureCommandArguments(
        _ arguments: [String],
        configuration: CodexProviderAdapter.Configuration
    ) -> [String] {
        configuration.executablePath == "/usr/bin/env" ? ["codex"] + arguments : arguments
    }

    private func featureCommandEnvironment(_ configuration: CodexProviderAdapter.Configuration) -> [String: String] {
        var environment = configuration.environment
        if let codexHomeDirectory = configuration.codexHomeDirectory {
            environment["CODEX_HOME"] = codexHomeDirectory.path
        }
        return environment
    }

    private func run(_ command: ShellCommand, timeout: TimeInterval) async throws -> ShellCommandResult {
        let shellRunner = self.shellRunner
        return try await withThrowingTaskGroup(of: ShellCommandResult.self) { group in
            group.addTask {
                try await shellRunner.run(command)
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw CodexFeatureSupportError.probeTimeout(seconds: timeout)
            }
            guard let result = try await group.next() else {
                throw CodexFeatureSupportError.probeTimeout(seconds: timeout)
            }
            group.cancelAll()
            return result
        }
    }

    static func parseFeatureNames(from output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let columns = trimmed.split(whereSeparator: \.isWhitespace)
            guard let name = columns.first, name.lowercased() != "name" else {
                return nil
            }
            return String(name)
        })
    }

    static func version(_ description: String, isAtLeast required: [Int]) -> Bool {
        let candidates = description.split { character in
            !character.isNumber && character != "."
        }
        guard let candidate = candidates.first(where: { $0.contains(".") }) else {
            return false
        }
        var components = candidate.split(separator: ".").compactMap { Int($0) }
        guard components.count >= 2 else {
            return false
        }
        while components.count < required.count {
            components.append(0)
        }
        for (actual, minimum) in zip(components, required) where actual != minimum {
            return actual > minimum
        }
        return true
    }
}

/// Dynamic Codex capability source backed by `CodexFeatureSupportChecking`.
public struct CodexProviderCapabilitySource: AgentProviderCapabilitySource {
    private let configuration: CodexProviderAdapter.Configuration

    /// Creates a Codex provider capability source.
    public init(configuration: CodexProviderAdapter.Configuration = CodexProviderAdapter.Configuration()) {
        self.configuration = configuration
    }

    /// Returns Codex capabilities with fast mode overlaid when the executable reports support.
    public func capabilities(
        for definition: AgentProviderDefinition,
        availability: AgentProviderAvailability?
    ) async -> AgentProviderCapabilities {
        guard definition.id == CodexProviderAdapter.providerId else {
            return definition.capabilities
        }
        let supportsFastMode = await configuration.featureSupportChecker.supportsFastMode(
            configuration: configuration,
            availability: availability
        )
        let supportsGoalMode = await configuration.featureSupportChecker.supportsGoalMode(
            configuration: configuration,
            availability: availability
        )
        return definition.capabilities
            .withSpeedModeSupport(supportsFastMode)
            .withGoalModeSupport(
                supportsGoalMode,
                supportsExistingSessionGoalStart: supportsGoalMode,
                supportedGoalActions: [.pause, .resume, .delete]
            )
    }
}

private enum CodexFeatureSupportError: Error {
    case probeTimeout(seconds: TimeInterval)
}

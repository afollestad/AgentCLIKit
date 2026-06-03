import Foundation

/// Codex project trust level stored in user-level `config.toml` under `[projects."<path>"]`.
public enum CodexProjectTrustLevel: String, Codable, Hashable, Sendable {
    /// Codex should load project-scoped `.codex/` config layers for this project.
    case trusted
    /// Codex should ignore project-scoped `.codex/` config layers for this project.
    case untrusted
}

/// Codex-specific configuration managed by AgentCLIKit.
public struct CodexConfig: Codable, Equatable, Sendable {
    /// Canonical project paths that Codex config marks as trusted.
    public let trustedProjects: Set<String>
    /// Canonical project paths that Codex config marks as untrusted.
    public let untrustedProjects: Set<String>
    /// Codex MCP server configuration that can be represented by AgentCLIKit's generic MCP model.
    public let mcpServers: [AgentMCPServer]

    /// Creates Codex configuration.
    public init(
        trustedProjects: Set<String> = [],
        untrustedProjects: Set<String> = [],
        mcpServers: [AgentMCPServer] = []
    ) {
        self.trustedProjects = trustedProjects
        self.untrustedProjects = untrustedProjects
        self.mcpServers = mcpServers
    }
}

/// Snapshot of Codex trust state suitable for host settings and project readiness UI.
public struct CodexConfigSnapshot: Codable, Equatable, Sendable {
    /// Monotonic revision incremented when the observed config content changes.
    public let revision: Int
    /// Canonical project paths with `trust_level = "trusted"`.
    public let trustedProjectPaths: Set<String>
    /// Canonical project paths with `trust_level = "untrusted"`.
    public let untrustedProjectPaths: Set<String>

    /// Creates a Codex config snapshot.
    public init(revision: Int, trustedProjectPaths: Set<String>, untrustedProjectPaths: Set<String> = []) {
        self.revision = revision
        self.trustedProjectPaths = trustedProjectPaths
        self.untrustedProjectPaths = untrustedProjectPaths
    }

    /// Returns whether the project path is trusted after canonical path normalization.
    public func isTrustedProject(path: String) -> Bool {
        trustedProjectPaths.contains(AgentPathHelpers.canonicalPath(URL(fileURLWithPath: path)))
    }

    /// Returns whether the project path is explicitly untrusted after canonical path normalization.
    public func isUntrustedProject(path: String) -> Bool {
        untrustedProjectPaths.contains(AgentPathHelpers.canonicalPath(URL(fileURLWithPath: path)))
    }
}

/// Codex-native MCP server entry stored under `[mcp_servers.<id>]` in `config.toml`.
public struct CodexMCPServerConfig: Codable, Equatable, Sendable {
    /// Local command for stdio MCP servers.
    public let command: String?
    /// Command arguments for stdio MCP servers.
    public let args: [String]?
    /// Environment variables for stdio MCP servers.
    public let env: [String: String]?
    /// Environment variable names Codex should allow and forward.
    public let envVars: [String]?
    /// Working directory for stdio MCP servers.
    public let cwd: String?
    /// Remote server URL for streamable HTTP MCP servers.
    public let url: String?
    /// Environment variable that stores the bearer token for HTTP MCP servers.
    public let bearerTokenEnvVar: String?
    /// Static HTTP headers for HTTP MCP servers.
    public let httpHeaders: [String: String]?
    /// HTTP headers whose values are read from environment variables.
    public let envHTTPHeaders: [String: String]?
    /// Startup timeout in seconds.
    public let startupTimeoutSec: Int?
    /// Per-tool timeout in seconds.
    public let toolTimeoutSec: Int?
    /// Whether the server is enabled.
    public let enabled: Bool?
    /// Whether Codex should fail startup when this enabled server cannot initialize.
    public let required: Bool?
    /// Tool allow list.
    public let enabledTools: [String]?
    /// Tool deny list applied after `enabledTools`.
    public let disabledTools: [String]?
    /// Default approval behavior for tools from this server.
    public let defaultToolsApprovalMode: String?

    /// Creates a Codex-native MCP server entry.
    public init(
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        envVars: [String]? = nil,
        cwd: String? = nil,
        url: String? = nil,
        bearerTokenEnvVar: String? = nil,
        httpHeaders: [String: String]? = nil,
        envHTTPHeaders: [String: String]? = nil,
        startupTimeoutSec: Int? = nil,
        toolTimeoutSec: Int? = nil,
        enabled: Bool? = nil,
        required: Bool? = nil,
        enabledTools: [String]? = nil,
        disabledTools: [String]? = nil,
        defaultToolsApprovalMode: String? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.envVars = envVars
        self.cwd = cwd
        self.url = url
        self.bearerTokenEnvVar = bearerTokenEnvVar
        self.httpHeaders = httpHeaders
        self.envHTTPHeaders = envHTTPHeaders
        self.startupTimeoutSec = startupTimeoutSec
        self.toolTimeoutSec = toolTimeoutSec
        self.enabled = enabled
        self.required = required
        self.enabledTools = enabledTools
        self.disabledTools = disabledTools
        self.defaultToolsApprovalMode = defaultToolsApprovalMode
    }
}

/// TOML-backed store for Codex configuration.
public actor CodexConfigStore {
    /// Default Codex home directory resolved from `CODEX_HOME` or `~/.codex`.
    public static var defaultCodexHomeDirectoryURL: URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return AgentPathHelpers.expandingTilde(in: codexHome)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private let fileURL: URL
    private let snapshotCache: CodexConfigSnapshotCache
    private var fileObserver: AgentConfigFileObserver?
    private var cachedText: String
    private var snapshotContinuations: [UUID: AsyncStream<CodexConfigSnapshot>.Continuation] = [:]
    private var revision = 0

    /// Creates a Codex config store for an explicit `config.toml` file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let text = (try? Self.readText(fileURL: fileURL)) ?? ""
        self.cachedText = text
        self.snapshotCache = CodexConfigSnapshotCache(snapshot: Self.snapshot(from: text, revision: 0))
    }

    /// Creates a Codex config store for a Codex home directory's `config.toml` file.
    public init(codexHomeDirectoryURL: URL = CodexConfigStore.defaultCodexHomeDirectoryURL) {
        self.init(fileURL: codexHomeDirectoryURL.appendingPathComponent("config.toml"))
    }

    /// Creates a Codex config store for a project's `.codex/config.toml` file.
    public init(projectDirectoryURL: URL) {
        self.init(fileURL: Self.projectConfigFileURL(for: projectDirectoryURL))
    }

    /// Returns the `.codex/config.toml` URL for a project directory.
    public static func projectConfigFileURL(for projectDirectoryURL: URL) -> URL {
        projectDirectoryURL.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("config.toml")
    }

    /// Returns the latest cached trust snapshot without disk IO.
    public nonisolated func cachedSnapshot() -> CodexConfigSnapshot {
        snapshotCache.snapshot
    }

    /// Returns the latest cached project trust status without disk IO.
    public nonisolated func cachedProjectTrustStatus(_ projectURL: URL) -> AgentProjectTrustStatus {
        cachedSnapshot().isTrustedProject(path: projectURL.path) ? .trusted : .notTrusted
    }

    /// Returns the latest trust snapshot after refreshing from disk when needed.
    public func currentSnapshot() throws -> CodexConfigSnapshot {
        startObservingIfNeeded()
        try refreshCacheIfNeeded()
        return snapshotCache.snapshot
    }

    /// Streams trust snapshots, starting with the latest cached value.
    public func snapshots() -> AsyncStream<CodexConfigSnapshot> {
        startObservingIfNeeded()
        _ = try? refreshCacheIfNeeded()
        let snapshot = snapshotCache.snapshot
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.onTermination = { _ in
                Task {
                    await self.removeSnapshotContinuation(id: id)
                }
            }
            snapshotContinuations[id] = continuation
        }
    }

    /// Returns whether the project is trusted after refreshing from disk when needed.
    public func isTrustedProject(_ projectURL: URL) throws -> Bool {
        try currentSnapshot().isTrustedProject(path: projectURL.path)
    }

    /// Returns refreshed Codex project trust status.
    public func projectTrustStatus(_ projectURL: URL) throws -> AgentProjectTrustStatus {
        try isTrustedProject(projectURL) ? .trusted : .notTrusted
    }

    /// Loads Codex configuration, returning an empty config when the file does not exist.
    public func load() throws -> CodexConfig {
        startObservingIfNeeded()
        let text = try refreshCacheIfNeeded()
        return try Self.config(from: text)
    }

    /// Loads a project's `.codex/config.toml` only when user-level Codex config marks the project trusted.
    public func loadTrustedProjectConfig(for projectURL: URL) throws -> CodexConfig? {
        guard try projectTrustStatus(projectURL) == .trusted else {
            return nil
        }
        let projectConfigURL = Self.projectConfigFileURL(for: projectURL)
        let text = try Self.readText(fileURL: projectConfigURL)
        return try Self.config(from: text)
    }

    /// Marks a project path as trusted in Codex config.
    public func trustProject(_ projectURL: URL) throws {
        try setProjectTrustLevel(.trusted, for: projectURL)
    }

    /// Writes the Codex project trust level while preserving unrelated config tables.
    public func setProjectTrustLevel(_ level: CodexProjectTrustLevel, for projectURL: URL) throws {
        startObservingIfNeeded()
        let text = try refreshCacheIfNeeded()
        let path = AgentPathHelpers.canonicalPath(projectURL)
        let updated = CodexTOMLDocument(text: text)
            .removingTables { $0.path == [CodexConfigKey.projects, path] }
            .appendingTOMLSections(Self.projectTrustSection(path: path, level: level))
        try writeText(updated)
        try refreshCacheIfNeeded(text: updated)
        startObservingIfNeeded()
    }

    /// Replaces Codex MCP servers represented by AgentCLIKit's generic MCP config.
    public func saveMCPConfig(_ mcpConfig: AgentMCPConfig) throws {
        try writeMCPServers(CodexMCPBridge.nativeServers(from: mcpConfig))
    }

    /// Reads Codex-native MCP server entries.
    public func readMCPServers() throws -> [String: CodexMCPServerConfig] {
        startObservingIfNeeded()
        let text = try refreshCacheIfNeeded()
        return try Self.mcpServerConfigs(from: text)
    }

    /// Writes Codex-native MCP server entries while preserving unrelated config keys and tables.
    public func writeMCPServers(_ servers: [String: CodexMCPServerConfig]) throws {
        startObservingIfNeeded()
        let text = try refreshCacheIfNeeded()
        let updated = CodexTOMLDocument(text: text)
            .removingTables { $0.path.first == CodexConfigKey.mcpServers }
            .appendingTOMLSections(Self.mcpServersSection(servers))
        try writeText(updated)
        try refreshCacheIfNeeded(text: updated)
        startObservingIfNeeded()
    }

    private static func readText(fileURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ""
        }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentCLIError.invalidInput("Codex config must be UTF-8 TOML.")
        }
        return text
    }

    private func writeText(_ text: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var output = text
        if !output.isEmpty, output.last != "\n" {
            output.append("\n")
        }
        try output.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func refreshCacheIfNeeded(text suppliedText: String? = nil) throws -> String {
        let text: String
        if let suppliedText {
            text = suppliedText
        } else {
            text = try Self.readText(fileURL: fileURL)
        }
        guard text != cachedText else {
            return text
        }

        cachedText = text
        revision += 1
        let snapshot = Self.snapshot(from: text, revision: revision)
        snapshotCache.update(snapshot)
        snapshotContinuations.values.forEach { continuation in
            continuation.yield(snapshot)
        }
        return text
    }

    private func refreshCacheFromObserver() {
        _ = try? refreshCacheIfNeeded()
    }

    private func startObservingIfNeeded() {
        guard fileObserver == nil else {
            return
        }
        fileObserver = AgentConfigFileObserver(
            configURL: fileURL,
            queueLabel: "com.agentclikit.codex-config-observer"
        ) { [weak self] in
            Task {
                await self?.refreshCacheFromObserver()
            }
        }
    }

    private func removeSnapshotContinuation(id: UUID) {
        snapshotContinuations[id] = nil
    }

    private static func config(from text: String) throws -> CodexConfig {
        let trustLevels = projectTrustLevels(from: text)
        return try CodexConfig(
            trustedProjects: Set(trustLevels.compactMap { path, level in
                level == .trusted ? AgentPathHelpers.canonicalPath(URL(fileURLWithPath: path)) : nil
            }),
            untrustedProjects: Set(trustLevels.compactMap { path, level in
                level == .untrusted ? AgentPathHelpers.canonicalPath(URL(fileURLWithPath: path)) : nil
            }),
            mcpServers: CodexMCPBridge().decode(Data(text.utf8)).servers
        )
    }

    private static func snapshot(from text: String, revision: Int) -> CodexConfigSnapshot {
        let trustLevels = projectTrustLevels(from: text)
        return CodexConfigSnapshot(
            revision: revision,
            trustedProjectPaths: Set(trustLevels.compactMap { path, level in
                level == .trusted ? AgentPathHelpers.canonicalPath(URL(fileURLWithPath: path)) : nil
            }),
            untrustedProjectPaths: Set(trustLevels.compactMap { path, level in
                level == .untrusted ? AgentPathHelpers.canonicalPath(URL(fileURLWithPath: path)) : nil
            })
        )
    }

    private static func projectTrustLevels(from text: String) -> [String: CodexProjectTrustLevel] {
        let document = CodexTOMLDocument(text: text)
        return document.tables.compactMap { table -> (String, CodexProjectTrustLevel)? in
            guard table.path.count == 2, table.path.first == CodexConfigKey.projects else {
                return nil
            }
            let values = CodexTOMLParser.keyValues(from: table.bodyLines)
            guard let trustLevel = values[CodexConfigKey.trustLevel]?.stringValue.flatMap(CodexProjectTrustLevel.init(rawValue:)) else {
                return nil
            }
            return (table.path[1], trustLevel)
        }.reduce(into: [:]) { result, entry in
            result[entry.0] = entry.1
        }
    }

    static func mcpServerConfigs(from text: String) throws -> [String: CodexMCPServerConfig] {
        let document = CodexTOMLDocument(text: text)
        var builders: [String: CodexMCPServerConfigBuilder] = [:]
        for table in document.tables where table.path.first == CodexConfigKey.mcpServers && table.path.count >= 2 {
            let serverID = table.path[1]
            var builder = builders[serverID] ?? CodexMCPServerConfigBuilder()
            let values = CodexTOMLParser.keyValues(from: table.bodyLines)
            let subsection = Array(table.path.dropFirst(2))
            switch subsection {
            case []:
                builder.applyRoot(values)
            case [CodexConfigKey.env]:
                builder.env = values.stringMap()
            case [CodexConfigKey.httpHeaders]:
                builder.httpHeaders = values.stringMap()
            case [CodexConfigKey.envHTTPHeaders]:
                builder.envHTTPHeaders = values.stringMap()
            default:
                break
            }
            builders[serverID] = builder
        }
        return builders.mapValues { $0.build() }
    }

    private static func projectTrustSection(path: String, level: CodexProjectTrustLevel) -> String {
        """
        [projects.\(CodexTOMLEncoder.quotedSegment(path))]
        trust_level = \(CodexTOMLEncoder.string(level.rawValue))
        """
    }

    static func mcpServersSection(_ servers: [String: CodexMCPServerConfig]) -> String {
        servers
            .sorted { $0.key < $1.key }
            .map { id, server in CodexTOMLEncoder.mcpServerSection(id: id, server: server) }
            .joined(separator: "\n\n")
    }
}

private final class CodexConfigSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: CodexConfigSnapshot

    init(snapshot: CodexConfigSnapshot) {
        self.storedSnapshot = snapshot
    }

    var snapshot: CodexConfigSnapshot {
        lock.withLock {
            storedSnapshot
        }
    }

    func update(_ snapshot: CodexConfigSnapshot) {
        lock.withLock {
            storedSnapshot = snapshot
        }
    }
}

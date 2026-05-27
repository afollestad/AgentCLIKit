import Foundation

/// Claude-specific configuration managed by AgentCLIKit.
public struct ClaudeConfig: Codable, Equatable, Sendable {
    /// Trusted project paths.
    public let trustedProjects: Set<String>
    /// Claude MCP server configuration.
    public let mcpServers: [AgentMCPServer]

    /// Creates Claude configuration.
    public init(trustedProjects: Set<String> = [], mcpServers: [AgentMCPServer] = []) {
        self.trustedProjects = trustedProjects
        self.mcpServers = mcpServers
    }
}

/// Snapshot of Claude trust state suitable for host settings and project readiness UI.
public struct ClaudeConfigSnapshot: Codable, Equatable, Sendable {
    /// Monotonic revision incremented when the observed config content changes.
    public let revision: Int
    /// Canonical trusted project paths.
    public let trustedProjectPaths: Set<String>

    /// Creates a Claude config snapshot.
    public init(revision: Int, trustedProjectPaths: Set<String>) {
        self.revision = revision
        self.trustedProjectPaths = trustedProjectPaths
    }

    /// Returns whether the project path is trusted after canonical path normalization.
    public func isTrustedProject(path: String) -> Bool {
        trustedProjectPaths.contains(AgentPathHelpers.canonicalPath(URL(fileURLWithPath: path)))
    }
}

/// Claude-native MCP server entry stored under `.claude.json`'s `mcpServers` object.
public struct ClaudeMCPServerConfig: Codable, Equatable, Sendable {
    /// Local command for stdio MCP servers.
    public let command: String?
    /// Command arguments for stdio MCP servers.
    public let args: [String]?
    /// Remote server URL for HTTP MCP servers.
    public let url: String?
    /// Headers for HTTP MCP servers.
    public let headers: [String: String]?
    /// Environment variables for stdio MCP servers.
    public let env: [String: String]?
    /// Whether the server is disabled in Claude config.
    public let disabled: Bool?

    /// Creates a Claude-native MCP server entry.
    public init(
        command: String? = nil,
        args: [String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        env: [String: String]? = nil,
        disabled: Bool? = nil
    ) {
        self.command = command
        self.args = args
        self.url = url
        self.headers = headers
        self.env = env
        self.disabled = disabled
    }
}

/// JSON-backed store for Claude configuration.
public actor ClaudeConfigStore {
    private let fileURL: URL
    private let snapshotCache: ClaudeConfigSnapshotCache
    private var cachedRoot: [String: Any]
    private var lastObservedCanonicalJSON: String
    private var snapshotContinuations: [UUID: AsyncStream<ClaudeConfigSnapshot>.Continuation] = [:]
    private var revision = 0

    /// Creates a Claude config store.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let root = (try? Self.readRoot(fileURL: fileURL)) ?? [:]
        self.cachedRoot = root
        self.lastObservedCanonicalJSON = Self.canonicalJSONString(from: root)
        self.snapshotCache = ClaudeConfigSnapshotCache(snapshot: Self.snapshot(from: root, revision: 0))
    }

    /// Returns the latest cached trust snapshot without disk IO.
    public nonisolated func cachedSnapshot() -> ClaudeConfigSnapshot {
        snapshotCache.snapshot
    }

    /// Returns the latest trust snapshot after refreshing from disk when needed.
    public func currentSnapshot() throws -> ClaudeConfigSnapshot {
        try refreshCacheIfNeeded()
        return snapshotCache.snapshot
    }

    /// Streams trust snapshots, starting with the latest cached value.
    public func snapshots() -> AsyncStream<ClaudeConfigSnapshot> {
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

    /// Loads Claude configuration, returning an empty config when the file does not exist.
    public func load() throws -> ClaudeConfig {
        let root = try refreshCacheIfNeeded()
        return try config(from: root)
    }

    /// Saves Claude configuration.
    public func save(_ config: ClaudeConfig) throws {
        var root = try refreshCacheIfNeeded()
        let existingProjects = root[ClaudeConfigKey.projects] as? [String: Any] ?? [:]
        root[ClaudeConfigKey.projects] = projectsObject(from: config.trustedProjects, existingProjects: existingProjects)
        root[ClaudeConfigKey.mcpServers] = try mcpServersObject(from: config.mcpServers)
        root.removeValue(forKey: ClaudeConfigKey.legacyTrustedProjects)
        try writeRoot(root)
        try refreshCacheIfNeeded(root: root)
    }

    /// Marks a project path as trusted.
    public func trustProject(_ projectURL: URL) throws {
        var root = try refreshCacheIfNeeded()
        let path = ClaudePathEncoder.encode(projectURL)
        var projects = root[ClaudeConfigKey.projects] as? [String: Any] ?? [:]
        var project = projects[path] as? [String: Any] ?? [:]
        project[ClaudeConfigKey.hasTrustDialogAccepted] = true
        project[ClaudeConfigKey.hasCompletedProjectOnboarding] = true
        projects[path] = project
        root[ClaudeConfigKey.projects] = projects
        root.removeValue(forKey: ClaudeConfigKey.legacyTrustedProjects)
        try writeRoot(root)
        try refreshCacheIfNeeded(root: root)
    }

    /// Replaces Claude MCP servers.
    public func saveMCPConfig(_ mcpConfig: AgentMCPConfig) throws {
        var root = try refreshCacheIfNeeded()
        root[ClaudeConfigKey.mcpServers] = try mcpServersObject(from: mcpConfig.servers)
        try writeRoot(root)
        try refreshCacheIfNeeded(root: root)
    }

    /// Reads Claude-native MCP server entries.
    public func readMCPServers() throws -> [String: ClaudeMCPServerConfig] {
        let root = try refreshCacheIfNeeded()
        guard let rawServers = root[ClaudeConfigKey.mcpServers] as? [String: Any] else {
            return [:]
        }
        let data = try JSONSerialization.data(withJSONObject: rawServers)
        return try JSONDecoder().decode([String: ClaudeMCPServerConfig].self, from: data)
    }

    /// Writes Claude-native MCP server entries while preserving unrelated config keys.
    public func writeMCPServers(_ servers: [String: ClaudeMCPServerConfig]) throws {
        var root = try refreshCacheIfNeeded()
        let data = try JSONEncoder().encode(servers)
        root[ClaudeConfigKey.mcpServers] = try JSONSerialization.jsonObject(with: data)
        try writeRoot(root)
        try refreshCacheIfNeeded(root: root)
    }

    private static func readRoot(fileURL: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return [:]
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentCLIError.invalidInput("Claude config root must be a JSON object.")
        }
        return root
    }

    private func readRoot() throws -> [String: Any] {
        try Self.readRoot(fileURL: fileURL)
    }

    private func writeRoot(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if data.last != 0x0A {
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    private func config(from root: [String: Any]) throws -> ClaudeConfig {
        // Public callers use a normalized config value; disk IO keeps Claude's native root-file schema.
        try ClaudeConfig(
            trustedProjects: trustedProjects(from: root),
            mcpServers: mcpServers(from: root)
        )
    }

    private func trustedProjects(from root: [String: Any]) -> Set<String> {
        if let projects = root[ClaudeConfigKey.projects] as? [String: Any] {
            return Set(projects.compactMap { path, value in
                guard let project = value as? [String: Any],
                      project[ClaudeConfigKey.hasTrustDialogAccepted] as? Bool == true,
                      project[ClaudeConfigKey.hasCompletedProjectOnboarding] as? Bool == true else {
                    return nil
                }
                return path
            })
        } else if let legacy = root[ClaudeConfigKey.legacyTrustedProjects] as? [String] {
            return Set(legacy)
        } else {
            return []
        }
    }

    @discardableResult
    private func refreshCacheIfNeeded(root suppliedRoot: [String: Any]? = nil) throws -> [String: Any] {
        let root: [String: Any]
        if let suppliedRoot {
            root = suppliedRoot
        } else {
            root = try readRoot()
        }
        let canonicalJSON = Self.canonicalJSONString(from: root)
        cachedRoot = root
        guard canonicalJSON != lastObservedCanonicalJSON else {
            return root
        }

        lastObservedCanonicalJSON = canonicalJSON
        revision += 1
        let snapshot = Self.snapshot(from: root, revision: revision)
        snapshotCache.update(snapshot)
        snapshotContinuations.values.forEach { continuation in
            continuation.yield(snapshot)
        }
        return root
    }

    private func removeSnapshotContinuation(id: UUID) {
        snapshotContinuations[id] = nil
    }

    private static func snapshot(from root: [String: Any], revision: Int) -> ClaudeConfigSnapshot {
        ClaudeConfigSnapshot(revision: revision, trustedProjectPaths: trustedProjectPaths(from: root))
    }

    private static func trustedProjectPaths(from root: [String: Any]) -> Set<String> {
        guard let projects = root[ClaudeConfigKey.projects] as? [String: Any] else {
            return []
        }
        return Set(projects.compactMap { path, value in
            guard let project = value as? [String: Any],
                  project[ClaudeConfigKey.hasTrustDialogAccepted] as? Bool == true,
                  project[ClaudeConfigKey.hasCompletedProjectOnboarding] as? Bool == true else {
                return nil
            }
            return AgentPathHelpers.canonicalPath(URL(fileURLWithPath: path))
        })
    }

    private static func canonicalJSONString(from root: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func projectsObject(from trustedProjects: Set<String>, existingProjects: [String: Any]) -> [String: Any] {
        var projects = existingProjects
        for path in trustedProjects {
            var project = projects[path] as? [String: Any] ?? [:]
            // Claude stores per-project settings here too, so only touch the trust flags AgentCLIKit owns.
            project[ClaudeConfigKey.hasTrustDialogAccepted] = true
            project[ClaudeConfigKey.hasCompletedProjectOnboarding] = true
            projects[path] = project
        }
        return projects
    }

    private func mcpServers(from root: [String: Any]) throws -> [AgentMCPServer] {
        guard let rawServers = root[ClaudeConfigKey.mcpServers] else {
            return []
        }
        if let legacyServers = rawServers as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: legacyServers)
            return try JSONDecoder().decode([AgentMCPServer].self, from: data)
        }
        let payload = [ClaudeConfigKey.mcpServers: rawServers]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try ClaudeMCPBridge().decode(data).servers
    }

    private func mcpServersObject(from servers: [AgentMCPServer]) throws -> [String: Any] {
        let data = try ClaudeMCPBridge().encode(AgentMCPConfig(servers: servers))
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return payload?[ClaudeConfigKey.mcpServers] as? [String: Any] ?? [:]
    }
}

/// Claude setup service backed by Claude's native config file.
public struct ClaudeProviderSetup: AgentProviderSetup {
    /// Claude provider identifier.
    public let providerId = ClaudeProviderAdapter.providerId

    private let configStore: ClaudeConfigStore

    /// Creates a Claude provider setup service.
    public init(configStore: ClaudeConfigStore) {
        self.configStore = configStore
    }

    /// Creates a Claude provider setup service for a Claude config file URL.
    public init(configFileURL: URL) {
        self.configStore = ClaudeConfigStore(fileURL: configFileURL)
    }

    /// Marks a project as trusted in Claude config while preserving unrelated config keys.
    public func trustProject(at projectURL: URL) async throws {
        try await configStore.trustProject(projectURL)
    }
}

private enum ClaudeConfigKey {
    static let projects = "projects"
    static let mcpServers = "mcpServers"
    static let legacyTrustedProjects = "trustedProjects"
    static let hasTrustDialogAccepted = "hasTrustDialogAccepted"
    static let hasCompletedProjectOnboarding = "hasCompletedProjectOnboarding"
}

private final class ClaudeConfigSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: ClaudeConfigSnapshot

    init(snapshot: ClaudeConfigSnapshot) {
        self.storedSnapshot = snapshot
    }

    var snapshot: ClaudeConfigSnapshot {
        lock.withLock {
            storedSnapshot
        }
    }

    func update(_ snapshot: ClaudeConfigSnapshot) {
        lock.withLock {
            storedSnapshot = snapshot
        }
    }
}

/// Bridge between generic MCP config and Claude config.
public struct ClaudeMCPBridge: AgentMCPConfigAdapter {
    /// Claude provider identifier.
    public let providerId = ClaudeProviderAdapter.providerId

    /// Creates a Claude MCP bridge.
    public init() {}

    /// Encodes generic MCP configuration as Claude-compatible JSON.
    public func encode(_ config: AgentMCPConfig) throws -> Data {
        let servers = Dictionary(config.servers.map { ($0.id, ClaudeMCPServer(server: $0)) }, uniquingKeysWith: { _, new in new })
        let payload = ClaudeMCPPayload(mcpServers: servers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    /// Decodes Claude MCP JSON into generic MCP configuration.
    public func decode(_ data: Data) throws -> AgentMCPConfig {
        let payload = try JSONDecoder().decode(ClaudeMCPPayload.self, from: data)
        return AgentMCPConfig(servers: payload.mcpServers.map { id, server in
            AgentMCPServer(
                id: id,
                name: server.name ?? id,
                command: server.command,
                arguments: server.args ?? [],
                environment: server.env ?? [:],
                isEnabled: server.disabled != true
            )
        }.sorted { $0.id < $1.id })
    }
}

private struct ClaudeMCPPayload: Codable {
    let mcpServers: [String: ClaudeMCPServer]
}

private struct ClaudeMCPServer: Codable {
    let name: String?
    let command: String
    let args: [String]?
    let env: [String: String]?
    let disabled: Bool?

    init(server: AgentMCPServer) {
        self.name = server.name
        self.command = server.command
        self.args = server.arguments
        self.env = server.environment
        self.disabled = server.isEnabled ? nil : true
    }
}

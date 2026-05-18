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

/// JSON-backed store for Claude configuration.
public actor ClaudeConfigStore {
    private let fileURL: URL

    /// Creates a Claude config store.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads Claude configuration, returning an empty config when the file does not exist.
    public func load() throws -> ClaudeConfig {
        let root = try readRoot()
        return try config(from: root)
    }

    /// Saves Claude configuration.
    public func save(_ config: ClaudeConfig) throws {
        var root = try readRoot()
        let existingProjects = root[ClaudeConfigKey.projects] as? [String: Any] ?? [:]
        root[ClaudeConfigKey.projects] = projectsObject(from: config.trustedProjects, existingProjects: existingProjects)
        root[ClaudeConfigKey.mcpServers] = try mcpServersObject(from: config.mcpServers)
        root.removeValue(forKey: ClaudeConfigKey.legacyTrustedProjects)
        try writeRoot(root)
    }

    /// Marks a project path as trusted.
    public func trustProject(_ projectURL: URL) throws {
        var root = try readRoot()
        let path = ClaudePathEncoder.encode(projectURL)
        var projects = root[ClaudeConfigKey.projects] as? [String: Any] ?? [:]
        var project = projects[path] as? [String: Any] ?? [:]
        project[ClaudeConfigKey.hasTrustDialogAccepted] = true
        project[ClaudeConfigKey.hasCompletedProjectOnboarding] = true
        projects[path] = project
        root[ClaudeConfigKey.projects] = projects
        root.removeValue(forKey: ClaudeConfigKey.legacyTrustedProjects)
        try writeRoot(root)
    }

    /// Replaces Claude MCP servers.
    public func saveMCPConfig(_ mcpConfig: AgentMCPConfig) throws {
        var root = try readRoot()
        root[ClaudeConfigKey.mcpServers] = try mcpServersObject(from: mcpConfig.servers)
        try writeRoot(root)
    }

    private func readRoot() throws -> [String: Any] {
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

private enum ClaudeConfigKey {
    static let projects = "projects"
    static let mcpServers = "mcpServers"
    static let legacyTrustedProjects = "trustedProjects"
    static let hasTrustDialogAccepted = "hasTrustDialogAccepted"
    static let hasCompletedProjectOnboarding = "hasCompletedProjectOnboarding"
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

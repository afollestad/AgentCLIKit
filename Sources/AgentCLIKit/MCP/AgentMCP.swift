import Foundation

/// Provider-neutral description of where a provider stores MCP server configuration.
public struct AgentMCPIntegrationDefinition: Codable, Equatable, Sendable {
    /// Config file path, which may include `~`.
    public let configPath: String
    /// Key path to the server map inside the config file.
    public let serversKeyPath: [String]
    /// Config file format.
    public let format: AgentMCPConfigFormat
    /// Adapter identifier used by host apps to select a config bridge.
    public let adapterId: String
    /// Whether the provider supports HTTP MCP servers.
    public let supportsHTTP: Bool

    /// Creates MCP integration metadata.
    public init(
        configPath: String,
        serversKeyPath: [String],
        format: AgentMCPConfigFormat,
        adapterId: String,
        supportsHTTP: Bool
    ) {
        self.configPath = configPath
        self.serversKeyPath = serversKeyPath
        self.format = format
        self.adapterId = adapterId
        self.supportsHTTP = supportsHTTP
    }

    private enum CodingKeys: String, CodingKey {
        case configPath
        case serversKeyPath
        case format
        case adapterId
        case supportsHTTP = "supportsHttp"
    }
}

/// Supported provider MCP config file formats.
public enum AgentMCPConfigFormat: String, Codable, Equatable, Sendable {
    /// JSON config.
    case json
    /// TOML config.
    case toml
}

/// Provider-neutral MCP server definition.
public struct AgentMCPServer: Codable, Equatable, Identifiable, Sendable {
    /// Stable server identifier.
    public let id: String
    /// Display name.
    public let name: String
    /// Server command executable.
    public let command: String
    /// Server command arguments.
    public let arguments: [String]
    /// Environment variables for the server command.
    public let environment: [String: String]
    /// Whether the server is enabled.
    public let isEnabled: Bool

    /// Creates an MCP server definition.
    public init(
        id: String,
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.isEnabled = isEnabled
    }
}

/// Provider-neutral MCP configuration.
public struct AgentMCPConfig: Codable, Equatable, Sendable {
    /// Configured MCP servers.
    public let servers: [AgentMCPServer]

    /// Creates an MCP configuration.
    public init(servers: [AgentMCPServer] = []) {
        self.servers = servers
    }
}

/// Store for reading and writing MCP configuration.
public protocol AgentMCPConfigStore: Sendable {
    /// Loads the current MCP configuration.
    func load() async throws -> AgentMCPConfig
    /// Saves the current MCP configuration.
    func save(_ config: AgentMCPConfig) async throws
}

/// JSON-backed MCP config store.
public actor JSONFileAgentMCPConfigStore: AgentMCPConfigStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a JSON-backed MCP config store.
    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    /// Loads the current MCP configuration.
    public func load() async throws -> AgentMCPConfig {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return AgentMCPConfig()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(AgentMCPConfig.self, from: data)
    }

    /// Saves the current MCP configuration.
    public func save(_ config: AgentMCPConfig) async throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: fileURL, options: [.atomic])
    }
}

/// Adapter that converts generic MCP configuration to a provider-specific representation.
public protocol AgentMCPConfigAdapter: Sendable {
    /// Provider supported by this adapter.
    var providerId: AgentProviderID { get }
    /// Encodes generic MCP configuration for a provider.
    func encode(_ config: AgentMCPConfig) throws -> Data
    /// Decodes provider MCP configuration into generic form.
    func decode(_ data: Data) throws -> AgentMCPConfig
}

/// Default JSON adapter for providers that use AgentCLIKit's generic MCP schema directly.
public struct JSONAgentMCPConfigAdapter: AgentMCPConfigAdapter {
    /// Provider supported by this adapter.
    public let providerId: AgentProviderID

    /// Creates a JSON MCP adapter.
    public init(providerId: AgentProviderID) {
        self.providerId = providerId
    }

    /// Encodes generic MCP configuration as JSON.
    public func encode(_ config: AgentMCPConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    /// Decodes generic MCP configuration from JSON.
    public func decode(_ data: Data) throws -> AgentMCPConfig {
        try JSONDecoder().decode(AgentMCPConfig.self, from: data)
    }
}

/// Service for adding, removing, and listing MCP servers.
public actor AgentMCPService {
    private let store: any AgentMCPConfigStore

    /// Creates an MCP service.
    public init(store: any AgentMCPConfigStore) {
        self.store = store
    }

    /// Lists configured MCP servers.
    public func listServers() async throws -> [AgentMCPServer] {
        try await store.load().servers.sorted { $0.id < $1.id }
    }

    /// Adds or replaces an MCP server.
    public func addServer(_ server: AgentMCPServer) async throws {
        var servers = try await store.load().servers.filter { $0.id != server.id }
        servers.append(server)
        try await store.save(AgentMCPConfig(servers: servers.sorted { $0.id < $1.id }))
    }

    /// Removes an MCP server.
    public func removeServer(id: String) async throws {
        let servers = try await store.load().servers.filter { $0.id != id }
        try await store.save(AgentMCPConfig(servers: servers))
    }
}

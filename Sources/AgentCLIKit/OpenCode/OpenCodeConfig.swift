import Foundation

/// Native MCP entry; additional fields preserve OpenCode extensions during explicit settings edits.
public struct OpenCodeMCPServerConfig: Codable, Equatable, Sendable {
    /// `local` launches a command; `remote` connects to an HTTP endpoint. Missing type can override only enablement.
    public var type: String?
    /// Local executable followed by its arguments.
    public var command: [String]?
    /// Remote MCP endpoint.
    public var url: String?
    /// Remote request headers, including explicitly configured credentials.
    public var headers: [String: String]?
    /// Local process environment overrides.
    public var environment: [String: String]?
    /// Whether OpenCode should connect to this server.
    public var enabled: Bool?
    /// Native OAuth settings; `false` disables OAuth for an endpoint using explicit headers.
    public var oauth: JSONValue?
    /// Native connection/tool timeout in milliseconds.
    public var timeout: Int?
    /// Unrecognized native settings retained on load and save.
    public var additionalFields: [String: JSONValue]

    /// Creates a native OpenCode MCP entry without dropping extension fields.
    public init(
        type: String? = nil,
        command: [String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        environment: [String: String]? = nil,
        enabled: Bool? = nil,
        oauth: JSONValue? = nil,
        timeout: Int? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.command = command
        self.url = url
        self.headers = headers
        self.environment = environment
        self.enabled = enabled
        self.oauth = oauth
        self.timeout = timeout
        self.additionalFields = additionalFields
    }

    /// Decodes recognized fields while retaining unknown native options.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        var fields = try container.decode([String: JSONValue].self)
        func take<Value: Decodable>(_ key: String, as valueType: Value.Type) throws -> Value? {
            guard let value = fields.removeValue(forKey: key) else { return nil }
            return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
        }
        type = try take("type", as: String.self)
        command = try take("command", as: [String].self)
        url = try take("url", as: String.self)
        headers = try take("headers", as: [String: String].self)
        environment = try take("environment", as: [String: String].self)
        enabled = try take("enabled", as: Bool.self)
        oauth = fields.removeValue(forKey: "oauth")
        timeout = try take("timeout", as: Int.self)
        additionalFields = fields
    }

    /// Encodes native field names alongside retained extension fields.
    public func encode(to encoder: Encoder) throws {
        var fields = additionalFields
        func put<Value: Encodable>(_ key: String, _ value: Value?) throws {
            guard let value else { return }
            fields[key] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }
        try put("type", type)
        try put("command", command)
        try put("url", url)
        try put("headers", headers)
        try put("environment", environment)
        try put("enabled", enabled)
        try put("oauth", oauth)
        try put("timeout", timeout)
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}

/// Explicit user-configuration edits, separate from the adapter's ephemeral runtime MCP configuration.
public actor OpenCodeConfigStore {
    /// Native user config selected when no explicit file URL is supplied.
    public static var defaultConfigFileURL: URL { configFileURL() }

    /// Resolves XDG configuration and prefers OpenCode's higher-precedence JSONC file when present.
    public static func configFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".config", isDirectory: true)
        let directory = base.appendingPathComponent("opencode", isDirectory: true)
        let candidates = ["opencode.jsonc", "opencode.json", "config.json"].map { directory.appendingPathComponent($0) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? directory.appendingPathComponent("opencode.jsonc")
    }

    private let fileURL: URL

    /// Creates a store; constructing or reading it never writes configuration.
    public init(fileURL: URL = OpenCodeConfigStore.defaultConfigFileURL) {
        self.fileURL = fileURL
    }

    /// Reads native local, remote, and enablement-only entries from JSON or JSONC.
    public func readMCPServers() throws -> [String: OpenCodeMCPServerConfig] {
        try nativeServers(in: readDocument())
    }

    /// Replaces only the MCP map, preserving unrelated bytes and existing unknown server fields.
    public func writeMCPServers(_ servers: [String: OpenCodeMCPServerConfig]) throws {
        let document = try readDocument()
        let existing = try nativeServers(in: document)
        var preserved = servers
        for (id, var server) in servers {
            server.additionalFields = (existing[id]?.additionalFields ?? [:]).merging(server.additionalFields) { _, new in new }
            preserved[id] = server
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let replacement = try encoder.encode(preserved)
        let output = try document.replacingRootMember("mcp", with: replacement)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: fileURL, options: .atomic)
    }

    /// Updates one entry without allowing another settings edit between read and write.
    public func setMCPServer(_ server: OpenCodeMCPServerConfig, id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCLIError.invalidInput("OpenCode MCP server names cannot be empty.")
        }
        var servers = try readMCPServers()
        servers[id] = server
        try writeMCPServers(servers)
    }

    /// Removes one entry atomically with respect to other edits through this store.
    public func removeMCPServer(id: String) throws {
        var servers = try readMCPServers()
        servers[id] = nil
        try writeMCPServers(servers)
    }

    private func readDocument() throws -> OpenCodeJSONCDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return try OpenCodeJSONCDocument(data: Data("{}\n".utf8))
        }
        return try OpenCodeJSONCDocument(data: Data(contentsOf: fileURL))
    }

    private func nativeServers(in document: OpenCodeJSONCDocument) throws -> [String: OpenCodeMCPServerConfig] {
        guard let servers = document.root["mcp"] else { return [:] }
        return try JSONDecoder().decode([String: OpenCodeMCPServerConfig].self, from: JSONEncoder().encode(servers))
    }
}

/// Explicit MCP settings operations that preserve other native entries, including remote OAuth configuration.
public actor OpenCodeMCPService {
    private let store: OpenCodeConfigStore

    /// Creates a service backed by the supplied native config store.
    public init(store: OpenCodeConfigStore = OpenCodeConfigStore()) {
        self.store = store
    }

    /// Lists native entries without creating or modifying the config file.
    public func listServers() async throws -> [String: OpenCodeMCPServerConfig] {
        try await store.readMCPServers()
    }

    /// Adds or replaces one explicitly edited server.
    public func setServer(_ server: OpenCodeMCPServerConfig, id: String) async throws {
        try await store.setMCPServer(server, id: id)
    }

    /// Removes one server while retaining other configuration.
    public func removeServer(id: String) async throws {
        try await store.removeMCPServer(id: id)
    }
}

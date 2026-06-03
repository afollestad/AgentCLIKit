import Foundation

/// Bridge between generic MCP config and Codex `config.toml`.
public struct CodexMCPBridge: AgentMCPConfigAdapter {
    /// Codex provider identifier.
    public let providerId = CodexProviderAdapter.providerId

    /// Creates a Codex MCP bridge.
    public init() {}

    /// Encodes generic MCP configuration as Codex-compatible TOML.
    public func encode(_ config: AgentMCPConfig) throws -> Data {
        Data(CodexConfigStore.mcpServersSection(Self.nativeServers(from: config)).utf8)
    }

    /// Decodes Codex MCP TOML into generic MCP configuration.
    public func decode(_ data: Data) throws -> AgentMCPConfig {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentCLIError.invalidInput("Codex MCP config must be UTF-8 TOML.")
        }
        let servers = try CodexConfigStore.mcpServerConfigs(from: text).compactMap { id, server -> AgentMCPServer? in
            guard let command = server.command, !command.isEmpty else {
                return nil
            }
            return AgentMCPServer(
                id: id,
                name: id,
                command: command,
                arguments: server.args ?? [],
                environment: server.env ?? [:],
                isEnabled: server.enabled ?? true
            )
        }
        return AgentMCPConfig(servers: servers.sorted { $0.id < $1.id })
    }

    /// Converts generic MCP configuration to Codex-native MCP server entries.
    public static func nativeServers(from config: AgentMCPConfig) -> [String: CodexMCPServerConfig] {
        Dictionary(config.servers.map { server in
            (
                server.id,
                CodexMCPServerConfig(
                    command: server.command,
                    args: server.arguments.isEmpty ? nil : server.arguments,
                    env: server.environment.isEmpty ? nil : server.environment,
                    enabled: server.isEnabled ? nil : false
                )
            )
        }, uniquingKeysWith: { _, new in new })
    }
}

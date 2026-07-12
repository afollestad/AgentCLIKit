import Foundation

enum ClaudeHostToolLaunch {
    private static let tokenEnvironmentKey = "AGENTCLIKIT_HOST_MCP_TOKEN"

    static func augment(
        arguments: inout [String],
        environment: inout [String: String],
        spawnConfig: AgentSpawnConfig,
        endpoint: AgentHostToolEndpoint?
    ) throws {
        let additionalRoots = spawnConfig.additionalWorkspaceRoots.filter {
            !AgentPathHelpers.isSameCanonicalPath($0, spawnConfig.workingDirectory)
        }
        if !additionalRoots.isEmpty {
            arguments.append("--add-dir")
            arguments.append(contentsOf: additionalRoots.map(\.path))
        }
        guard let endpoint else {
            return
        }
        arguments.append(contentsOf: ["--mcp-config", try inlineMCPConfig(endpoint)])
        arguments.append("--allowedTools")
        arguments.append(contentsOf: endpoint.enabledToolNames.map {
            "mcp__\(endpoint.serverName)__\($0)"
        })
        environment[tokenEnvironmentKey] = endpoint.bearerToken
    }

    private static func inlineMCPConfig(_ endpoint: AgentHostToolEndpoint) throws -> String {
        let payload: [String: Any] = [
            "mcpServers": [
                endpoint.serverName: [
                    "type": "http",
                    "url": endpoint.url.absoluteString,
                    "headers": [
                        "Authorization": "Bearer ${\(tokenEnvironmentKey)}"
                    ],
                    "alwaysLoad": true
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw AgentCLIError.invalidInput("Could not encode inline Claude MCP configuration.")
        }
        return value
    }
}

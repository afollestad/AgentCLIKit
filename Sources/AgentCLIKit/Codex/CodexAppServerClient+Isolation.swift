import Foundation

/// Isolation that only a thread launch can apply: the sandbox's network switch and user MCP servers are read when
/// App Server loads a thread, so neither belongs in sticky settings (`mergeIntegrationIsolationConfig` covers those).
extension CodexAppServerClient {
    func mergeLaunchIsolationConfig(
        spawnConfig: AgentSpawnConfig,
        hostToolEndpoint: AgentHostToolEndpoint?,
        into config: inout [String: JSONValue]
    ) {
        if spawnConfig.integrationIsolation.contains(.shellNetwork) {
            // Explicit so a user config that grants workspace-write network cannot reopen it.
            config["sandbox_workspace_write.network_access"] = .bool(false)
        }
        // One dotted leaf per server: a whole `mcp_servers` object would collide with the host-tool entry.
        for name in withheldMCPServerNames(spawnConfig: spawnConfig, hostToolEndpoint: hostToolEndpoint) {
            config["mcp_servers.\(name).enabled"] = .bool(false)
        }
    }

    /// User and trusted-project MCP servers a `.nativeIntegrations` thread must not start. Plugin servers go with
    /// `features.plugins`; the host-tool server is injected per thread and never withheld. A name containing `.`
    /// cannot be addressed as a dotted override, and a malformed key could fail the launch, so it is left alone.
    private func withheldMCPServerNames(spawnConfig: AgentSpawnConfig, hostToolEndpoint: AgentHostToolEndpoint?) -> [String] {
        guard spawnConfig.integrationIsolation.contains(.nativeIntegrations) else {
            return []
        }
        let names = CodexConfigStore.configuredMCPServerNames(
            codexHomeDirectoryURL: appServerCodexHome,
            workingDirectory: spawnConfig.workingDirectory
        )
        return names
            .subtracting([hostToolEndpoint?.serverName].compactMap { $0 })
            .filter { !$0.contains(".") }
            .sorted()
    }

    /// The home the App Server process reads, resolved the way its transport sets `CODEX_HOME`; reading any other
    /// config would withhold the wrong servers.
    private var appServerCodexHome: URL {
        if let codexHomeDirectory = configuration.codexHomeDirectory {
            return codexHomeDirectory
        }
        if let home = configuration.environment["CODEX_HOME"], !home.isEmpty {
            return AgentPathHelpers.expandingTilde(in: home)
        }
        return CodexConfigStore.defaultCodexHomeDirectoryURL
    }
}

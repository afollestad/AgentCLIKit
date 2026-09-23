import Foundation

/// Configuration is layered in the child process; host credentials never enter the user's config file.
extension OpenCodeClient {
    func serverConfiguration(config: AgentSpawnConfig, endpoint: AgentHostToolEndpoint?) async throws -> OpenCodeServerConfiguration {
        let executable: String
        if configuration.executablePath == "/usr/bin/env" {
            guard let resolved = await configuration.executableResolver.resolvedExecutablePath(for: OpenCodeHarnessDefinition.definition) else {
                throw OpenCodeTransportError.unavailable("Install a compatible OpenCode executable first.")
            }
            executable = resolved
        } else { executable = configuration.executablePath }
        var environment = configuration.environment.merging(config.environment) { _, value in value }
        let isolatesIntegrations = config.integrationIsolation.contains(.nativeIntegrations)
        let withheld = isolatesIntegrations
            ? await configuredMCPServerNames(executable: executable, directory: config.workingDirectory, environment: environment)
                .subtracting([endpoint?.serverName].compactMap { $0 })
            : []
        if endpoint != nil || !withheld.isEmpty {
            let inherited = environment["OPENCODE_CONFIG_CONTENT"] ?? ProcessInfo.processInfo.environment["OPENCODE_CONFIG_CONTENT"]
            let document = try OpenCodeJSONCDocument(data: Data((inherited ?? "{}").utf8))
            var mcp = document.root["mcp"]?.ocObject ?? [:]
            // OpenCode deep-merges this layer, so `enabled: false` alone disables a server another layer defines.
            for name in withheld {
                var entry = mcp[name]?.ocObject ?? [:]
                entry["enabled"] = .bool(false)
                mcp[name] = .object(entry)
            }
            if let endpoint {
                mcp[endpoint.serverName] = .object([
                    "type": .string("remote"), "url": .string(endpoint.url.absoluteString), "enabled": .bool(true),
                    "oauth": .bool(false), "headers": .object(["Authorization": .string("Bearer \(endpoint.bearerToken)")])
                ])
            }
            // OpenCode permission object order is meaningful: preserve every unrelated byte,
            // including user rules whose last matching entry wins.
            let output = try document.replacingRootMember("mcp", with: JSONEncoder().encode(JSONValue.object(mcp)))
            environment["OPENCODE_CONFIG_CONTENT"] = String(bytes: output, encoding: .utf8)
        }
        return OpenCodeServerConfiguration(
            executablePath: executable, workingDirectory: config.workingDirectory, environment: environment,
            startupTimeout: configuration.startupTimeout, requestTimeout: configuration.requestTimeout,
            shutdownTimeout: configuration.shutdownTimeout, excludesExternalPlugins: isolatesIntegrations
        )
    }

    /// Every MCP server OpenCode would start in `directory`, across all its config layers, from `opencode debug
    /// config` run with the server's own environment. A failed or slow probe lists nothing rather than blocking launch.
    private func configuredMCPServerNames(executable: String, directory: URL, environment: [String: String]) async -> Set<String> {
        let command = ShellCommand(
            executable: executable, arguments: ["debug", "config"], environment: environment, workingDirectory: directory
        )
        let runner = configuration.oneShotShellRunner
        let result = await withTaskGroup(of: ShellCommandResult?.self) { group in
            group.addTask { try? await runner.run(command) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result, result.exitCode == 0,
              let root = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let mcp = root["mcp"] as? [String: Any] else {
            return []
        }
        return Set(mcp.keys)
    }

    func selectedModel(_ state: OpenCodeGeneration) -> JSONValue? {
        guard let selection = state.context.spawnConfig.model,
              let separator = selection.firstIndex(of: "/") else { return nil }
        let providerID = String(selection[..<separator])
        let modelID = String(selection[selection.index(after: separator)...])
        guard state.providers[oc: "connected"]?.ocArray?.contains(.string(providerID)) == true else { return nil }
        return state.providers[oc: "all"]?.ocArray?.first { $0[oc: "id"]?.ocString == providerID }?[oc: "models"]?[oc: modelID]
    }

    func modelIdentity(_ state: OpenCodeGeneration) throws -> (provider: String, model: String)? {
        guard let value = state.context.spawnConfig.model else { return nil }
        guard let separator = value.firstIndex(of: "/"), separator != value.startIndex,
              value.index(after: separator) != value.endIndex else {
            throw AgentCLIError.invalidInput("OpenCode models must include their provider, for example provider/model.")
        }
        guard selectedModel(state) != nil else {
            throw AgentCLIError.invalidInput("The selected OpenCode model is unavailable: \(value)")
        }
        return (String(value[..<separator]), String(value[value.index(after: separator)...]))
    }

    /// Native default selection is persisted on the session, and older/forked sessions retain it in user history.
    /// Prefer that identity to today's config, which can differ from the model that owns this conversation.
    func compactionModel(_ state: OpenCodeGeneration) async throws -> (provider: String, model: String) {
        if let model = try modelIdentity(state) { return model }
        let session = try await state.transport.request(method: "GET", path: "/session/\(state.sessionID)", body: nil)
        if let provider = session[oc: "model"]?[oc: "providerID"]?.ocString,
           let model = session[oc: "model"]?[oc: "id"]?.ocString { return (provider, model) }
        let history = try await state.transport.request(method: "GET", path: "/session/\(state.sessionID)/message", body: nil)
        for message in (history.ocArray ?? []).reversed() {
            guard let info = message[oc: "info"], info[oc: "role"]?.ocString == "user",
                  let provider = info[oc: "model"]?[oc: "providerID"]?.ocString,
                  let model = info[oc: "model"]?[oc: "modelID"]?.ocString else { continue }
            return (provider, model)
        }
        let configured = try await state.transport.request(method: "GET", path: "/config", body: nil)
        let fallback = configured[oc: "model"]?.ocString?.split(separator: "/", maxSplits: 1).map(String.init)
        guard let fallback, fallback.count == 2 else {
            throw AgentCLIError.invalidInput("Select an explicit OpenCode model before manual compaction.")
        }
        return (fallback[0], fallback[1])
    }

    func sessionAction(_ action: String, record: AgentSessionRecord) async throws {
        guard !isShutdown else { throw CancellationError() }
        guard record.harnessId == .opencode, let directory = record.workingDirectory else {
            throw AgentCLIError.invalidInput("OpenCode session actions require an OpenCode session and its working directory.")
        }
        try Self.validateID(record.harnessSessionId.rawValue)
        let config = AgentSpawnConfig(harnessId: .opencode, workingDirectory: directory)
        let serverConfig = try await serverConfiguration(config: config, endpoint: nil)
        guard !isShutdown else { throw CancellationError() }
        let transport = configuration.makeTransport(serverConfig)
        let actionID = UUID()
        actionTransports[actionID] = transport
        defer { actionTransports[actionID] = nil }
        do {
            try await transport.start()
            guard !isShutdown else { throw CancellationError() }
            let health = try await transport.request(method: "GET", path: "/global/health", body: nil)
            try OpenCodeVersionSupport.validate(health[oc: "version"]?.ocString ?? "unknown")
            guard !isShutdown else { throw CancellationError() }
            let path = "/session/\(record.harnessSessionId.rawValue)"
            if action == "delete" {
                _ = try await transport.request(method: "DELETE", path: path, body: nil)
            } else {
                let time: JSONValue = .object(["archived": .number(Date().timeIntervalSince1970 * 1_000)])
                _ = try await transport.request(method: "PATCH", path: path, body: .object(["time": time]))
            }
            await transport.stop()
        } catch {
            await transport.stop()
            throw error
        }
    }
}

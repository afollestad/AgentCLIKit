import Foundation

/// One-shot runs use native read tools in a disposable profile; project config and executable extensions never load.
extension OpenCodeHarnessAdapter {
    /// Prepares an isolated command. The caller must terminate the command before releasing its disposable profile.
    public func prepareOneShotPrompt(request: AgentOneShotPromptRequest) async throws -> AgentPreparedOneShotPrompt {
        let model = try Self.oneShotModel(request)
        let inherited = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, value in value }
            .merging(request.environment) { _, value in value }
        let provider = try OpenCodeOneShotProviderConfiguration.load(
            model: model, environment: inherited, workingDirectory: request.workingDirectory
        )
        let duration = min(request.timeout ?? 1_200, 1_200)
        try OpenCodeOneShotAuthentication.validate(provider.authentication, minimumValidity: duration + 100)
        let executable: String
        if configuration.executablePath == "/usr/bin/env" {
            guard let resolved = await configuration.executableResolver.resolvedExecutablePath(for: definition) else {
                throw OpenCodeTransportError.unavailable("Install a compatible OpenCode executable first.")
            }
            executable = resolved
        } else { executable = configuration.executablePath }

        let profile = try OpenCodeOneShotProfile(provider: provider, model: model, inherited: inherited)
        do {
            let command = ShellCommand(
                executable: executable, arguments: Self.oneShotArguments(model: model, effort: request.effort),
                environment: profile.environment, inheritsEnvironment: false,
                workingDirectory: request.workingDirectory, standardInput: request.prompt
            )
            try await validateOneShotSelection(command, model: model, effort: request.effort, timeout: request.timeout)
            try Task.checkCancellation()
            try OpenCodeOneShotAuthentication.validate(provider.authentication, minimumValidity: duration + 60)
            return AgentPreparedOneShotPrompt(command: command, executionDeadline: Date().addingTimeInterval(duration)) {
                try profile.cleanup()
            }
        } catch {
            do { try profile.cleanup() } catch let cleanupError {
                throw AgentOneShotPromptError.cleanupFailed(
                    harnessId: .opencode, reason: cleanupError.localizedDescription, operationFailure: error.localizedDescription
                )
            }
            throw error
        }
    }

    private static func oneShotModel(_ request: AgentOneShotPromptRequest) throws -> String {
        guard request.harnessId == .opencode, request.toolPolicy == .readOnly, request.arguments.isEmpty else {
            throw AgentCLIError.invalidInput("OpenCode read-only one-shot prompts do not accept additional CLI arguments.")
        }
        if let timeout = request.timeout, !timeout.isFinite || timeout < 0 {
            throw AgentCLIError.invalidInput("OpenCode one-shot timeout must be a finite, nonnegative duration.")
        }
        guard let model = request.model, model == model.trimmingCharacters(in: .whitespacesAndNewlines),
              let separator = model.firstIndex(of: "/"), separator != model.startIndex,
              model.index(after: separator) != model.endIndex, !model.contains("\n") else {
            throw AgentCLIError.invalidInput("OpenCode one-shot prompts require an exact provider/model selection.")
        }
        return model
    }

    private static func oneShotArguments(model: String, effort: String?) -> [String] {
        var arguments = ["run", "--format", "json", "--model", model, "--agent", "agentclikit-readonly", "--title", "AgentCLIKit one-shot"]
        if let effort { arguments += ["--variant", effort] }
        return arguments
    }
}

/// All writable native state stays beneath one private directory, including refreshed credentials and the session database.
private struct OpenCodeOneShotProfile: Sendable {
    let directory: URL
    let environment: [String: String]

    init(provider: OpenCodeOneShotProviderConfiguration, model: String, inherited: [String: String]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentclikit-opencode-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var environment = inherited.filter { ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ"].contains($0.key) }
            environment.merge(provider.providerEnvironment) { _, value in value }
            for key in ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "OPENCODE_CONFIG_DIR", "TMPDIR"] {
                let path = directory.appendingPathComponent(key.lowercased())
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                environment[key] = path.path
            }
            environment["OPENCODE_DB"] = directory.appendingPathComponent("session.db").path
            let dataDirectory = directory.appendingPathComponent("xdg_data_home/opencode")
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let authPath = dataDirectory.appendingPathComponent("auth.json")
            try JSONEncoder().encode(OpenCodeOneShotAuthentication.isolatedCopy(provider.authentication)).write(to: authPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath.path)
            var config = provider.configuration
            config.merge(Self.readOnlyConfiguration(model: model, dataDirectory: dataDirectory)) { _, value in value }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(JSONValue.object(config))
            let path = directory.appendingPathComponent("opencode.json")
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            environment["OPENCODE_CONFIG"] = path.path
            environment["OPENCODE_CONFIG_CONTENT"] = "{}"
            for key in Self.disabledFeatures { environment[key] = "true" }
            environment["OPENCODE_PURE"] = "true"
            environment["DO_NOT_TRACK"] = "1"
            self.environment = environment
        } catch {
            do { try FileManager.default.removeItem(at: directory) } catch let cleanupError {
                throw AgentOneShotPromptError.cleanupFailed(
                    harnessId: .opencode, reason: cleanupError.localizedDescription, operationFailure: error.localizedDescription
                )
            }
            throw error
        }
    }

    func cleanup() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private static let disabledFeatures = [
        "OPENCODE_DISABLE_AUTOUPDATE", "OPENCODE_DISABLE_MODELS_FETCH", "OPENCODE_DISABLE_PROJECT_CONFIG",
        "OPENCODE_DISABLE_EXTERNAL_SKILLS", "OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_LSP_DOWNLOAD",
        "OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER", "OPENCODE_DISABLE_TERMINAL_TITLE", "OPENCODE_DISABLE_FFF"
    ]

    private static func readOnlyConfiguration(model: String, dataDirectory: URL) -> [String: JSONValue] {
        // Sorted JSON puts the wildcard first, so the three precise native tool allowances win.
        let permission: JSONValue = .object([
            "*": .string("deny"), "read": .string("allow"), "glob": .string("allow"), "grep": .string("allow"),
            "external_directory": .object([
                "*": .string("deny"), dataDirectory.appendingPathComponent("tool-output/*").path: .string("deny")
            ])
        ])
        return [
            "model": .string(model), "small_model": .string(model), "share": .string("disabled"), "autoupdate": .bool(false),
            "enabled_providers": .array([.string(String(model.prefix { $0 != "/" }))]),
            "snapshot": .bool(false), "lsp": .bool(false), "formatter": .bool(false), "plugin": .array([]),
            "mcp": .object([:]), "instructions": .array([]), "permission": permission,
            "default_agent": .string("agentclikit-readonly"),
            "agent": .object(["agentclikit-readonly": .object(["mode": .string("primary"), "permission": permission])])
        ]
    }
}

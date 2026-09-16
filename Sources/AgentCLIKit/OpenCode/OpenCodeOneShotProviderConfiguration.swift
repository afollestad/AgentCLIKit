import Foundation

/// Copies only the selected inference connection into disposable one-shot storage; never evaluates native plugins or project config.
struct OpenCodeOneShotProviderConfiguration: Sendable {
    let configuration: [String: JSONValue]
    let authentication: JSONValue?
    let providerEnvironment: [String: String]

    static func load(
        model: String, environment: [String: String], workingDirectory: URL,
        managedConfigPaths: [String] = systemManagedConfigPaths
    ) throws -> Self {
        guard let slash = model.firstIndex(of: "/"), slash != model.startIndex,
              model.index(after: slash) != model.endIndex else {
            throw AgentCLIError.invalidInput("Select an exact OpenCode provider/model for an isolated prompt.")
        }
        guard !managedConfigPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw AgentCLIError.invalidInput("OpenCode managed configuration cannot be isolated for a read-only prompt.")
        }
        let provider = String(model[..<slash])
        let home = try directory(environment["HOME"], fallback: FileManager.default.homeDirectoryForCurrentUser)
        let configRoot = try directory(environment["XDG_CONFIG_HOME"], fallback: home.appendingPathComponent(".config"))
            .appendingPathComponent("opencode")
        var files = ["config.json", "opencode.json", "opencode.jsonc"].map { configRoot.appendingPathComponent($0) }
        if let explicit = environment["OPENCODE_CONFIG"], !explicit.isEmpty {
            files.append(resolve(explicit, relativeTo: workingDirectory, home: home))
        }
        var directories = [home.appendingPathComponent(".opencode")]
        if let explicit = environment["OPENCODE_CONFIG_DIR"], !explicit.isEmpty {
            directories.append(resolve(explicit, relativeTo: workingDirectory, home: home))
        }
        files += directories.flatMap { directory in ["opencode.json", "opencode.jsonc"].map { directory.appendingPathComponent($0) } }
        var selected: [String: JSONValue] = [:]
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let root = try readConfiguration(file)
            try mergeProvider(
                root, provider: provider, into: &selected, environment: environment, directory: file.deletingLastPathComponent(), home: home
            )
        }
        if let content = environment["OPENCODE_CONFIG_CONTENT"], !content.isEmpty {
            let root: [String: JSONValue]
            do { root = try OpenCodeJSONCDocument(data: Data(content.utf8)).root } catch {
                throw AgentCLIError.invalidInput("OpenCode inline configuration is invalid.")
            }
            try mergeProvider(root, provider: provider, into: &selected, environment: environment, directory: workingDirectory, home: home)
        }
        let modelID = String(model[model.index(after: slash)...])
        let selectedModel = selected["models"]?[oc: modelID]
        selected["models"] = selectedModel.map { .object([modelID: $0]) }
        try validateBundledSDK(selected["npm"])
        try validateBundledSDK(selectedModel?[oc: "provider"]?[oc: "npm"])
        let authentication = try authentication(provider: provider, environment: environment, home: home)
        // Native stored auth overrides environment credentials; materializing the latter into options would invert that precedence.
        if authentication == nil { materializeDeclaredAPIKey(in: &selected, environment: environment) }
        return Self(
            configuration: selected.isEmpty ? [:] : ["provider": .object([provider: .object(selected)])],
            authentication: authentication.map { .object([provider: $0]) },
            providerEnvironment: environment.filter { credentialKeys(for: provider).contains($0.key) }
        )
    }

    /// Native managed configuration loads after inline overrides; refusing it avoids claiming an isolation policy it can replace.
    static var systemManagedConfigPaths: [String] {
        #if os(macOS)
        [
            "/Library/Application Support/opencode/opencode.json", "/Library/Application Support/opencode/opencode.jsonc",
            "/Library/Managed Preferences/ai.opencode.managed.plist",
            "/Library/Managed Preferences/\(NSUserName())/ai.opencode.managed.plist"
        ]
        #else
        ["/etc/opencode/opencode.json", "/etc/opencode/opencode.jsonc"]
        #endif
    }

    private static func readConfiguration(_ file: URL) throws -> [String: JSONValue] {
        do { return try OpenCodeJSONCDocument(data: Data(contentsOf: file)).root } catch {
            throw AgentCLIError.invalidInput("Could not read OpenCode provider configuration at \(file.path).")
        }
    }

    /// Native provider configuration can load executable npm modules even in pure mode; isolated runs only use bundled SDKs.
    private static func validateBundledSDK(_ value: JSONValue?) throws {
        guard let value else { return }
        guard let package = value.ocString else {
            throw AgentCLIError.invalidInput("This OpenCode provider requires an external SDK unavailable in isolated prompts.")
        }
        try validateSDK(package)
    }

    static func validateSDK(_ npm: String?) throws {
        guard let npm else { return }
        guard bundledSDKs.contains(npm) else {
            throw AgentCLIError.invalidInput("This OpenCode provider requires an external SDK unavailable in isolated prompts.")
        }
    }

    /// Native providers with one declared credential variable treat its value as their API key. Copy the value, never the variable name.
    private static func materializeDeclaredAPIKey(in provider: inout [String: JSONValue], environment: [String: String]) {
        guard let keys = provider["env"]?.ocArray, keys.count == 1, let key = keys.first?.ocString,
              let value = environment[key], !value.isEmpty else { return }
        var options = provider["options"]?.ocObject ?? [:]
        if options["apiKey"] == nil { options["apiKey"] = .string(value) }
        provider["options"] = .object(options)
    }

    private static let bundledSDKs: Set<String> = [
        "@ai-sdk/amazon-bedrock", "@ai-sdk/amazon-bedrock/mantle", "@ai-sdk/anthropic", "@ai-sdk/azure",
        "@ai-sdk/google", "@ai-sdk/google-vertex", "@ai-sdk/google-vertex/anthropic", "@ai-sdk/openai",
        "@ai-sdk/openai-compatible", "@openrouter/ai-sdk-provider", "@ai-sdk/xai", "@ai-sdk/mistral", "@ai-sdk/groq",
        "@ai-sdk/deepinfra", "@ai-sdk/cerebras", "@ai-sdk/cohere", "@ai-sdk/gateway", "@ai-sdk/togetherai",
        "@ai-sdk/perplexity", "@ai-sdk/vercel", "@ai-sdk/alibaba", "gitlab-ai-provider", "@ai-sdk/github-copilot",
        "venice-ai-sdk-provider"
    ]

    // swiftlint:disable:next function_parameter_count
    private static func mergeProvider(
        _ root: [String: JSONValue], provider: String, into selected: inout [String: JSONValue],
        environment: [String: String], directory: URL, home: URL
    ) throws {
        guard let value = root["provider"]?[oc: provider] else { return }
        guard let fields = try substitute(value, environment: environment, directory: directory, home: home).ocObject else {
            throw AgentCLIError.invalidInput("OpenCode provider configuration must be an object.")
        }
        selected = merge(selected, fields)
    }

    private static func merge(_ existing: [String: JSONValue], _ overlay: [String: JSONValue]) -> [String: JSONValue] {
        existing.merging(overlay) { old, new in
            guard let old = old.ocObject, let new = new.ocObject else { return new }
            return .object(merge(old, new))
        }
    }

    /// Resolve placeholders only inside the selected provider; unrelated instructions and plugins are never read or executed.
    private static func substitute(_ value: JSONValue, environment: [String: String], directory: URL, home: URL) throws -> JSONValue {
        switch value {
        case .object(let values):
            return .object(try values.mapValues { try substitute($0, environment: environment, directory: directory, home: home) })
        case .array(let values):
            return .array(try values.map { try substitute($0, environment: environment, directory: directory, home: home) })
        case .string(let value):
            var output = value
            for kind in ["env", "file"] {
                output = try substituteString(output, kind: kind, environment: environment, directory: directory, home: home)
            }
            return .string(output)
        default: return value
        }
    }

    private static func substituteString(
        _ value: String, kind: String, environment: [String: String], directory: URL, home: URL
    ) throws -> String {
        let pattern = try NSRegularExpression(pattern: "\\{\(kind):([^}]+)\\}")
        let output = NSMutableString(string: value)
        for match in pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let name = Range(match.range(at: 1), in: value) else { continue }
            let replacement: String
            if kind == "env" {
                replacement = environment[String(value[name])] ?? ""
            } else {
                let file = resolve(String(value[name]), relativeTo: directory, home: home)
                do { replacement = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) } catch {
                    throw AgentCLIError.invalidInput("Could not read an OpenCode provider credential file.")
                }
            }
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return output as String
    }

    private static func authentication(provider: String, environment: [String: String], home: URL) throws -> JSONValue? {
        let root: [String: JSONValue]
        do {
            if let inline = environment["OPENCODE_AUTH_CONTENT"], !inline.isEmpty {
                root = try JSONDecoder().decode([String: JSONValue].self, from: Data(inline.utf8))
            } else {
                let data = try directory(environment["XDG_DATA_HOME"], fallback: home.appendingPathComponent(".local/share"))
                let file = data.appendingPathComponent("opencode/auth.json")
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
            }
        } catch { throw AgentCLIError.invalidInput("Could not read OpenCode authentication for an isolated prompt.") }
        guard let selected = root[provider] else { return nil }
        guard let type = selected[oc: "type"]?.ocString, type == "api" || type == "oauth" else {
            throw AgentCLIError.invalidInput("This OpenCode authentication method is unavailable for isolated prompts.")
        }
        return selected
    }

    private static func directory(_ value: String?, fallback: URL) throws -> URL {
        guard let value, !value.isEmpty else { return fallback }
        guard value.hasPrefix("/") else { throw AgentCLIError.invalidInput("OpenCode home and XDG directories must be absolute paths.") }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private static func resolve(_ value: String, relativeTo directory: URL, home: URL) -> URL {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        return directory.appendingPathComponent(value)
    }

    private static func credentialKeys(for provider: String) -> Set<String> {
        let keys: [String: Set<String>] = [
            "opencode": ["OPENCODE_API_KEY"], "opencode-go": ["OPENCODE_API_KEY"],
            "openai": ["OPENAI_API_KEY", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID"],
            "anthropic": ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
            "google": ["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"],
            "google-vertex": ["GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_VERTEX_PROJECT", "GOOGLE_VERTEX_LOCATION"],
            "google-vertex-anthropic": ["GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_VERTEX_PROJECT", "GOOGLE_VERTEX_LOCATION"],
            "amazon-bedrock": [
                "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_BEARER_TOKEN_BEDROCK",
                "AWS_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION"
            ],
            "azure": ["AZURE_API_KEY", "AZURE_OPENAI_API_KEY", "AZURE_RESOURCE_NAME", "AZURE_OPENAI_ENDPOINT"],
            "github-copilot": ["GITHUB_TOKEN", "GH_TOKEN"], "gitlab": ["GITLAB_TOKEN"],
            "cloudflare-workers-ai": ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_KEY"],
            "cloudflare-ai-gateway": ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_GATEWAY_ID", "CLOUDFLARE_API_TOKEN", "CF_AIG_TOKEN"],
            "snowflake-cortex": ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_CORTEX_TOKEN", "SNOWFLAKE_CORTEX_PAT"],
            "sap-ai-core": ["AICORE_SERVICE_KEY", "AICORE_DEPLOYMENT_ID", "AICORE_RESOURCE_GROUP"]
        ]
        let normalized = provider.uppercased().replacingOccurrences(of: "-", with: "_")
        return keys[provider] ?? ["\(normalized)_API_KEY", "\(normalized)_TOKEN"]
    }
}

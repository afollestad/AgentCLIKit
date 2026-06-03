import Foundation

/// Model option source that queries Codex App Server `model/list` on demand.
///
/// This source starts a temporary App Server transport when `modelOptions(for:)` is called for Codex. It is intentionally
/// opt-in so provider discovery and settings screens can use static or cached model options without launching Codex.
public struct CodexAppServerModelOptionSource: AgentModelOptionSource {
    private let configuration: CodexProviderAdapter.Configuration
    private let fallbackSource: any AgentModelOptionSource
    private let cache = AgentModelOptionMemoryCache()
    private let maximumPages: Int

    /// Creates a Codex App Server model option source.
    public init(
        configuration: CodexProviderAdapter.Configuration = CodexProviderAdapter.Configuration(),
        fallbackSource: any AgentModelOptionSource = StaticAgentModelOptionSource(),
        maximumPages: Int = 10
    ) {
        self.configuration = configuration
        self.fallbackSource = fallbackSource
        self.maximumPages = maximumPages
    }

    /// Returns Codex model options from App Server when possible, falling back to cached or static options.
    public func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption] {
        guard providerId == CodexProviderAdapter.providerId else {
            return await fallbackSource.modelOptions(for: providerId)
        }
        do {
            let liveOptions = try await liveModelOptions()
            guard !liveOptions.isEmpty else {
                return await fallbackOptions(providerId: providerId)
            }
            cache.save(liveOptions, providerId: providerId)
            return liveOptions
        } catch {
            return await fallbackOptions(providerId: providerId)
        }
    }

    private func liveModelOptions() async throws -> [AgentModelOption] {
        let transport = configuration.makeTransport(configuration)
        try await transport.start()
        do {
            _ = try await transport.sendRequest(method: "initialize", params: initializeParams())
            try await transport.sendNotification(method: "initialized", params: nil)

            var options: [AgentModelOption] = []
            var cursor: String?
            var pages = 0
            repeat {
                let response = try await transport.sendRequest(method: "model/list", params: modelListParams(cursor: cursor))
                let parsed = Self.parseModelListResponse(response)
                options.append(contentsOf: parsed.options)
                cursor = parsed.nextCursor
                pages += 1
            } while cursor != nil && pages < maximumPages
            await transport.shutdown()
            return Self.normalized(options)
        } catch {
            await transport.shutdown()
            throw error
        }
    }

    private func fallbackOptions(providerId: AgentProviderID) async -> [AgentModelOption] {
        if let cached = cache.options(providerId: providerId), !cached.isEmpty {
            return cached
        }
        let fallback = await fallbackSource.modelOptions(for: providerId)
        return fallback.isEmpty ? AgentDefaultModelOptions.providerDefault(for: providerId) : fallback
    }

    private func initializeParams() -> JSONValue {
        .object([
            "clientInfo": .object([
                "name": .string("AgentCLIKit"),
                "title": .string("AgentCLIKit"),
                "version": .string("0")
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(configuration.experimentalAPIEnabled),
                "requestAttestation": .bool(false)
            ])
        ])
    }

    private func modelListParams(cursor: String?) -> JSONValue? {
        guard let cursor else {
            return .object([:])
        }
        return .object(["cursor": .string(cursor)])
    }

    private static func parseModelListResponse(_ response: JSONValue) -> (options: [AgentModelOption], nextCursor: String?) {
        guard case let .object(object) = response else {
            return ([], nil)
        }
        let values = object["data"]?.codexArrayValue ?? object["models"]?.codexArrayValue ?? []
        let options = values.compactMap(modelOption(from:))
        let nextCursor = object["nextCursor"]?.codexNonEmptyString ?? object["next_cursor"]?.codexNonEmptyString
        return (options, nextCursor)
    }

    private static func modelOption(from value: JSONValue) -> AgentModelOption? {
        guard case let .object(object) = value,
              object["hidden"]?.codexBoolValue != true,
              let id = object["id"]?.codexNonEmptyString ?? object["model"]?.codexNonEmptyString else {
            return nil
        }
        let displayName = object["displayName"]?.codexNonEmptyString
            ?? object["display_name"]?.codexNonEmptyString
            ?? id
        let model = object["model"]?.codexNonEmptyString ?? id
        let contextWindow = object["contextWindow"]?.codexIntValue
            ?? object["context_window"]?.codexIntValue
            ?? object["modelContextWindow"]?.codexIntValue
        return AgentModelOption(
            providerId: CodexProviderAdapter.providerId,
            id: id,
            model: model,
            label: displayName,
            description: object["description"]?.codexNonEmptyString,
            contextWindowSize: contextWindow,
            isDefault: object["isDefault"]?.codexBoolValue ?? false,
            metadata: [
                "source": .string("codex_app_server")
            ]
        )
    }

    private static func normalized(_ options: [AgentModelOption]) -> [AgentModelOption] {
        var seen = Set<String>()
        var normalized: [AgentModelOption] = []
        for option in options where !seen.contains(option.id) {
            seen.insert(option.id)
            normalized.append(option)
        }
        return normalized.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }
}

private final class AgentModelOptionMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var optionsByProvider: [AgentProviderID: [AgentModelOption]] = [:]

    func save(_ options: [AgentModelOption], providerId: AgentProviderID) {
        lock.withLock {
            optionsByProvider[providerId] = options
        }
    }

    func options(providerId: AgentProviderID) -> [AgentModelOption]? {
        lock.withLock {
            optionsByProvider[providerId]
        }
    }
}

private extension JSONValue {
    var codexNonEmptyString: String? {
        guard case let .string(value) = self, !value.isEmpty else {
            return nil
        }
        return value
    }

    var codexBoolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }

    var codexIntValue: Int? {
        guard case let .number(value) = self else {
            return nil
        }
        return Int(value)
    }

    var codexArrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }
}

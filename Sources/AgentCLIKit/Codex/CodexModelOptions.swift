import Foundation

/// Model option source that queries Codex App Server `model/list` on demand.
///
/// This source starts a temporary App Server transport for Codex when its cache is missing or expired. It is
/// intentionally opt-in so default provider discovery can avoid launching Codex.
public struct CodexAppServerModelOptionSource: AgentModelOptionSource {
    private let configuration: CodexProviderAdapter.Configuration
    private let fallbackSource: any AgentModelOptionSource
    private let cache = AgentModelOptionMemoryCache()
    private let maximumPages: Int
    private let cacheTimeToLive: TimeInterval
    private let now: @Sendable () -> Date

    /// Creates a Codex App Server model option source.
    public init(
        configuration: CodexProviderAdapter.Configuration = CodexProviderAdapter.Configuration(),
        fallbackSource: any AgentModelOptionSource = StaticAgentModelOptionSource(),
        maximumPages: Int = 10,
        cacheTimeToLive: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.fallbackSource = fallbackSource
        self.maximumPages = maximumPages
        self.cacheTimeToLive = cacheTimeToLive
        self.now = now
    }

    /// Returns Codex model options from App Server when possible, falling back to cached or static options.
    public func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption] {
        guard providerId == CodexProviderAdapter.providerId else {
            return await fallbackSource.modelOptions(for: providerId)
        }
        if let cached = cache.freshOptions(providerId: providerId, now: now(), cacheTimeToLive: cacheTimeToLive), !cached.isEmpty {
            return cached
        }
        do {
            let liveOptions = try await liveModelOptions()
            guard !liveOptions.isEmpty else {
                return await fallbackOptions(providerId: providerId)
            }
            cache.save(liveOptions, providerId: providerId, fetchedAt: now())
            return liveOptions
        } catch {
            return await fallbackOptions(providerId: providerId)
        }
    }

    private func liveModelOptions() async throws -> [AgentModelOption] {
        let resolvedConfiguration = await configuration.resolvingExecutableIfNeeded(for: CodexProviderDefinition.definition)
        let transport = resolvedConfiguration.makeTransport(resolvedConfiguration)
        try await transport.start()
        do {
            _ = try await transport.sendRequest(method: "initialize", params: initializeParams(configuration: resolvedConfiguration))
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
        if let cached = cache.staleOptions(providerId: providerId), !cached.isEmpty {
            return cached
        }
        let fallback = await fallbackSource.modelOptions(for: providerId)
        return fallback.isEmpty
            ? AgentDefaultModelOptions.providerDefault(for: providerId, description: "Use the Codex default model.")
            : fallback
    }

    private func initializeParams(configuration: CodexProviderAdapter.Configuration) -> JSONValue {
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
        let supportedEfforts = reasoningEffortOptions(
            from: object["supportedReasoningEfforts"] ?? object["supported_reasoning_efforts"]
        )
        let defaultEffortValue = object["defaultReasoningEffort"]?.codexNonEmptyString
            ?? object["default_reasoning_effort"]?.codexNonEmptyString
        let effortMetadata = completedEffortMetadata(
            supportedEfforts: supportedEfforts,
            defaultEffortValue: defaultEffortValue
        )
        let reportedShortName = object["shortName"]?.codexNonEmptyString
            ?? object["short_name"]?.codexNonEmptyString
            ?? object["slug"]?.codexNonEmptyString
        return AgentModelOption(
            providerId: CodexProviderAdapter.providerId,
            id: id,
            model: model,
            label: displayName,
            shortName: reportedShortName ?? derivedShortName(for: id),
            description: object["description"]?.codexNonEmptyString,
            contextWindowSize: contextWindow,
            isDefault: object["isDefault"]?.codexBoolValue ?? false,
            supportedEffortOptions: effortMetadata.supportedEfforts,
            defaultEffortOption: effortMetadata.defaultEffort,
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
        return resolvingShortNameCollisions(in: normalized)
    }

    /// Model ids such as `gpt-5.6-sol` carry a codename suffix that reads as a usable alias, while ids such as
    /// `gpt-5.5` or `gpt-5.4-mini` do not. Derive only the former so hosts never advertise an ambiguous short name.
    private static func derivedShortName(for id: String) -> String {
        guard let suffix = id.split(separator: "-").last.map(String.init),
              suffix.count >= 3,
              suffix.allSatisfy(\.isLetter),
              !genericModelQualifiers.contains(suffix.lowercased()) else {
            return id
        }
        return suffix.lowercased()
    }

    /// Falls back to the full id whenever a short name is claimed twice or would shadow a different model's id.
    private static func resolvingShortNameCollisions(in options: [AgentModelOption]) -> [AgentModelOption] {
        let ids = Set(options.map { $0.id.lowercased() })
        var shortNameCounts: [String: Int] = [:]
        for option in options {
            shortNameCounts[option.shortName.lowercased(), default: 0] += 1
        }
        return options.map { option in
            let shortName = option.shortName.lowercased()
            guard shortName != option.id.lowercased() else {
                return option
            }
            guard shortNameCounts[shortName, default: 0] > 1 || ids.contains(shortName) else {
                return option
            }
            return option.withShortName(option.id)
        }
    }

    private static let genericModelQualifiers: Set<String> = [
        "codex", "high", "latest", "low", "max", "mini", "nano", "preview", "pro", "turbo"
    ]

    private static func reasoningEffortOptions(from value: JSONValue?) -> [AgentProviderOption] {
        value?.codexArrayValue?.compactMap(reasoningEffortOption(from:)) ?? []
    }

    private static func reasoningEffortOption(from value: JSONValue) -> AgentProviderOption? {
        if let rawValue = value.codexNonEmptyString {
            return synthesizedEffortOption(rawValue)
        }
        guard case let .object(object) = value,
              let effort = object["reasoningEffort"]?.codexNonEmptyString ?? object["reasoning_effort"]?.codexNonEmptyString else {
            return nil
        }
        return AgentProviderOption(
            value: effort,
            label: effortLabel(for: effort),
            description: object["description"]?.codexNonEmptyString ?? effortDescription(for: effort)
        )
    }

    private static func completedEffortMetadata(
        supportedEfforts: [AgentProviderOption],
        defaultEffortValue: String?
    ) -> (supportedEfforts: [AgentProviderOption], defaultEffort: AgentProviderOption?) {
        guard let defaultEffortValue else {
            return (supportedEfforts, nil)
        }
        if let defaultEffort = supportedEfforts.first(where: { $0.value == defaultEffortValue }) {
            return (supportedEfforts, defaultEffort)
        }
        let defaultEffort = synthesizedEffortOption(defaultEffortValue)
        return (supportedEfforts + [defaultEffort], defaultEffort)
    }

    private static func synthesizedEffortOption(_ value: String) -> AgentProviderOption {
        AgentProviderOption(
            value: value,
            label: effortLabel(for: value),
            description: effortDescription(for: value)
        )
    }

    private static func effortLabel(for value: String) -> String {
        switch value {
        case "xhigh":
            return "Extra High"
        default:
            return value
                .split { $0 == "-" || $0 == "_" }
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    private static func effortDescription(for value: String) -> String {
        "Use \(effortLabel(for: value).lowercased()) reasoning effort."
    }
}

private final class AgentModelOptionMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var optionsByProvider: [AgentProviderID: CachedAgentModelOptions] = [:]

    func save(_ options: [AgentModelOption], providerId: AgentProviderID, fetchedAt: Date) {
        lock.withLock {
            optionsByProvider[providerId] = CachedAgentModelOptions(options: options, fetchedAt: fetchedAt)
        }
    }

    func freshOptions(providerId: AgentProviderID, now: Date, cacheTimeToLive: TimeInterval) -> [AgentModelOption]? {
        lock.withLock {
            guard let cached = optionsByProvider[providerId],
                  now.timeIntervalSince(cached.fetchedAt) <= cacheTimeToLive else {
                return nil
            }
            return cached.options
        }
    }

    func staleOptions(providerId: AgentProviderID) -> [AgentModelOption]? {
        lock.withLock {
            optionsByProvider[providerId]?.options
        }
    }
}

private struct CachedAgentModelOptions {
    let options: [AgentModelOption]
    let fetchedAt: Date
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

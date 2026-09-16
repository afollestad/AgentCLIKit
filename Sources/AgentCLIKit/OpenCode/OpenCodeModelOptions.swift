import Foundation

/// Stable metadata keys for OpenCode's provider-specific model capabilities.
public enum OpenCodeModelMetadata {
    /// Provider identifier used in OpenCode prompt requests.
    public static let providerID = "opencode_provider_id"
    /// Model identifier within its provider, which may itself contain slashes.
    public static let modelID = "opencode_model_id"
    /// Whether the selected model explicitly reports image input support.
    public static let supportsImageInput = "supports_image_input"
    /// Provider-reported input limit, when distinct from the context limit.
    public static let inputTokenLimit = "input_token_limit"
    /// Provider-reported maximum output tokens.
    public static let outputTokenLimit = "output_token_limit"
    /// Variant IDs mapped into the model's selectable effort options.
    public static let variants = "opencode_variants"
    /// Whether this model is its provider's default, not the global harness default.
    public static let isProviderDefault = "opencode_provider_default"
}

/// Opt-in provider discovery that preserves full provider/model identities and native variants.
public struct OpenCodeModelOptionSource: AgentModelOptionSource {
    private let probe: OpenCodeDiscoveryProbe

    /// Shares a read-only server probe with setup checks.
    public init(probe: OpenCodeDiscoveryProbe = OpenCodeDiscoveryProbe()) {
        self.probe = probe
    }

    /// Returns connected-provider choices with a stable harness-default fallback.
    public func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption] {
        guard harnessId == .opencode else { return AgentDefaultModelOptions.staticOptions(for: harnessId) }
        return AgentDefaultModelOptions.staticOptions(for: .opencode) + (await probe.refresh()).models
    }

    /// Translates `/provider`, filtering catalog-only providers that cannot currently serve requests.
    public static func parseProviderResponse(_ response: JSONValue) throws -> [AgentModelOption] {
        guard let root = response.discoveryObject,
              case let .array(providers)? = root["all"],
              case let .array(connectedValues)? = root["connected"] else {
            throw AgentCLIError.invalidInput("OpenCode provider response did not include its provider catalog and connections.")
        }
        let connected = Set(connectedValues.compactMap(\.discoveryString))
        let defaults = root["default"]?.discoveryObject ?? [:]
        var options: [String: AgentModelOption] = [:]
        for provider in providers {
            guard let values = provider.discoveryObject,
                  let providerID = values["id"]?.discoveryString,
                  connected.contains(providerID),
                  let models = values["models"]?.discoveryObject else { continue }
            let providerName = values["name"]?.discoveryString ?? providerID
            for (key, value) in models {
                guard let model = value.discoveryObject,
                      model["status"]?.discoveryString != "deprecated" else { continue }
                let modelID = model["id"]?.discoveryString ?? key
                guard !providerID.isEmpty, !modelID.isEmpty else { continue }
                let option = modelOption(
                    model, providerID: providerID, providerName: providerName, modelID: modelID,
                    isProviderDefault: defaults[providerID]?.discoveryString == modelID
                )
                options[option.id] = option
            }
        }
        return options.values.sorted { $0.id < $1.id }
    }

    private static func modelOption(
        _ model: [String: JSONValue], providerID: String, providerName: String, modelID: String, isProviderDefault: Bool
    ) -> AgentModelOption {
        let identifier = "\(providerID)/\(modelID)"
        let limit = model["limit"]?.discoveryObject ?? [:]
        let capabilities = model["capabilities"]?.discoveryObject ?? [:]
        let input = capabilities["input"]?.discoveryObject ?? [:]
        let variants = (model["variants"]?.discoveryObject ?? [:]).filter { _, value in
            value.discoveryObject?["disabled"] != .bool(true)
        }.keys.sorted()
        var metadata: [String: JSONValue] = [
            OpenCodeModelMetadata.providerID: .string(providerID),
            OpenCodeModelMetadata.modelID: .string(modelID),
            OpenCodeModelMetadata.supportsImageInput: .bool(input["image"] == .bool(true)),
            OpenCodeModelMetadata.variants: .array(variants.map(JSONValue.string)),
            OpenCodeModelMetadata.isProviderDefault: .bool(isProviderDefault)
        ]
        metadata[OpenCodeModelMetadata.inputTokenLimit] = limit["input"]
        metadata[OpenCodeModelMetadata.outputTokenLimit] = limit["output"]
        return AgentModelOption(
            harnessId: .opencode,
            id: identifier,
            model: identifier,
            label: "\(model["name"]?.discoveryString ?? modelID) · \(providerName)",
            shortName: identifier,
            contextWindowSize: limit["context"]?.discoveryPositiveInt,
            supportedEffortOptions: variants.map { AgentHarnessOption(value: $0, label: $0, description: "OpenCode model variant: \($0)") },
            metadata: metadata
        )
    }
}

private extension JSONValue {
    var discoveryObject: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var discoveryString: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var discoveryPositiveInt: Int? {
        guard case let .number(value) = self, value > 0, value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }
}

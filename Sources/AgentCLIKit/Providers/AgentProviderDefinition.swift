import Foundation

/// Static metadata and capabilities for an agent CLI provider.
public struct AgentProviderDefinition: Codable, Equatable, Sendable {
    /// Stable provider identifier.
    public let id: AgentProviderID
    /// Display name for diagnostics and host UI.
    public let displayName: String
    /// Candidate executable names or absolute paths used for provider detection.
    public let executableNames: [String]
    /// Capabilities supported by the provider adapter.
    public let capabilities: AgentProviderCapabilities
    /// Permission modes supported by the provider, when the provider exposes named modes.
    public let supportedPermissionModes: [AgentProviderOption]?
    /// Effort levels supported by the provider, when the provider exposes effort selection.
    public let supportedEffortLevels: [String]?

    /// Creates a provider definition.
    public init(
        id: AgentProviderID,
        displayName: String,
        executableNames: [String],
        capabilities: AgentProviderCapabilities = AgentProviderCapabilities(),
        supportedPermissionModes: [AgentProviderOption]? = nil,
        supportedEffortLevels: [String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.executableNames = executableNames
        self.capabilities = capabilities
        self.supportedPermissionModes = supportedPermissionModes
        self.supportedEffortLevels = supportedEffortLevels
    }

    /// Decodes provider metadata, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(AgentProviderID.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.executableNames = try container.decode([String].self, forKey: .executableNames)
        self.capabilities = try container.decodeIfPresent(AgentProviderCapabilities.self, forKey: .capabilities) ?? AgentProviderCapabilities()
        self.supportedPermissionModes = try container.decodeIfPresent([AgentProviderOption].self, forKey: .supportedPermissionModes)
        self.supportedEffortLevels = try container.decodeIfPresent([String].self, forKey: .supportedEffortLevels)
    }
}

/// Provider features that host apps can inspect before enabling workflows.
public struct AgentProviderCapabilities: Codable, Equatable, Sendable {
    /// Whether the provider supports resuming a previous provider session.
    public let supportsSessionResume: Bool
    /// Whether the provider supports local hook callbacks.
    public let supportsHooks: Bool
    /// Whether the provider can use MCP servers.
    public let supportsMCP: Bool
    /// Whether the provider can request host approval interactions.
    public let supportsApprovals: Bool
    /// Whether the provider exposes token or context-window usage.
    public let supportsUsage: Bool
    /// Whether the provider can accept user input while a turn is active.
    public let supportsMidTurnSteering: Bool

    /// Creates provider capability metadata.
    public init(
        supportsSessionResume: Bool = false,
        supportsHooks: Bool = false,
        supportsMCP: Bool = false,
        supportsApprovals: Bool = false,
        supportsUsage: Bool = false,
        supportsMidTurnSteering: Bool = false
    ) {
        self.supportsSessionResume = supportsSessionResume
        self.supportsHooks = supportsHooks
        self.supportsMCP = supportsMCP
        self.supportsApprovals = supportsApprovals
        self.supportsUsage = supportsUsage
        self.supportsMidTurnSteering = supportsMidTurnSteering
    }

    /// Decodes capability metadata, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.supportsSessionResume = try container.decodeIfPresent(Bool.self, forKey: .supportsSessionResume) ?? false
        self.supportsHooks = try container.decodeIfPresent(Bool.self, forKey: .supportsHooks) ?? false
        self.supportsMCP = try container.decodeIfPresent(Bool.self, forKey: .supportsMCP) ?? false
        self.supportsApprovals = try container.decodeIfPresent(Bool.self, forKey: .supportsApprovals) ?? false
        self.supportsUsage = try container.decodeIfPresent(Bool.self, forKey: .supportsUsage) ?? false
        self.supportsMidTurnSteering = try container.decodeIfPresent(Bool.self, forKey: .supportsMidTurnSteering) ?? false
    }
}

/// User-facing provider option metadata for host settings and launch controls.
public struct AgentProviderOption: Codable, Equatable, Sendable {
    /// Provider wire value.
    public let value: String
    /// Short label for host UI.
    public let label: String
    /// Longer host-facing description.
    public let description: String

    /// Creates provider option metadata.
    public init(value: String, label: String, description: String) {
        self.value = value
        self.label = label
        self.description = description
    }
}

/// Provider availability result returned by detection services.
public struct AgentProviderAvailability: Codable, Equatable, Sendable {
    /// Provider that was checked.
    public let providerId: AgentProviderID
    /// Resolved executable path when available.
    public let executablePath: String?
    /// Version output returned by the provider when requested.
    public let versionDescription: String?

    /// Whether an executable was found.
    public var isAvailable: Bool {
        executablePath != nil
    }

    /// Creates a provider availability value.
    public init(providerId: AgentProviderID, executablePath: String?, versionDescription: String? = nil) {
        self.providerId = providerId
        self.executablePath = executablePath
        self.versionDescription = versionDescription
    }
}

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

    /// Creates a provider definition.
    public init(
        id: AgentProviderID,
        displayName: String,
        executableNames: [String],
        capabilities: AgentProviderCapabilities = AgentProviderCapabilities()
    ) {
        self.id = id
        self.displayName = displayName
        self.executableNames = executableNames
        self.capabilities = capabilities
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

    /// Creates provider capability metadata.
    public init(
        supportsSessionResume: Bool = false,
        supportsHooks: Bool = false,
        supportsMCP: Bool = false,
        supportsApprovals: Bool = false,
        supportsUsage: Bool = false
    ) {
        self.supportsSessionResume = supportsSessionResume
        self.supportsHooks = supportsHooks
        self.supportsMCP = supportsMCP
        self.supportsApprovals = supportsApprovals
        self.supportsUsage = supportsUsage
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

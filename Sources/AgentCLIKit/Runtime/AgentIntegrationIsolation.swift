import Foundation

/// Harness integrations a host can withhold from one conversation, so the agent reaches external services only
/// through the host's own tools.
///
/// Hosts should request only options listed in `AgentHarnessCapabilities.supportedIntegrationIsolation`; launching
/// with an unsupported option throws `AgentCLIError.unsupportedCapability` rather than silently running unisolated.
public struct AgentIntegrationIsolation: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    /// Creates an isolation set from its raw bit mask.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Withholds harness-native connectors, apps, plugins, and user-configured MCP servers the harness can drop per
    /// conversation. Host tools stay available.
    public static let nativeIntegrations = AgentIntegrationIsolation(rawValue: 1 << 0)
    /// Runs the agent's shell commands without network access.
    public static let shellNetwork = AgentIntegrationIsolation(rawValue: 1 << 1)
}

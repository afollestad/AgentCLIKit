import Foundation

/// OpenCode metadata for the HTTP server protocol supported by this adapter.
public enum OpenCodeHarnessDefinition {
    /// Stable CLI identity, independent of the model provider used by OpenCode.
    public static let harnessId: AgentHarnessID = .opencode

    /// Features translated by AgentCLIKit rather than every feature in the OpenCode terminal UI.
    public static let definition = AgentHarnessDefinition(
        id: harnessId,
        displayName: "OpenCode",
        executableNames: ["opencode"],
        capabilities: AgentHarnessCapabilities(
            supportsSessionResume: true,
            supportsMCP: true,
            supportsApprovals: true,
            supportsUsage: true,
            supportsMidTurnSteering: true,
            supportsToolEvents: true,
            supportsGroupedToolOutput: true,
            supportsPlanMode: true,
            supportsTaskLists: true,
            supportsSubagents: true,
            supportsPromptRequests: true,
            supportsContextWindow: true,
            supportsContextCompaction: true,
            supportsNativeThreadFork: true,
            supportsModelOptions: true,
            supportsSessionArchiving: true,
            supportsSessionDeletion: true,
            supportsLocalImageInput: true,
            supportsReadOnlyOneShotPrompts: true,
            supportedIntegrationIsolation: [.nativeIntegrations]
        ),
        supportedPermissionModes: [
            AgentHarnessOption(
                value: "configured", label: "Configured", description: "Use the permissions configured in OpenCode."
            ),
            AgentHarnessOption(
                value: "ask", label: "Ask", description: "Ask before tool actions that require permission."
            ),
            AgentHarnessOption(
                value: "fullAccess", label: "Full access", description: "Allow tool actions without asking for approval."
            )
        ]
    )

    /// New sessions ask for permission unless a host explicitly selects another policy.
    public static let defaultPermissionMode = "ask"
}

/// Keeps an unrecognized server protocol from being treated as a compatible installation.
public enum OpenCodeVersionSupport {
    /// First OpenCode version targeted by this adapter.
    public static let minimumVersion = "1.18.31"

    /// Accepts supported stable 1.x versions, rejecting prereleases and unknown major protocols.
    public static func validate(_ version: String) throws {
        let value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let release = normalized.split(separator: "+", maxSplits: 1).first.map(String.init) ?? normalized
        let components = release.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2]),
              major == 1, minor > 18 || (minor == 18 && patch >= 31) else {
            throw AgentCLIError.unsupportedCapability(
                harnessId: .opencode,
                capability: "OpenCode server version \(value); requires >=\(minimumVersion) and <2.0.0"
            )
        }
    }
}

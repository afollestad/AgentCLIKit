import Foundation

/// Resolves the executable path that should be used for a provider launch.
///
/// Hosts can supply a custom resolver when they need to constrain lookup to a sandbox, test fixture, or known install
/// location. Built-in provider adapters use this only when their configuration asks to launch through `/usr/bin/env`;
/// an explicitly configured executable path remains authoritative and bypasses resolution.
public protocol AgentProviderExecutableResolving: Sendable {
    /// Returns a runnable executable path for the provider definition, or `nil` when no candidate can be resolved.
    func resolvedExecutablePath(for definition: AgentProviderDefinition) async -> String?
}

/// Default executable resolver backed by `AgentProviderDetector`.
///
/// The detector checks exact executable paths first, then `PATH`, login-shell lookup, and standard provider install
/// directories. It also validates the detected executable through the provider definition's version arguments.
public struct DefaultAgentProviderExecutableResolver: AgentProviderExecutableResolving {
    private let detector: AgentProviderDetector

    /// Creates a resolver backed by the supplied provider detector.
    /// - Parameter detector: Detector that performs provider-specific executable lookup.
    public init(detector: AgentProviderDetector = AgentProviderDetector()) {
        self.detector = detector
    }

    /// Returns the detected executable path for the provider definition.
    public func resolvedExecutablePath(for definition: AgentProviderDefinition) async -> String? {
        await detector.availability(for: definition).executablePath
    }
}

import Foundation

/// Resolves the executable path that should be used for a harness launch.
///
/// Hosts can supply a custom resolver when they need to constrain lookup to a sandbox, test fixture, or known install
/// location. Built-in harness adapters use this only when their configuration asks to launch through `/usr/bin/env`;
/// an explicitly configured executable path remains authoritative and bypasses resolution.
public protocol AgentHarnessExecutableResolving: Sendable {
    /// Returns a runnable executable path for the harness definition, or `nil` when no candidate can be resolved.
    func resolvedExecutablePath(for definition: AgentHarnessDefinition) async -> String?
}

/// Default executable resolver backed by `AgentHarnessDetector`.
///
/// The detector checks exact executable paths first, then `PATH`, login-shell lookup, and standard harness install
/// directories. It also validates the detected executable through the harness definition's version arguments.
public struct DefaultAgentHarnessExecutableResolver: AgentHarnessExecutableResolving {
    private let detector: AgentHarnessDetector

    /// Creates a resolver backed by the supplied harness detector.
    /// - Parameter detector: Detector that performs harness-specific executable lookup.
    public init(detector: AgentHarnessDetector = AgentHarnessDetector()) {
        self.detector = detector
    }

    /// Returns the detected executable path for the harness definition.
    public func resolvedExecutablePath(for definition: AgentHarnessDefinition) async -> String? {
        await detector.availability(for: definition).executablePath
    }
}

import Foundation

/// Read-only setup checks for OpenCode; provider authentication stays owned by OpenCode.
public struct OpenCodeHarnessSetup: AgentHarnessSetup {
    /// Harness whose server and provider readiness are checked.
    public let harnessId: AgentHarnessID = .opencode
    private let probe: OpenCodeDiscoveryProbe

    /// Shares a probe with `OpenCodeModelOptionSource` to avoid duplicate startup work.
    public init(probe: OpenCodeDiscoveryProbe = OpenCodeDiscoveryProbe()) {
        self.probe = probe
    }

    /// Returns the last observed setup state without starting a process.
    public func cachedSetupReadiness() -> AgentHarnessReadinessState {
        probe.cachedSnapshot().readiness
    }

    /// Checks the supported server version and connected-provider catalog.
    public func setupReadiness() async -> AgentHarnessReadinessState {
        await probe.refresh(force: true).readiness
    }

    /// Returns guidance from the same cached or refreshed probe as readiness.
    public func setupDiagnostics() async -> [String] {
        await probe.refresh().diagnostics
    }

    /// OpenCode has no project-trust gate managed by this adapter.
    public func trustProject(at projectURL: URL) async throws {}
}

import Foundation

@testable import AgentCLIKit

struct FixedCodexFeatureSupportChecker: CodexFeatureSupportChecking {
    let supportsFastMode: Bool
    var supportsGoalMode = true
    var supportsRuntimeWorkspaceRoots = true

    func supportsFastMode(
        configuration: CodexHarnessAdapter.Configuration,
        availability: AgentHarnessAvailability?
    ) async -> Bool {
        supportsFastMode
    }

    func supportsGoalMode(
        configuration: CodexHarnessAdapter.Configuration,
        availability: AgentHarnessAvailability?
    ) async -> Bool {
        supportsGoalMode
    }

    func supportsRuntimeWorkspaceRoots(
        configuration: CodexHarnessAdapter.Configuration,
        availability: AgentHarnessAvailability?
    ) async -> Bool {
        supportsRuntimeWorkspaceRoots
    }
}

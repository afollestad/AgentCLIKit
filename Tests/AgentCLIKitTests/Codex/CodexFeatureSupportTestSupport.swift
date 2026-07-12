import Foundation

@testable import AgentCLIKit

struct FixedCodexFeatureSupportChecker: CodexFeatureSupportChecking {
    let supportsFastMode: Bool
    var supportsGoalMode = true
    var supportsRuntimeWorkspaceRoots = true

    func supportsFastMode(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async -> Bool {
        supportsFastMode
    }

    func supportsGoalMode(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async -> Bool {
        supportsGoalMode
    }

    func supportsRuntimeWorkspaceRoots(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async -> Bool {
        supportsRuntimeWorkspaceRoots
    }
}

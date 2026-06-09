import Foundation

@testable import AgentCLIKit

struct FixedCodexFeatureSupportChecker: CodexFeatureSupportChecking {
    let supportsFastMode: Bool

    func supportsFastMode(
        configuration: CodexProviderAdapter.Configuration,
        availability: AgentProviderAvailability?
    ) async -> Bool {
        supportsFastMode
    }
}

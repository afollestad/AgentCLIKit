import XCTest

@testable import AgentCLIKit

final class AgentCLIKitPublicContractTests: XCTestCase {
    func testHostFacingTypesRemainSendable() {
        assertSendable(AgentCLIError.self)
        assertSendable(AgentDiagnosticEvent.self)
        assertSendable(AgentActivityEvent.self)
        assertSendable(AgentEventEnvelope.self)
        assertSendable(AgentEventSubscription.self)
        assertSendable(AgentRuntimeStatus.self)
        assertSendable(AgentInteractionRecord.self)
        assertSendable(AgentPendingAction.self)
        assertSendable(AgentProviderAdapterSet.self)
        assertSendable(AgentProviderInputContext.self)
        assertSendable(AgentProviderRuntimeContext.self)
        assertSendable(AgentProviderInterruptContext.self)
        assertSendable(AgentProviderRuntimeEvent.self)
        assertSendable(AgentProjectTrustStatus.self)
        assertSendable(DefaultAgentProjectTrustService.self)
        assertSendable(CodexConfig.self)
        assertSendable(CodexConfigSnapshot.self)
        assertSendable(CodexMCPServerConfig.self)
        assertSendable(CodexAuthReadiness.self)
        assertSendable(CodexAuthProbe.self)
        assertSendable(ClaudeProviderAdapter.Configuration.self)
        assertSendable(MainActorClaudeHookDecisionProvider.self)
    }

    private func assertSendable<T: Sendable>(_ type: T.Type) {}
}

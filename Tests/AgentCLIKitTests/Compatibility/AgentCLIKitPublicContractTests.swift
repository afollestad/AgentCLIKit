import XCTest

@testable import AgentCLIKit

final class AgentCLIKitPublicContractTests: XCTestCase {
    func testHostFacingTypesRemainSendable() {
        assertSendable(AgentCLIError.self)
        assertSendable(AgentDiagnosticEvent.self)
        assertSendable(AgentActivityEvent.self)
        assertSendable(AgentContextCompactionEvent.self)
        assertSendable(AgentContextCompactionPhase.self)
        assertSendable(AgentEventEnvelope.self)
        assertSendable(AgentEventSubscription.self)
        assertSendable(AgentRuntimeStatus.self)
        assertSendable(AgentInteractionRecord.self)
        assertSendable(AgentPendingAction.self)
        assertSendable(AgentProviderAdapterSet.self)
        assertSendable(AgentProviderSessionActionRouter.self)
        assertSendable(AgentProviderOutputContext.self)
        assertSendable(AgentProviderInputContext.self)
        assertSendable(AgentProviderRuntimeContext.self)
        assertSendable(AgentProviderInterruptContext.self)
        assertSendable(AgentProviderRuntimeEvent.self)
        assertSendable(AgentProjectTrustStatus.self)
        assertSendable(DefaultAgentProjectTrustService.self)
        assertSendable(AgentProviderInstallationState.self)
        assertSendable(AgentModelOption.self)
        assertSendable(AgentProviderStatus.self)
        assertSendable(StaticAgentProviderEnablementSource.self)
        assertSendable(StaticAgentModelOptionSource.self)
        assertSendable(DefaultAgentProviderDiscoveryService.self)
        assertSendable(CodexConfig.self)
        assertSendable(CodexConfigSnapshot.self)
        assertSendable(CodexMCPServerConfig.self)
        assertSendable(CodexAuthReadiness.self)
        assertSendable(CodexAuthProbe.self)
        assertSendable(CodexAppServerModelOptionSource.self)
        assertSendable(ClaudeProviderAdapter.Configuration.self)
        assertSendable(MainActorClaudeHookDecisionProvider.self)
    }

    private func assertSendable<T: Sendable>(_ type: T.Type) {}
}

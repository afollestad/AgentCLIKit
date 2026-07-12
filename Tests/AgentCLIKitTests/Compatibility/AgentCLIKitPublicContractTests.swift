import XCTest

@testable import AgentCLIKit

final class AgentCLIKitPublicContractTests: XCTestCase {
    func testHostFacingTypesRemainSendable() {
        assertSendable(AgentCLIError.self)
        assertSendable(AgentDiagnosticEvent.self)
        assertSendable(AgentActivityEvent.self)
        assertSendable(AgentContextCompactionEvent.self)
        assertSendable(AgentContextCompactionPhase.self)
        assertSendable(AgentSubAgentEvent.self)
        assertSendable(AgentSubAgentPhase.self)
        assertSendable(AgentSessionMetadataEvent.self)
        assertSendable(AgentEventEnvelope.self)
        assertSendable(AgentEventSubscription.self)
        assertSendable(AgentCollaborationMode.self)
        assertSendable(AgentSpeedMode.self)
        assertSendable(AgentGoalStatus.self)
        assertSendable(AgentGoalAction.self)
        assertSendable(AgentGoalSnapshot.self)
        assertSendable(AgentGoalEvent.self)
        assertSendable(AgentCollaborationModeEvent.self)
        assertSendable(AgentRuntimeStatus.self)
        assertSendable(AgentRuntimeReconfigureResult.self)
        assertSendable(AgentInteractionRecord.self)
        assertSendable(AgentPendingAction.self)
    }

    func testProviderRuntimeTypesRemainSendable() {
        assertSendable(AgentSpawnConfig.self)
        assertSendable(AgentProviderAdapterSet.self)
        assertSendable(AgentProviderSessionActionRouter.self)
        assertSendable(AgentProviderLaunchContext.self)
        assertSendable(AgentProviderOutputContext.self)
        assertSendable(AgentProviderInputContext.self)
        assertSendable(AgentProviderRuntimeContext.self)
        assertSendable(AgentProviderInterruptContext.self)
        assertSendable(AgentProviderEncodedGoalStart.self)
        assertSendable(AgentProviderGoalStartContext.self)
        assertSendable(AgentProviderGoalActionContext.self)
        assertSendable(AgentProviderReconfigureContext.self)
        assertSendable(AgentProviderReconfigureResult.self)
        assertSendable(AgentProviderRuntimeEvent.self)
    }

    func testHostToolTypesRemainSendable() {
        assertSendable(AgentHostToolDefinition.self)
        assertSendable(AgentHostToolAnnotations.self)
        assertSendable(AgentHostToolServerMetadata.self)
        assertSendable(AgentHostToolCallContext.self)
        assertSendable(AgentHostToolCall.self)
        assertSendable(AgentHostToolResult.self)
        assertSendable(AgentHostToolHandling.self)
        assertSendable(AgentHostToolEndpoint.self)
    }

    func testProviderServiceTypesRemainSendable() {
        assertSendable(AgentProjectTrustStatus.self)
        assertSendable(DefaultAgentProjectTrustService.self)
        assertSendable(AgentProviderInstallationState.self)
        assertSendable(AgentModelOption.self)
        assertSendable(AgentProviderStatus.self)
        assertSendable(StaticAgentProviderEnablementSource.self)
        assertSendable(StaticAgentProviderCapabilitySource.self)
        assertSendable(DefaultAgentProviderCapabilitySource.self)
        assertSendable(CodexProviderCapabilitySource.self)
        assertSendable(DefaultCodexFeatureSupportChecker.self)
        assertSendable(DefaultAgentProviderExecutableResolver.self)
        assertSendable(StaticAgentModelOptionSource.self)
        assertSendable(DefaultAgentModelOptionSource.self)
        assertSendable(DefaultAgentProviderDiscoveryService.self)
        assertSendable(CodexConfig.self)
        assertSendable(CodexConfigSnapshot.self)
        assertSendable(CodexMCPServerConfig.self)
        assertSendable(CodexAuthReadiness.self)
        assertSendable(CodexAuthProbe.self)
        assertSendable(CodexAppServerModelOptionSource.self)
        assertSendable(AgentCommandApprovalNormalizationPolicy.self)
        assertSendable(CodexProviderAdapter.Configuration.self)
        assertSendable(ClaudeProviderAdapter.Configuration.self)
        assertSendable(MainActorClaudeHookDecisionProvider.self)
    }

    func testOneShotTypesRemainSendable() {
        assertSendable(AgentOneShotToolPolicy.self)
        assertSendable(AgentOneShotPromptRequest.self)
        assertSendable(AgentOneShotPromptResult.self)
        assertSendable(AgentOneShotPromptError.self)
        assertSendable(DefaultAgentOneShotPromptRunner.self)
    }

    private func assertSendable<T: Sendable>(_ type: T.Type) {}
}

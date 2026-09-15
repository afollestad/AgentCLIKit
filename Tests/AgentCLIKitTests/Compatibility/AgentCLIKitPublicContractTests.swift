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

    func testHarnessRuntimeTypesRemainSendable() {
        assertSendable(AgentSpawnConfig.self)
        assertSendable(AgentHarnessAdapterSet.self)
        assertSendable(AgentHarnessSessionActionRouter.self)
        assertSendable(AgentHarnessLaunchContext.self)
        assertSendable(AgentHarnessOutputContext.self)
        assertSendable(AgentHarnessInputContext.self)
        assertSendable(AgentHarnessRuntimeContext.self)
        assertSendable(AgentHarnessInterruptContext.self)
        assertSendable(AgentHarnessEncodedGoalStart.self)
        assertSendable(AgentHarnessGoalStartContext.self)
        assertSendable(AgentHarnessGoalActionContext.self)
        assertSendable(AgentHarnessReconfigureContext.self)
        assertSendable(AgentHarnessReconfigureResult.self)
        assertSendable(AgentHarnessRuntimeEvent.self)
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

    func testHarnessServiceTypesRemainSendable() {
        assertSendable(AgentProjectTrustStatus.self)
        assertSendable(DefaultAgentProjectTrustService.self)
        assertSendable(AgentHarnessInstallationState.self)
        assertSendable(AgentModelOption.self)
        assertSendable(AgentHarnessStatus.self)
        assertSendable(StaticAgentHarnessEnablementSource.self)
        assertSendable(StaticAgentHarnessCapabilitySource.self)
        assertSendable(DefaultAgentHarnessCapabilitySource.self)
        assertSendable(CodexHarnessCapabilitySource.self)
        assertSendable(DefaultCodexFeatureSupportChecker.self)
        assertSendable(DefaultAgentHarnessExecutableResolver.self)
        assertSendable(StaticAgentModelOptionSource.self)
        assertSendable(DefaultAgentModelOptionSource.self)
        assertSendable(DefaultAgentHarnessDiscoveryService.self)
        assertSendable(CodexConfig.self)
        assertSendable(CodexConfigSnapshot.self)
        assertSendable(CodexMCPServerConfig.self)
        assertSendable(CodexAuthReadiness.self)
        assertSendable(CodexAuthProbe.self)
        assertSendable(CodexAppServerModelOptionSource.self)
        assertSendable(AgentCommandApprovalNormalizationPolicy.self)
        assertSendable(CodexHarnessAdapter.Configuration.self)
        assertSendable(ClaudeHarnessAdapter.Configuration.self)
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

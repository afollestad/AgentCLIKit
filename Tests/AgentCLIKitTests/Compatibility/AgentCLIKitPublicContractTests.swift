import XCTest

@testable import AgentCLIKit

final class AgentCLIKitPublicContractTests: XCTestCase {
    func testHostFacingTypesRemainSendable() {
        assertSendable(AgentCLIError.self)
        assertSendable(AgentDiagnosticEvent.self)
        assertSendable(AgentEventEnvelope.self)
        assertSendable(AgentEventSubscription.self)
        assertSendable(AgentRuntimeStatus.self)
        assertSendable(AgentInteractionRecord.self)
        assertSendable(AgentPendingAction.self)
        assertSendable(MainActorClaudeHookDecisionProvider.self)
    }

    private func assertSendable<T: Sendable>(_ type: T.Type) {}
}

import XCTest

@testable import AgentCLIKit

extension RuntimeInteractionResolutionTests {
    func testSameProposalIdWithDifferentPlanMarkdownSynthesizesReplacementPlanModeExit() async throws {
        let recorder = PlanProposalRecorder()
        let runtime = DefaultAgentRuntime(adapters: [
            PlanProposalProviderAdapter(recorder: recorder, emitsPlanRevisionAfterResolution: true)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            collaborationMode: .plan
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        var iterator = subscription.events.makeAsyncIterator()
        try await runtime.spawn(conversationId: conversationId, config: config)
        let firstInteraction = try await Self.nextPlanModeExit(from: &iterator)
        try await runtime.resolveInteraction(
            AgentInteractionResolution(id: firstInteraction.id, outcome: .denied),
            conversationId: conversationId
        )
        let secondInteraction = try await Self.nextPlanModeExit(from: &iterator)
        let status = await runtime.status(conversationId: conversationId)

        await runtime.shutdown()

        XCTAssertEqual(firstInteraction.id, "runtime-plan-exit-plan-1")
        XCTAssertNotEqual(secondInteraction.id, firstInteraction.id)
        XCTAssertEqual(firstInteraction.metadata["plan"], .string(PlanProposalProviderAdapter.planMarkdown))
        XCTAssertEqual(secondInteraction.metadata["plan"], .string(PlanProposalProviderAdapter.revisedPlanMarkdown))
        XCTAssertEqual(secondInteraction.metadata[AgentPlanProposalMetadata.proposalId], .string("plan-1"))
        XCTAssertEqual(status?.waitingState, .planModeExit)
    }

    private static func nextPlanModeExit(
        from iterator: inout AsyncStream<AgentEventEnvelope>.Iterator
    ) async throws -> AgentInteractionEvent {
        while let envelope = await iterator.next() {
            guard case let .interaction(interaction) = envelope.event,
                  interaction.kind == .planModeExit else {
                continue
            }
            return interaction
        }
        throw AgentCLIError.invalidInput("Expected a plan-mode exit interaction.")
    }
}

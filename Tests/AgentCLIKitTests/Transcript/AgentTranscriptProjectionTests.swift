import XCTest

@testable import AgentCLIKit

final class AgentTranscriptProjectionTests: XCTestCase {
    func testProjectorMapsInteractionsTasksAndNotes() {
        let envelopes = [
            envelope(index: 2, event: .lifecycle(AgentLifecycleEvent(state: .cancelled, message: "Interrupted"))),
            envelope(index: 0, event: .interaction(AgentInteractionEvent(id: "approval", kind: .approval, prompt: "Approve Edit?"))),
            envelope(index: 1, event: .task(AgentTaskEvent(
                id: "todos",
                phase: .progress,
                description: "Tasks",
                metadata: ["todos": .array([])]
            )))
        ]

        let projections = AgentTranscriptProjector().project(envelopes)

        XCTAssertEqual(projections.map(\.kind), [.approval, .taskList, .centeredNote])
        XCTAssertEqual(projections.map(\.title), ["Approve Edit?", "Tasks", "Interrupted"])
    }

    func testMetricsBuilderUsesLatestUsageAndRateLimit() {
        let usage = AgentUsageEvent(
            model: "claude",
            inputTokens: 10,
            outputTokens: 20,
            contextWindow: 200_000
        )
        let rateLimit = AgentRateLimitEvent(status: .allowedWarning, utilization: 0.8)

        let metrics = AgentConversationMetricsBuilder().build(from: [
            envelope(index: 0, event: .usage(AgentUsageEvent(model: "old", inputTokens: 1, outputTokens: 1))),
            envelope(index: 2, event: .rateLimit(rateLimit)),
            envelope(index: 1, event: .usage(usage))
        ])

        XCTAssertEqual(metrics.usage, usage)
        XCTAssertEqual(metrics.rateLimit, rateLimit)
        XCTAssertEqual(metrics.model, "claude")
        XCTAssertEqual(metrics.contextWindow, 200_000)
    }

    private func envelope(index: Int, event: AgentEvent) -> AgentEventEnvelope {
        AgentEventEnvelope(
            generation: 1,
            index: index,
            providerId: "provider",
            conversationId: "conversation",
            providerSessionId: nil,
            source: .stdout,
            event: event,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
}

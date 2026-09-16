import XCTest

@testable import AgentCLIKit

final class OpenCodeQuestionValidationTests: XCTestCase {
    func testClosedChoiceQuestionCannotAccidentallyApprovePlanWithFreeTextOrEmptyAnswer() async throws {
        let question: JSONValue = .object([
            "id": .string("que_plan"), "sessionID": .string("ses_current"), "questions": .array([
                .object(["question": .string("Start implementing?"), "custom": .bool(false), "options": .array([
                    .object(["label": .string("Yes")]), .object(["label": .string("No")])
                ])])
            ])
        ])
        let fixture = OpenCodeCompatibilityFixture(transport: OpenCodeCompatibilityTransport(questions: [question]))
        _ = try await fixture.launch()
        for answers in [[], ["Explain more"], ["Yes", "No"]] as [[String]] {
            do {
                try await fixture.send(.interactionResolution(AgentInteractionResolution(
                    id: "que_plan", outcome: .answered,
                    metadata: ["opencode_answers": .array([.array(answers.map(JSONValue.string))])]
                )))
                XCTFail("A native closed-choice question must not accept an invalid answer")
            } catch { XCTAssertTrue(error is AgentCLIError) }
        }
        let requests = await fixture.transport.requests
        XCTAssertFalse(requests.contains { $0.path == "/question/que_plan/reply" })
        try await fixture.send(.interactionResolution(AgentInteractionResolution(id: "que_plan", outcome: .answered, responseText: "No")))
        let replies = await fixture.transport.requests.filter { $0.path == "/question/que_plan/reply" }
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.body, .object(["answers": .array([.array([.string("No")])])]))
        await fixture.stop()
    }
}

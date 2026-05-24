import XCTest

@testable import AgentCLIKit

final class AgentEventAndInputTests: XCTestCase {
    func testEventEnvelopeRoundTripsThroughJSON() throws {
        let envelope = AgentEventEnvelope(
            generation: 1,
            index: 3,
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: "provider-session",
            source: .stdout,
            event: .message(AgentMessageEvent(role: .assistant, text: "Done.")),
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(AgentEventEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
    }

    func testStreamingAndReasoningEventsRoundTripThroughJSON() throws {
        let events: [AgentEvent] = [
            .messageDelta(AgentMessageDeltaEvent(
                role: .assistant,
                text: "partial",
                metadata: ["parent_tool_use_id": .string("task-1")]
            )),
            .reasoning(AgentReasoningEvent(
                text: "thinking",
                metadata: ["provider": .string("test")]
            ))
        ]

        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([AgentEvent].self, from: data)

        XCTAssertEqual(decoded, events)
    }

    func testRateLimitEventRoundTripsThroughJSON() throws {
        let event = AgentEvent.rateLimit(AgentRateLimitEvent(
            status: .allowedWarning,
            resetDate: Date(timeIntervalSince1970: 1_779_375_000),
            limitType: "five_hour",
            utilization: 0.82,
            overageStatus: .rejected,
            metadata: ["provider": .string("claude")]
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }

    func testMessageAndToolEventsDecodeWhenMetadataIsMissing() throws {
        let messageData = Data(#"{"role":"assistant","text":"Done."}"#.utf8)
        let toolCallData = Data(#"{"id":"tool-1","name":"Edit","input":{"file_path":"README.md"}}"#.utf8)
        let toolResultData = Data(#"{"id":"tool-1","isError":false,"content":"ok"}"#.utf8)

        let message = try JSONDecoder().decode(AgentMessageEvent.self, from: messageData)
        let toolCall = try JSONDecoder().decode(AgentToolCallEvent.self, from: toolCallData)
        let toolResult = try JSONDecoder().decode(AgentToolResultEvent.self, from: toolResultData)

        XCTAssertEqual(message.metadata, [:])
        XCTAssertEqual(toolCall.metadata, [:])
        XCTAssertEqual(toolResult.metadata, [:])
    }

    func testEventEnvelopeDecodesPersistedEventsWithMissingMetadata() throws {
        let envelope = AgentEventEnvelope(
            generation: 1,
            index: 3,
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: "provider-session",
            source: .stdout,
            event: .toolCall(AgentToolCallEvent(
                id: "tool-1",
                name: "Edit",
                input: .object(["file_path": .string("README.md")]),
                metadata: ["parent_tool_use_id": .string("agent-tool-1")]
            )),
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data)
        let legacyData = try JSONSerialization.data(withJSONObject: removingMetadata(from: object))

        let decoded = try JSONDecoder().decode(AgentEventEnvelope.self, from: legacyData)

        XCTAssertEqual(decoded.event, .toolCall(AgentToolCallEvent(
            id: "tool-1",
            name: "Edit",
            input: .object(["file_path": .string("README.md")])
        )))
    }

    func testAgentInputRoundTripsThroughJSON() throws {
        let input = AgentInput.userMessage(
            AgentMessageInput(
                text: "Implement it",
                metadata: ["priority": .string("normal")]
            )
        )

        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(AgentInput.self, from: data)

        XCTAssertEqual(decoded, input)
    }

    func testPathHelpersExpandTilde() {
        let home = URL(fileURLWithPath: "/Users/example")

        XCTAssertEqual(AgentPathHelpers.expandingTilde(in: "~", homeDirectory: home).path, "/Users/example")
        XCTAssertEqual(AgentPathHelpers.expandingTilde(in: "~/Project", homeDirectory: home).path, "/Users/example/Project")
        XCTAssertEqual(AgentPathHelpers.expandingTilde(in: "/tmp/Project", homeDirectory: home).path, "/tmp/Project")
    }

    private func removingMetadata(from value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(removingMetadata)
        }
        guard var dictionary = value as? [String: Any] else {
            return value
        }
        dictionary.removeValue(forKey: "metadata")
        for (key, child) in dictionary {
            dictionary[key] = removingMetadata(from: child)
        }
        return dictionary
    }
}

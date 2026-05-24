import XCTest

@testable import AgentCLIKit

final class AgentTranscriptTests: XCTestCase {
    func testDefaultPolicyGroupsAdjacentMessagesWithSameRole() {
        let envelopes = [
            envelope(index: 0, role: .assistant, text: "A"),
            envelope(index: 1, role: .assistant, text: "B"),
            envelope(index: 2, role: .user, text: "C")
        ]

        let entries = AgentTranscriptBuilder().build(from: envelopes)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].indexRange, 0...1)
        XCTAssertEqual(entries[0].text, "A\nB")
        XCTAssertEqual(entries[1].role, .user)
    }

    func testBuilderUsesInjectedPolicy() {
        let builder = AgentTranscriptBuilder(policy: NeverGroupingPolicy())
        let entries = builder.build(from: [
            envelope(index: 0, role: .assistant, text: "A"),
            envelope(index: 1, role: .assistant, text: "B")
        ])

        XCTAssertEqual(entries.count, 2)
    }

    func testDefaultPolicyDoesNotGroupAcrossGenerations() {
        let entries = AgentTranscriptBuilder().build(from: [
            envelope(generation: 2, index: 0, role: .assistant, text: "B"),
            envelope(generation: 1, index: 0, role: .assistant, text: "A")
        ])

        XCTAssertEqual(entries.map(\.text), ["A", "B"])
        XCTAssertEqual(entries.map(\.indexRange), [0...0, 0...0])
    }

    func testDefaultPolicyDoesNotGroupAcrossConversations() {
        let entries = AgentTranscriptBuilder().build(from: [
            envelope(index: 0, providerId: .claude, conversationId: "one", role: .assistant, text: "A"),
            envelope(index: 1, providerId: .claude, conversationId: "two", role: .assistant, text: "B"),
            envelope(index: 2, providerId: .claude, conversationId: "three", role: .assistant, text: "C")
        ])

        XCTAssertEqual(entries.map(\.text), ["A", "B", "C"])
        XCTAssertEqual(entries.map(\.indexRange), [0...0, 1...1, 2...2])
    }

    func testDefaultPolicyDoesNotGroupAcrossSkippedEventIndexes() {
        let entries = AgentTranscriptBuilder().build(from: [
            envelope(index: 0, role: .assistant, text: "A"),
            diagnosticEnvelope(index: 1),
            envelope(index: 2, role: .assistant, text: "B")
        ])

        XCTAssertEqual(entries.map(\.text), ["A", "B"])
        XCTAssertEqual(entries.map(\.indexRange), [0...0, 2...2])
    }

    private func envelope(index: Int, role: AgentMessageRole, text: String) -> AgentEventEnvelope {
        envelope(index: index, providerId: .claude, conversationId: "conversation", role: role, text: text)
    }

    private func envelope(generation: Int, index: Int, role: AgentMessageRole, text: String) -> AgentEventEnvelope {
        envelope(index: index, providerId: .claude, conversationId: "conversation", generation: generation, role: role, text: text)
    }

    private func envelope(
        index: Int,
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        generation: Int = 1,
        role: AgentMessageRole,
        text: String
    ) -> AgentEventEnvelope {
        AgentEventEnvelope(
            generation: generation,
            index: index,
            providerId: providerId,
            conversationId: conversationId,
            providerSessionId: nil,
            source: .stdout,
            event: .message(AgentMessageEvent(role: role, text: text)),
            createdAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }

    private func diagnosticEnvelope(index: Int) -> AgentEventEnvelope {
        AgentEventEnvelope(
            generation: 1,
            index: index,
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: nil,
            source: .stderr,
            event: .diagnostic(AgentDiagnosticEvent(severity: .info, message: "detail")),
            createdAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
}

private struct NeverGroupingPolicy: AgentTranscriptGroupingPolicy {
    func canGroup(_ current: AgentTranscriptEntry, with next: AgentEventEnvelope) -> Bool {
        false
    }

    func makeEntry(from envelope: AgentEventEnvelope) -> AgentTranscriptEntry? {
        guard case let .message(message) = envelope.event else {
            return nil
        }
        return AgentTranscriptEntry(indexRange: envelope.index...envelope.index, role: message.role, text: message.text, envelopes: [envelope])
    }

    func append(_ envelope: AgentEventEnvelope, to entry: AgentTranscriptEntry) -> AgentTranscriptEntry {
        entry
    }
}

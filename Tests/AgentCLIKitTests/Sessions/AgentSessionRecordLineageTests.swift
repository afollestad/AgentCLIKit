import XCTest

@testable import AgentCLIKit

/// Lineage bookkeeping for provider sessions a conversation replaced.
final class AgentSessionRecordLineageTests: XCTestCase {
    func testLineageIsEmptyWithoutMetadata() {
        XCTAssertEqual(record().supersededProviderSessionIds, [])
    }

    func testAppendPreservesOrderAndIgnoresDuplicates() {
        var metadata: [String: JSONValue] = ["source": .string("runtime")]
        for sessionId in ["one", "two", "one", "three"] {
            metadata = AgentSessionRecord.appendingSupersededProviderSessionId(
                AgentSessionID(rawValue: sessionId),
                to: metadata
            )
        }

        XCTAssertEqual(record(metadata: metadata).supersededProviderSessionIds, ["one", "two", "three"])
        XCTAssertEqual(metadata["source"], .string("runtime"))
    }

    func testAppendTrimsOldestBeyondRetentionLimit() {
        var metadata: [String: JSONValue] = [:]
        let total = AgentSessionRecord.supersededProviderSessionIdLimit + 5
        for index in 0..<total {
            metadata = AgentSessionRecord.appendingSupersededProviderSessionId(
                AgentSessionID(rawValue: "session-\(index)"),
                to: metadata
            )
        }
        let lineage = record(metadata: metadata).supersededProviderSessionIds

        XCTAssertEqual(lineage.count, AgentSessionRecord.supersededProviderSessionIdLimit)
        XCTAssertEqual(lineage.first, "session-5")
        XCTAssertEqual(lineage.last, AgentSessionID(rawValue: "session-\(total - 1)"))
    }

    func testLineageSkipsMalformedEntries() {
        let metadata: [String: JSONValue] = [
            AgentSessionRecord.supersededProviderSessionIdsMetadataKey: .array([
                .string("one"),
                .string(""),
                .number(7),
                .string("two")
            ])
        ]

        XCTAssertEqual(record(metadata: metadata).supersededProviderSessionIds, ["one", "two"])
    }

    func testRetargetingAimsAtOneSessionAndDropsItsLineage() {
        let metadata = AgentSessionRecord.appendingSupersededProviderSessionId("old", to: ["source": .string("runtime")])
        let retargeted = record(metadata: metadata).retargeted(to: "old")

        XCTAssertEqual(retargeted.providerSessionId, "old")
        XCTAssertEqual(retargeted.supersededProviderSessionIds, [])
        XCTAssertEqual(retargeted.conversationId, "conversation")
        XCTAssertEqual(retargeted.providerId, .codex)
        XCTAssertEqual(retargeted.metadata["source"], .string("runtime"))
    }

    private func record(metadata: [String: JSONValue] = [:]) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            providerId: .codex,
            providerSessionId: "current",
            generation: 1,
            metadata: metadata
        )
    }
}

import XCTest

@testable import AgentCLIKit

/// Lineage bookkeeping for harness sessions a conversation replaced.
final class AgentSessionRecordLineageTests: XCTestCase {
    func testLineageIsEmptyWithoutMetadata() {
        XCTAssertEqual(record().supersededHarnessSessionIds, [])
    }

    func testAppendPreservesOrderAndIgnoresDuplicates() {
        var metadata: [String: JSONValue] = ["source": .string("runtime")]
        for sessionId in ["one", "two", "one", "three"] {
            metadata = AgentSessionRecord.appendingSupersededHarnessSessionId(
                AgentSessionID(rawValue: sessionId),
                to: metadata
            )
        }

        XCTAssertEqual(record(metadata: metadata).supersededHarnessSessionIds, ["one", "two", "three"])
        XCTAssertEqual(metadata["source"], .string("runtime"))
    }

    func testAppendTrimsOldestBeyondRetentionLimit() {
        var metadata: [String: JSONValue] = [:]
        let total = AgentSessionRecord.supersededHarnessSessionIdLimit + 5
        for index in 0..<total {
            metadata = AgentSessionRecord.appendingSupersededHarnessSessionId(
                AgentSessionID(rawValue: "session-\(index)"),
                to: metadata
            )
        }
        let lineage = record(metadata: metadata).supersededHarnessSessionIds

        XCTAssertEqual(lineage.count, AgentSessionRecord.supersededHarnessSessionIdLimit)
        XCTAssertEqual(lineage.first, "session-5")
        XCTAssertEqual(lineage.last, AgentSessionID(rawValue: "session-\(total - 1)"))
    }

    func testLineageSkipsMalformedEntries() {
        let metadata: [String: JSONValue] = [
            AgentSessionRecord.supersededHarnessSessionIdsMetadataKey: .array([
                .string("one"),
                .string(""),
                .number(7),
                .string("two")
            ])
        ]

        XCTAssertEqual(record(metadata: metadata).supersededHarnessSessionIds, ["one", "two"])
    }

    func testRetargetingAimsAtOneSessionAndDropsItsLineage() {
        let metadata = AgentSessionRecord.appendingSupersededHarnessSessionId("old", to: ["source": .string("runtime")])
        let retargeted = record(metadata: metadata).retargeted(to: "old")

        XCTAssertEqual(retargeted.harnessSessionId, "old")
        XCTAssertEqual(retargeted.supersededHarnessSessionIds, [])
        XCTAssertEqual(retargeted.conversationId, "conversation")
        XCTAssertEqual(retargeted.harnessId, .codex)
        XCTAssertEqual(retargeted.metadata["source"], .string("runtime"))
    }

    private func record(metadata: [String: JSONValue] = [:]) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            harnessId: .codex,
            harnessSessionId: "current",
            generation: 1,
            metadata: metadata
        )
    }
}

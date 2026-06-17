import XCTest

@testable import AgentCLIKit

final class CodexSessionTranscriptPlanReaderTests: XCTestCase {
    func testFindsCompletedPlanInCodexSessionFile() throws {
        let codexHome = try temporaryDirectory()
        let ignoredResponseLine =
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[" +
            "{\"type\":\"output_text\",\"text\":\"<proposed_plan>ignored</proposed_plan>\"}]}}"
        let completedPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"thread-123\"," +
            "\"turn_id\":\"turn-1\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-1-plan\",\"text\":\"# Plan\\n\\n- Ship it\"}," +
            "\"completed_at_ms\":1781660055673}}"
        try writeSessionFile(
            codexHome: codexHome,
            threadId: "thread-123",
            contents: [ignoredResponseLine, completedPlanLine].joined(separator: "\n")
        )

        let plans = CodexSessionTranscriptPlanReader(codexHomeDirectory: codexHome).completedPlans(threadId: "thread-123")

        XCTAssertEqual(plans, [
            CodexSessionTranscriptPlan(
                itemId: "turn-1-plan",
                turnId: "turn-1",
                text: "# Plan\n\n- Ship it",
                completedAtMs: 1_781_660_055_673
            )
        ])
    }

    func testIgnoresOtherThreadsAndNonPlanCompletedItems() throws {
        let codexHome = try temporaryDirectory()
        let otherThreadPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"other-thread\"," +
            "\"turn_id\":\"turn-1\",\"item\":{\"type\":\"Plan\",\"id\":\"other-plan\",\"text\":\"# Other\"}}}"
        let agentMessageLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"thread-123\"," +
            "\"turn_id\":\"turn-1\",\"item\":{\"type\":\"agentMessage\",\"id\":\"message-1\",\"text\":\"Done\"}}}"
        let tokenCountLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1}}}}"
        try writeSessionFile(
            codexHome: codexHome,
            threadId: "thread-123",
            contents: [otherThreadPlanLine, agentMessageLine, tokenCountLine].joined(separator: "\n")
        )

        let plans = CodexSessionTranscriptPlanReader(codexHomeDirectory: codexHome).completedPlans(threadId: "thread-123")

        XCTAssertTrue(plans.isEmpty)
    }

    func testPreservesSameItemIdPlanRevisionsWithDifferentText() throws {
        let codexHome = try temporaryDirectory()
        let firstPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"thread-123\"," +
            "\"turn_id\":\"turn-1\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-1-plan\",\"text\":\"# First Plan\"}}}"
        let duplicateFirstPlanLine = firstPlanLine
        let revisedPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"thread-123\"," +
            "\"turn_id\":\"turn-1\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-1-plan\",\"text\":\"# Revised Plan\"}}}"
        try writeSessionFile(
            codexHome: codexHome,
            threadId: "thread-123",
            contents: [firstPlanLine, duplicateFirstPlanLine, revisedPlanLine].joined(separator: "\n")
        )

        let plans = CodexSessionTranscriptPlanReader(codexHomeDirectory: codexHome).completedPlans(threadId: "thread-123")

        XCTAssertEqual(plans, [
            CodexSessionTranscriptPlan(
                itemId: "turn-1-plan",
                turnId: "turn-1",
                text: "# First Plan",
                completedAtMs: nil
            ),
            CodexSessionTranscriptPlan(
                itemId: "turn-1-plan",
                turnId: "turn-1",
                text: "# Revised Plan",
                completedAtMs: nil
            )
        ])
    }

    private func writeSessionFile(codexHome: URL, threadId: String, contents: String) throws {
        let sessionsDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("16", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let fileURL = sessionsDirectory.appendingPathComponent("rollout-2026-06-16T20-33-05-\(threadId).jsonl")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

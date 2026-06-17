import Foundation
import XCTest

@testable import AgentCLIKit

extension CodexProviderAdapterRuntimeTests {
    func testRuntimeEventsRecoverSameItemIdPlanRevisionFromCodexSessionTranscript() async throws {
        let codexHome = try temporaryDirectory()
        try writeCodexSessionPlanRevisions(codexHome: codexHome, threadId: "thread-123")
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport, codexHomeDirectory: codexHome))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        async let collectedEvents = Self.collect(stream, count: 4)

        await transport.emitNotification(method: "thread/tokenUsage/updated", params: tokenUsageParams())
        await transport.emitNotification(method: "thread/tokenUsage/updated", params: tokenUsageParams())

        let events = await collectedEvents.map(\.event)
        let messages = events.compactMap { event -> AgentMessageEvent? in
            guard case let .message(message) = event else {
                return nil
            }
            return message
        }
        let usageEvents = events.compactMap { event -> AgentUsageEvent? in
            guard case let .usage(usage) = event else {
                return nil
            }
            return usage
        }

        XCTAssertEqual(messages.map(\.text), [Self.recoveredPlanMarkdown, Self.revisedRecoveredPlanMarkdown])
        XCTAssertEqual(messages.map { $0.metadata[AgentPlanProposalMetadata.proposalId] }, [
            .string("turn-1-plan"),
            .string("turn-1-plan")
        ])
        XCTAssertEqual(messages.map { $0.metadata[AgentPlanProposalMetadata.planMarkdown] }, [
            .string(Self.recoveredPlanMarkdown),
            .string(Self.revisedRecoveredPlanMarkdown)
        ])
        XCTAssertEqual(usageEvents.count, 2)
    }

    func testRuntimeEventsDoNotRecoverLiveForwardedPlanDuplicateBeforeRevision() async throws {
        let codexHome = try temporaryDirectory()
        try writeCodexSessionPlanRevisions(codexHome: codexHome, threadId: "thread-123")
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport, codexHomeDirectory: codexHome))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        async let collectedEvents = Self.collect(stream, count: 3)

        await transport.emitNotification(method: "item_completed", params: .object([
            "thread_id": .string("thread-123"),
            "turn_id": .string("turn-1"),
            "item": .object([
                "id": .string("turn-1-plan"),
                "type": .string("Plan"),
                "text": .string(Self.recoveredPlanMarkdown)
            ])
        ]))
        await transport.emitNotification(method: "thread/tokenUsage/updated", params: tokenUsageParams())

        let events = await collectedEvents.map(\.event)
        let messages = events.compactMap { event -> AgentMessageEvent? in
            guard case let .message(message) = event else {
                return nil
            }
            return message
        }
        let usageEvents = events.compactMap { event -> AgentUsageEvent? in
            guard case let .usage(usage) = event else {
                return nil
            }
            return usage
        }

        XCTAssertEqual(messages.map(\.text), [Self.recoveredPlanMarkdown, Self.revisedRecoveredPlanMarkdown])
        XCTAssertEqual(usageEvents.count, 1)
    }

    private func writeCodexSessionPlanRevisions(codexHome: URL, threadId: String) throws {
        let sessionsDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("16", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let fileURL = sessionsDirectory.appendingPathComponent("rollout-2026-06-16T20-33-05-\(threadId).jsonl")
        let firstPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"" + threadId +
            "\",\"turn_id\":\"turn-1\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-1-plan\",\"text\":\"" +
            Self.escapedRecoveredPlanMarkdown + "\"},\"completed_at_ms\":1781660055673}}"
        let duplicateFirstPlanLine = firstPlanLine
        let revisedPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"" + threadId +
            "\",\"turn_id\":\"turn-1\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-1-plan\",\"text\":\"" +
            Self.escapedRevisedRecoveredPlanMarkdown + "\"},\"completed_at_ms\":1781660056673}}"
        try [firstPlanLine, duplicateFirstPlanLine, revisedPlanLine]
            .joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static let recoveredPlanMarkdown = "# UX Polish Pass\n\n- Tighten the hero.\n- Verify the gallery."
    private static let revisedRecoveredPlanMarkdown = "# Experience Section Refresh\n\n- Use the answered prompt choices."
    private static let escapedRecoveredPlanMarkdown = "# UX Polish Pass\\n\\n- Tighten the hero.\\n- Verify the gallery."
    private static let escapedRevisedRecoveredPlanMarkdown = "# Experience Section Refresh\\n\\n- Use the answered prompt choices."
}

import XCTest

@testable import AgentCLIKit

extension ClaudeProviderAdapterTests {
    func testStdoutCompactionFramesShareStableProcessScopedId() async throws {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))
        let processToken = UUID()
        let context = AgentProviderOutputContext(
            conversationId: "conversation",
            processToken: processToken,
            providerSessionId: nil,
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp"))
        )

        let started = try await adapter.decodeStdoutLine(#"""
        {"type":"system","status":"compacting","session_id":"session-123","compact_metadata":{"trigger":"auto"}}
        """#, context: context)
        let completed = try await adapter.decodeStdoutLine(#"""
        {"type":"system","subtype":"compact_boundary","session_id":"session-123","compact_result":"success","compact_metadata":{"trigger":"auto"}}
        """#, context: context)

        XCTAssertEqual(started, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "claude-context-compaction-session-123-1",
                phase: .started,
                trigger: "auto",
                metadata: [
                    "session_id": .string("session-123"),
                    "status": .string("compacting"),
                    "trigger": .string("auto")
                ]
            ))
        ])
        XCTAssertEqual(completed, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "claude-context-compaction-session-123-1",
                phase: .completed,
                trigger: "auto",
                metadata: [
                    "session_id": .string("session-123"),
                    "compact_result": .string("success"),
                    "subtype": .string("compact_boundary"),
                    "trigger": .string("auto")
                ]
            ))
        ])
    }

    func testStdoutDelayedCompactionStartReusesTerminalId() async throws {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))
        let context = AgentProviderOutputContext(
            conversationId: "conversation",
            processToken: UUID(),
            providerSessionId: nil,
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp"))
        )

        let completed = try await adapter.decodeStdoutLine(#"""
        {"type":"system","subtype":"compact_boundary","session_id":"session-123","compact_result":"success"}
        """#, context: context)
        let delayedStart = try await adapter.decodeStdoutLine(#"""
        {"type":"system","status":"compacting","session_id":"session-123"}
        """#, context: context)
        let compactions = (completed + delayedStart).compactMap { event -> AgentContextCompactionEvent? in
            guard case let .contextCompaction(compaction) = event else {
                return nil
            }
            return compaction
        }

        XCTAssertEqual(compactions.map(\.id), [
            "claude-context-compaction-session-123-1",
            "claude-context-compaction-session-123-1"
        ])
        XCTAssertEqual(compactions.map(\.phase), [.completed, .started])
    }
}

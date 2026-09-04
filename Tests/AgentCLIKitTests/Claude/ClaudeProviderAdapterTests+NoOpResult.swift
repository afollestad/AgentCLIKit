import XCTest

@testable import AgentCLIKit

/// The no-op result tracker downgrades Claude's zero-usage `result` frames only after task-notification traffic.
extension ClaudeProviderAdapterTests {
    func testNoOpResultAfterTaskNotificationBecomesInterimUsage() async throws {
        let adapter = Self.hooklessAdapter()
        let context = Self.outputContext()

        _ = try await adapter.decodeStdoutLine(Self.systemTaskNotificationLine, context: context)
        let events = try await adapter.decodeStdoutLine(Self.noOpResultLine, context: context)

        guard case let .usage(usage)? = events.first, events.count == 1 else {
            return XCTFail("Expected a single usage event, got \(events)")
        }
        XCTAssertFalse(usage.isTerminal)
        XCTAssertEqual(usage.stopReason, AgentUsageEvent.interimUsageStopReason)
        XCTAssertEqual(usage.metadata[AgentBackgroundTaskMetadata.noOpResult], .bool(true))
        XCTAssertFalse(usage.endsActiveTurn)
    }

    func testNoOpResultWithoutTaskNotificationStaysTerminal() async throws {
        let adapter = Self.hooklessAdapter()

        let events = try await adapter.decodeStdoutLine(Self.noOpResultLine, context: Self.outputContext())

        guard case let .usage(usage)? = events.first else {
            return XCTFail("Expected a usage event, got \(events)")
        }
        XCTAssertTrue(usage.isTerminal)
        XCTAssertNil(usage.stopReason)
        XCTAssertNil(usage.metadata[AgentBackgroundTaskMetadata.noOpResult])
    }

    func testSyntheticNoResponseRequestedMessageIsDroppedAndArmsTracker() async throws {
        let adapter = Self.hooklessAdapter()
        let context = Self.outputContext()

        let messageEvents = try await adapter.decodeStdoutLine(#"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"No response requested."}],
        "usage":{"input_tokens":0,"output_tokens":0}}}
        """#.replacingOccurrences(of: "\n", with: ""), context: context)
        let resultEvents = try await adapter.decodeStdoutLine(Self.noOpResultLine, context: context)

        XCTAssertFalse(messageEvents.contains { if case .message = $0 { true } else { false } })
        guard case let .usage(usage)? = resultEvents.first else {
            return XCTFail("Expected a usage event, got \(resultEvents)")
        }
        XCTAssertFalse(usage.isTerminal)
    }

    func testAssistantContentAfterTaskNotificationDisarmsTracker() async throws {
        let adapter = Self.hooklessAdapter()
        let context = Self.outputContext()

        _ = try await adapter.decodeStdoutLine(Self.systemTaskNotificationLine, context: context)
        _ = try await adapter.decodeStdoutLine(#"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"notified"}]}}
        """#, context: context)
        let events = try await adapter.decodeStdoutLine(Self.noOpResultLine, context: context)

        guard case let .usage(usage)? = events.first else {
            return XCTFail("Expected a usage event, got \(events)")
        }
        XCTAssertTrue(usage.isTerminal)
    }

    func testRealResultAfterTaskNotificationStaysTerminalAndDisarms() async throws {
        let adapter = Self.hooklessAdapter()
        let context = Self.outputContext()

        _ = try await adapter.decodeStdoutLine(Self.systemTaskNotificationLine, context: context)
        let real = try await adapter.decodeStdoutLine(#"""
        {"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":76}}
        """#, context: context)
        let later = try await adapter.decodeStdoutLine(Self.noOpResultLine, context: context)

        guard case let .usage(realUsage)? = real.first, case let .usage(laterUsage)? = later.first else {
            return XCTFail("Expected usage events, got \(real) and \(later)")
        }
        XCTAssertTrue(realUsage.isTerminal)
        XCTAssertTrue(laterUsage.isTerminal)
    }

    func testProcessTerminationResetsTrackerArming() async throws {
        let adapter = Self.hooklessAdapter()
        let context = Self.outputContext()

        _ = try await adapter.decodeStdoutLine(Self.systemTaskNotificationLine, context: context)
        await adapter.processDidTerminate(processToken: context.processToken)
        let events = try await adapter.decodeStdoutLine(Self.noOpResultLine, context: context)

        guard case let .usage(usage)? = events.first else {
            return XCTFail("Expected a usage event, got \(events)")
        }
        XCTAssertTrue(usage.isTerminal)
    }

    private static func hooklessAdapter() -> ClaudeProviderAdapter {
        ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))
    }

    private static func outputContext() -> AgentProviderOutputContext {
        AgentProviderOutputContext(
            conversationId: "conversation",
            processToken: UUID(),
            providerSessionId: nil,
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp"))
        )
    }

    private static let systemTaskNotificationLine = #"""
    {"type":"system","subtype":"task_notification","task_id":"a0d2815","tool_use_id":"toolu_agent","status":"completed","summary":"done"}
    """#

    private static let noOpResultLine = #"""
    {"type":"result","subtype":"success","is_error":false,"duration_ms":3,"num_turns":1,
    "usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
    """#.replacingOccurrences(of: "\n", with: "")
}

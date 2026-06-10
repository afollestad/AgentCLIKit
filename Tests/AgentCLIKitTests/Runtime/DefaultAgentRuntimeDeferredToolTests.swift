import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeDeferredToolTests: XCTestCase {
    func testDeferredApprovalResumeSuppressesReplayedProviderEvents() async throws {
        let launches = LaunchSequence([
            shell("printf 'message:history\\napproval:tool-1\\ndeferred\\n'"),
            shell("printf 'message:history\\napproval:tool-1\\ndeferred\\nmessage:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "new"))
            }
        })

        XCTAssertFalse(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "history")) })
        XCTAssertFalse(events.contains { $0.event == .interaction(AgentInteractionEvent(id: "tool-1", kind: .approval, prompt: "Bash")) })
        XCTAssertFalse(events.contains { $0.event == .usage(Self.deferredUsage) })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
        let finalStatus = await runtime.status(conversationId: conversationId)
        XCTAssertEqual(finalStatus?.waitingState, .idle)
    }

    func testDeferredApprovalResumeSuppressesReplayWithVolatileMetadata() async throws {
        let launches = LaunchSequence([
            shell("printf 'approval-volatile:first\\n'"),
            shell("printf 'approval-volatile:second\\nmessage:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "new"))
            }
        })

        XCTAssertFalse(events.contains { envelope in
            if case .interaction = envelope.event {
                return true
            }
            return false
        })
        XCTAssertFalse(events.contains { $0.event == .usage(Self.deferredUsageWithVolatileMetadata("second")) })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testDeferredApprovalResumeSuppressesReplayedProviderSuffix() async throws {
        let launches = LaunchSequence([
            shell("printf 'message:intro\\ntool:glob\\nresult:glob\\ntool:grep\\nresult:grep\\napproval:tool-1\\ndeferred\\n'"),
            shell("printf 'tool:glob\\nresult:glob\\ntool:grep\\nresult:grep\\nmessage:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "new"))
            }
        })

        XCTAssertFalse(events.contains { envelope in
            if case .toolCall = envelope.event {
                return true
            }
            return false
        })
        XCTAssertFalse(events.contains { envelope in
            if case .toolResult = envelope.event {
                return true
            }
            return false
        })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testDeferredApprovalResumeSuppressesCompletedMessagesReplayedFromPriorDeltas() async throws {
        let launches = LaunchSequence([
            shell("printf 'delta:Running 4 tools in parallel now.\\ntool:glob\\nresult:glob\\napproval:tool-1\\ndeferred\\n'"),
            shell("printf 'message:Running 4 tools in parallel now.\\ntool:glob\\nresult:glob\\nmessage:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "new"))
            }
        })

        XCTAssertFalse(events.contains { envelope in
            envelope.event == .message(AgentMessageEvent(role: .assistant, text: "Running 4 tools in parallel now."))
        })
        XCTAssertFalse(events.contains { envelope in
            if case .toolCall = envelope.event {
                return true
            }
            return false
        })
        XCTAssertFalse(events.contains { envelope in
            if case .toolResult = envelope.event {
                return true
            }
            return false
        })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testDeferredApprovalResumeSuppressesReplayedToolsWithFreshIDs() async throws {
        let launches = LaunchSequence([
            shell("printf 'tool-call:glob-old:Glob:**/*.html\\ntool-result:glob-old:index.html\\napproval:tool-1\\ndeferred\\n'"),
            shell("printf 'tool-call:glob-new:Glob:**/*.html\\ntool-result:glob-new:index.html\\nmessage:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "new"))
            }
        })

        XCTAssertFalse(events.contains { envelope in
            if case .toolCall = envelope.event {
                return true
            }
            return false
        })
        XCTAssertFalse(events.contains { envelope in
            if case .toolResult = envelope.event {
                return true
            }
            return false
        })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testDeferredApprovalResumeKeepsMatchingContentAfterNewOutputStarts() async throws {
        let launches = LaunchSequence([
            shell("printf 'message:history\\napproval:tool-1\\ndeferred\\n'"),
            shell("printf 'message:history\\nmessage:new\\nmessage:history\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.filter { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "history"))
            }.count == 1
        })

        XCTAssertEqual(events.filter { $0.event == .message(AgentMessageEvent(role: .assistant, text: "history")) }.count, 1)
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testFreshSessionDoesNotSuppressProviderEventsAfterDeferredApprovalStop() async throws {
        let launches = LaunchSequence([
            shell("printf 'message:history\\napproval:tool-1\\ndeferred\\n'"),
            shell("printf 'message:history\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.freshSession(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.generation == 2 && envelope.event == .message(AgentMessageEvent(role: .assistant, text: "history"))
            }
        })

        XCTAssertTrue(events.contains { envelope in
            envelope.generation == 2 && envelope.event == .message(AgentMessageEvent(role: .assistant, text: "history"))
        })
    }

    func testNonDeferredResumeDoesNotSuppressMatchingProviderEvents() async throws {
        let launches = LaunchSequence([
            shell("printf 'message:history\\n'"),
            shell("printf 'message:history\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "history"))
            }
        })

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "history")) })
    }

    func testDeferredApprovalResumeSuppressesParallelReplayedApprovals() async throws {
        let launches = LaunchSequence([
            shell("printf 'approval:tool-1\\napproval:tool-2\\ndeferred\\n'"),
            shell("printf 'approval:tool-1\\napproval:tool-2\\ndeferred\\nmessage:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "new"))
            }
        })

        let approvalEvents = events.compactMap { envelope -> AgentInteractionEvent? in
            guard case let .interaction(interaction) = envelope.event else {
                return nil
            }
            return interaction
        }
        XCTAssertTrue(approvalEvents.isEmpty)
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testRuntimePreservesWaitingStateAfterDeferredApprovalProcessExits() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredToolStopProviderAdapter(command: shell("printf 'approval\\ndeferred\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .exited)
        XCTAssertEqual(status?.waitingState, .approval)
        XCTAssertEqual(status?.inputAvailability, .blocked(reason: "Waiting for approval."))
        XCTAssertFalse(status?.isProcessRunning ?? true)
    }

    func testRuntimeIgnoresStdoutAfterDeferredToolStopPerConversation() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredToolStopProviderAdapter(command: shell("printf 'deferred\\nmessage:trailing\\n'"))
        ])
        let firstConversationId: AgentConversationID = "first"
        let secondConversationId: AgentConversationID = "second"

        try await runtime.spawn(conversationId: firstConversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: firstConversationId)
        let firstReplay = await runtime.subscribe(conversationId: firstConversationId, afterIndex: nil)
        let firstEvents = await Self.collect(firstReplay.events, limit: (firstStatus?.lastEventIndex ?? -1) + 1)

        try await runtime.spawn(conversationId: secondConversationId, config: spawnConfig())
        let secondStatus = await waitForExit(runtime: runtime, conversationId: secondConversationId)
        let secondReplay = await runtime.subscribe(conversationId: secondConversationId, afterIndex: nil)
        let secondEvents = await Self.collect(secondReplay.events, limit: (secondStatus?.lastEventIndex ?? -1) + 1)

        let deferredUsage = AgentUsageEvent(model: nil, inputTokens: nil, outputTokens: nil, stopReason: "tool_deferred")
        let trailingMessage = AgentMessageEvent(role: .assistant, text: "trailing")

        XCTAssertTrue(firstEvents.contains { $0.event == .usage(deferredUsage) })
        XCTAssertFalse(firstEvents.contains { $0.event == .message(trailingMessage) })
        XCTAssertTrue(secondEvents.contains { $0.event == .usage(deferredUsage) })
        XCTAssertFalse(secondEvents.contains { $0.event == .message(trailingMessage) })
    }

    fileprivate static let deferredUsage = AgentUsageEvent(model: nil, inputTokens: nil, outputTokens: nil, stopReason: "tool_deferred")

    fileprivate static func deferredUsageWithVolatileMetadata(_ marker: String) -> AgentUsageEvent {
        AgentUsageEvent(
            model: "claude",
            inputTokens: marker == "first" ? 10 : 11,
            outputTokens: marker == "first" ? 1 : 2,
            durationMs: marker == "first" ? 100 : 200,
            stopReason: "tool_deferred",
            metadata: [
                "stop_reason": .string("tool_deferred"),
                "raw_event": .string(marker)
            ]
        )
    }

}

private struct DeferredReplayProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let launchSequence: LaunchSequence

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await launchSequence.next()
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if let events = decodedMessageEvent(from: line) ??
            decodedToolCallEvent(from: line) ??
            decodedToolResultEvent(from: line) ??
            decodedApprovalEvent(from: line) {
            return events
        }
        if line == "deferred" {
            return [.usage(DefaultAgentRuntimeDeferredToolTests.deferredUsage)]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    private func decodedMessageEvent(from line: String) -> [AgentEvent]? {
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        if let text = line.removingPrefix("delta:") {
            return [.messageDelta(AgentMessageDeltaEvent(role: .assistant, text: text))]
        }
        return nil
    }

    private func decodedToolCallEvent(from line: String) -> [AgentEvent]? {
        if let rawTool = line.removingPrefix("tool-call:") {
            let components = rawTool.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count == 3 else {
                return []
            }
            return [.toolCall(AgentToolCallEvent(
                id: components[0],
                name: components[1],
                input: .object(["pattern": .string(components[2])])
            ))]
        }
        if let toolId = line.removingPrefix("tool:") {
            return [.toolCall(AgentToolCallEvent(
                id: toolId,
                name: toolId == "glob" ? "Glob" : "Grep",
                input: .object(["pattern": .string(toolId == "glob" ? "**/*.html" : "TODO|FIXME|HACK")])
            ))]
        }
        return nil
    }

    private func decodedToolResultEvent(from line: String) -> [AgentEvent]? {
        if let rawResult = line.removingPrefix("tool-result:") {
            let components = rawResult.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2 else {
                return []
            }
            return [.toolResult(AgentToolResultEvent(id: components[0], isError: false, content: components[1]))]
        }
        if let toolId = line.removingPrefix("result:") {
            return [.toolResult(AgentToolResultEvent(id: toolId, isError: false, content: "ok"))]
        }
        return nil
    }

    private func decodedApprovalEvent(from line: String) -> [AgentEvent]? {
        if let toolId = line.removingPrefix("approval:") {
            return [.interaction(AgentInteractionEvent(id: AgentInteractionID(rawValue: toolId), kind: .approval, prompt: "Bash"))]
        }
        if let marker = line.removingPrefix("approval-volatile:") {
            return [
                .interaction(AgentInteractionEvent(
                    id: "tool-1",
                    kind: .approval,
                    prompt: "Bash",
                    metadata: [
                        "session_id": .string("session-1"),
                        "tool_name": .string("Bash"),
                        "tool_input": .object(["command": .string("pwd")]),
                        "raw_event": .string(marker)
                    ]
                )),
                .usage(DefaultAgentRuntimeDeferredToolTests.deferredUsageWithVolatileMetadata(marker))
            ]
        }
        return nil
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }
        return String(dropFirst(prefix.count))
    }
}

import XCTest

@testable import AgentCLIKit

extension ClaudeHookTests {
    func testHookSettingsCanRegisterCompactHooksWithoutPreToolUse() throws {
        let preToolURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/claude/hooks/pre-tool-use"))
        let preCompactURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/claude/hooks/pre-compact"))
        let postCompactURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/claude/hooks/post-compact"))
        let settings = ClaudeHookSettings(
            endpointURL: preToolURL,
            includePreToolUse: false,
            preCompactEndpointURL: preCompactURL,
            postCompactEndpointURL: postCompactURL
        )

        let data = try settings.encodedData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let preCompact = try XCTUnwrap((hooks["PreCompact"] as? [[String: Any]])?.first)
        let postCompact = try XCTUnwrap((hooks["PostCompact"] as? [[String: Any]])?.first)
        let preTransport = try XCTUnwrap((preCompact["hooks"] as? [[String: Any]])?.first)
        let postTransport = try XCTUnwrap((postCompact["hooks"] as? [[String: Any]])?.first)

        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertEqual(preCompact["matcher"] as? String, ClaudeHookPolicy.compactMatcher)
        XCTAssertEqual(postCompact["matcher"] as? String, ClaudeHookPolicy.compactMatcher)
        XCTAssertEqual(preTransport["url"] as? String, preCompactURL.absoluteString)
        XCTAssertEqual(postTransport["url"] as? String, postCompactURL.absoluteString)
    }

    // swiftlint:disable:next function_body_length
    func testCompactHooksReturnContinueAndEmitRuntimeEvents() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let token = await tokenStore.issue(validFor: 60)
        let processToken = UUID()
        let stream = AsyncStream<AgentProviderRuntimeEvent>.makeStream()
        let accumulator = RuntimeEventAccumulator()
        let collector = Task {
            for await event in stream.stream {
                await accumulator.append(event)
                if await accumulator.count == 2 {
                    break
                }
            }
        }
        await server.registerCompactHooks(processToken: processToken, token: token.value)
        await server.registerCompactRuntimeEvents(processToken: processToken, continuation: stream.continuation)

        let invalid = await server.handle(ClaudeHookRequest(
            bearerToken: "bad",
            hookName: "PreCompact",
            conversationId: "conversation",
            payload: .object([:]),
            processToken: processToken
        ))
        let started = await server.handle(ClaudeHookRequest(
            bearerToken: token.value,
            hookName: "PreCompact",
            conversationId: "conversation",
            payload: .object([
                "trigger": .string("auto"),
                "session_id": .string("session-123")
            ]),
            processToken: processToken
        ))
        let completed = await server.handle(ClaudeHookRequest(
            bearerToken: token.value,
            hookName: "PostCompact",
            conversationId: "conversation",
            payload: .object([
                "trigger": .string("auto"),
                "session_id": .string("session-123"),
                "compact_summary": .string("Retained recent context.")
            ]),
            processToken: processToken
        ))
        try? await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()
        await server.unregisterCompactRuntimeEvents(processToken: processToken)
        let events = await accumulator.events

        XCTAssertEqual(invalid, .continueProcessing)
        XCTAssertEqual(started, .continueProcessing)
        XCTAssertEqual(completed, .continueProcessing)
        XCTAssertEqual(events.map(\.source), [.hook, .hook])
        XCTAssertEqual(events.map(\.event), [
            .contextCompaction(AgentContextCompactionEvent(
                id: "claude-context-compaction-session-123-1",
                phase: .started,
                trigger: "auto",
                metadata: [
                    "conversation_id": .string("conversation"),
                    "process_token": .string(processToken.uuidString),
                    "claude_hook_name": .string("PreCompact"),
                    "session_id": .string("session-123"),
                    "trigger": .string("auto")
                ]
            )),
            .contextCompaction(AgentContextCompactionEvent(
                id: "claude-context-compaction-session-123-1",
                phase: .completed,
                trigger: "auto",
                summary: "Retained recent context.",
                metadata: [
                    "conversation_id": .string("conversation"),
                    "process_token": .string(processToken.uuidString),
                    "claude_hook_name": .string("PostCompact"),
                    "session_id": .string("session-123"),
                    "trigger": .string("auto"),
                    "compact_summary": .string("Retained recent context.")
                ]
            ))
        ])
    }

    // swiftlint:disable:next function_body_length
    func testPostCompactHookCanEmitFailedEvent() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let token = await tokenStore.issue(validFor: 60)
        let processToken = UUID()
        let stream = AsyncStream<AgentProviderRuntimeEvent>.makeStream()
        let accumulator = RuntimeEventAccumulator()
        let collector = Task {
            for await event in stream.stream {
                await accumulator.append(event)
                break
            }
        }
        await server.registerCompactHooks(processToken: processToken, token: token.value)
        await server.registerCompactRuntimeEvents(processToken: processToken, continuation: stream.continuation)

        let response = await server.handle(ClaudeHookRequest(
            bearerToken: token.value,
            hookName: "PostCompact",
            conversationId: "conversation",
            payload: .object([
                "trigger": .string("manual"),
                "session_id": .string("session-123"),
                "compact_result": .string("failed"),
                "compact_error": .string("Provider reported a compact failure."),
                "compactMetadata": .object([
                    "preTokens": .number(100_000)
                ])
            ]),
            processToken: processToken
        ))
        try? await Task.sleep(nanoseconds: 20_000_000)
        collector.cancel()
        await server.unregisterCompactRuntimeEvents(processToken: processToken)
        let events = await accumulator.events

        XCTAssertEqual(response, .continueProcessing)
        XCTAssertEqual(events.map(\.event), [
            .contextCompaction(AgentContextCompactionEvent(
                id: "claude-context-compaction-session-123-1",
                phase: .failed,
                trigger: "manual",
                errorMessage: "Provider reported a compact failure.",
                preTokens: 100_000,
                metadata: [
                    "conversation_id": .string("conversation"),
                    "process_token": .string(processToken.uuidString),
                    "claude_hook_name": .string("PostCompact"),
                    "session_id": .string("session-123"),
                    "trigger": .string("manual"),
                    "compact_result": .string("failed"),
                    "compact_error": .string("Provider reported a compact failure."),
                    "pre_tokens": .number(100_000)
                ]
            ))
        ])
    }
}

private actor RuntimeEventAccumulator {
    private(set) var events: [AgentProviderRuntimeEvent] = []

    var count: Int {
        events.count
    }

    func append(_ event: AgentProviderRuntimeEvent) {
        events.append(event)
    }
}

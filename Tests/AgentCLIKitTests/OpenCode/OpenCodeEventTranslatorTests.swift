import XCTest

@testable import AgentCLIKit

final class OpenCodeEventTranslatorTests: XCTestCase {
    func testSessionUpdatesSuppressOnlyExactNativePlaceholderTitles() throws {
        let titles: [(String, String?)] = [
            ("New session - 2026-09-16T00:07:08.123Z", nil),
            ("Child session - 2026-09-16T00:07:08.123Z", nil),
            ("Fix task title discovery", "Fix task title discovery"),
            ("New session - planning", "New session - planning"),
            ("New session - 2026-09-16T00:07:08.123Z (fork #1)", "New session - 2026-09-16T00:07:08.123Z (fork #1)")
        ]
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        for (title, expected) in titles {
            let update = event("session.updated", ["info": .object(["id": .string("ses_root"), "title": .string(title)])])
            let events = translator.translate(update)
            guard case let .sessionMetadata(metadata)? = events.first else { return XCTFail("Missing session identity") }
            XCTAssertEqual(metadata.harnessSessionId, "ses_root")
            XCTAssertEqual(metadata.name, expected)
            XCTAssertTrue(translator.translate(update).isEmpty)
        }
    }

    func testPinnedLiveV11831RecordingPreservesNativeConversationSemantics() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "live-v1.18.31", withExtension: "json"))
        let recording = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let root = try XCTUnwrap(recording.openCodeValue("responses").openCodeValue("created").openCodeValue("id").openCodeString)
        let stream = try XCTUnwrap(recording.openCodeValue("events").openCodeArray)
        var translator = OpenCodeEventTranslator(rootSessionID: root)
        let events = stream.flatMap { translator.translate($0) }
        let assistant = events.compactMap { event -> String? in
            guard case let .message(message) = event, message.role == .assistant else { return nil }
            return message.text
        }
        XCTAssertEqual(assistant, [
            "Fixture text complete.", "Fixture question complete.", "Fixture permission complete.",
            "Fixture steer complete.", "Fixture followup complete."
        ])
        let compacted = events.compactMap { event -> AgentContextCompactionPhase? in
            guard case let .contextCompaction(value) = event else { return nil }
            return value.phase
        }
        XCTAssertEqual(compacted, [.started, .completed])
        XCTAssertTrue(stream.flatMap { translator.translate($0) }.isEmpty)
    }

    func testNativeV1StreamDeduplicatesEventsAndCompletedSnapshot() throws {
        let stream = try fixture()
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        var events: [AgentEvent] = []
        for event in stream {
            events += translator.translate(event)
            XCTAssertTrue(translator.translate(event).isEmpty)
        }
        XCTAssertEqual(deltas(events), ["Hello"])
        XCTAssertEqual(messages(events), ["Hello"])
        let snapshot = snapshotMessage(info: info(), parts: [textPart("Hello", complete: true)])
        XCTAssertTrue(translator.reconcile(messages: [snapshot]).isEmpty)
    }

    func testMissingLiveFinalIsRecoveredOnceByReconciliation() {
        var translator = prepared()
        XCTAssertEqual(deltas(translator.translate(delta("Hello"))), ["Hello"])
        let snapshot = snapshotMessage(info: info(), parts: [textPart("Hello world", complete: true)])
        XCTAssertEqual(messages(translator.reconcile(messages: [snapshot])), ["Hello world"])
        XCTAssertTrue(translator.reconcile(messages: [snapshot]).isEmpty)
        XCTAssertTrue(translator.translate(delta(" world")).isEmpty)
    }

    func testSnapshotOverlapDoesNotAppendBufferedDeltaTwice() {
        var translator = prepared()
        let snapshot = snapshotMessage(info: info(), parts: [textPart("Hello")])
        XCTAssertEqual(deltas(translator.reconcile(messages: [snapshot])), ["Hello"])
        XCTAssertTrue(translator.translate(delta("Hello")).isEmpty)
        XCTAssertEqual(messages(translator.translate(partEvent(textPart("Hello world", complete: true)))), ["Hello world"])
    }

    func testStaleSnapshotDoesNotRollBackStreamedText() {
        var translator = prepared()
        _ = translator.translate(delta("Hello world"))
        XCTAssertTrue(translator.reconcile(messages: [snapshotMessage(info: info(), parts: [textPart("Hello")])]).isEmpty)
        XCTAssertEqual(messages(translator.translate(partEvent(textPart("Hello world!", complete: true)))), ["Hello world!"])
    }

    func testSeedSuppressesHistoryButAllowsNewMessage() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let snapshot = snapshotMessage(info: info(complete: true), parts: [textPart("Old", complete: true)])
        translator.seed(messages: [snapshot])
        XCTAssertTrue(translator.reconcile(messages: [snapshot]).isEmpty)
        let next = info(messageID: "msg_next")
        _ = translator.translate(event("message.updated", ["info": next]))
        let part = textPart("New", complete: true).openCodeSetting("messageID", .string("msg_next"))
        XCTAssertEqual(messages(translator.translate(partEvent(part))), ["New"])
    }

    func testPartBeforeMessageInfoIsBufferedRatherThanMisclassified() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        XCTAssertTrue(translator.translate(partEvent(textPart("Hello", complete: true))).isEmpty)
        XCTAssertEqual(messages(translator.translate(event("message.updated", ["info": info()]))), ["Hello"])
    }

    func testReasoningUsesSuffixesAndSeparatesPartsWithoutRepeatingFinalText() {
        var translator = prepared(part: textPart("", type: "reasoning"))
        XCTAssertEqual(reasoning(translator.translate(delta("Thinking"))), ["Thinking"])
        XCTAssertTrue(translator.translate(partEvent(textPart("Thinking", type: "reasoning", complete: true))).isEmpty)
        let next = textPart("Another thought", type: "reasoning", complete: true).openCodeSetting("id", .string("prt_second"))
        XCTAssertEqual(reasoning(translator.translate(partEvent(next))), ["\n\n", "Another thought"])
    }

    func testUsageSeparatesCacheAndIncludesReasoningWithoutCompletingTurn() throws {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root", contextWindow: 200_000)
        let complete = info(complete: true).openCodeSetting("tokens", .object([
            "input": .number(100), "output": .number(20), "reasoning": .number(5),
            "cache": .object(["read": .number(40), "write": .number(10)])
        ])).openCodeSetting("finish", .string("stop"))
        let events = translator.translate(event("message.updated", ["info": complete]))
        let usage = try XCTUnwrap(events.compactMap { event -> AgentUsageEvent? in
            guard case let .usage(value) = event else { return nil }
            return value
        }.first)
        XCTAssertEqual(usage.model, "provider/model")
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 25)
        XCTAssertEqual(usage.cacheReadInputTokens, 40)
        XCTAssertEqual(usage.cacheCreationInputTokens, 10)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertEqual(usage.totalTokens, 175)
        XCTAssertEqual(usage.contextWindow, 200_000)
        XCTAssertEqual(usage.stopReason, AgentUsageEvent.interimUsageStopReason)
        XCTAssertFalse(usage.isTerminal)
        XCTAssertTrue(translator.translate(event("message.updated", ["info": complete])).isEmpty)
    }

    func testToolSnapshotSynthesizesMissingStartAndNeverRegressesAfterCompletion() throws {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let events = translator.translate(partEvent(toolPart(status: "completed")))
        let call = try XCTUnwrap(events.compactMap { event -> AgentToolCallEvent? in
            guard case let .toolCall(value) = event else { return nil }
            return value
        }.first)
        let result = try XCTUnwrap(events.compactMap { event -> AgentToolResultEvent? in
            guard case let .toolResult(value) = event else { return nil }
            return value
        }.first)
        XCTAssertEqual(call.id, result.id)
        XCTAssertEqual(call.id, "opencode:ses_root:msg_assistant:call_1")
        XCTAssertEqual(result.content, "done")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(translator.translate(partEvent(toolPart(status: "running"))).isEmpty)
        XCTAssertTrue(translator.translate(partEvent(toolPart(status: "completed"))).isEmpty)
    }

    func testToolIDsDoNotCollideAcrossMessagesOrSessions() {
        let translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let first = translator.toolID(sessionID: "root", messageID: "first", callID: "same")
        XCTAssertNotEqual(first, translator.toolID(sessionID: "root", messageID: "second", callID: "same"))
        XCTAssertNotEqual(first, translator.toolID(sessionID: "child", messageID: "first", callID: "same"))
    }

    func testTaskRegistersChildAndRoutesChildTextToItsParentTool() throws {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let events = translator.translate(partEvent(toolPart(status: "running", name: "task", child: "ses_child")))
        let subagent = try XCTUnwrap(events.compactMap { event -> AgentSubAgentEvent? in
            guard case let .subAgent(value) = event else { return nil }
            return value
        }.first)
        XCTAssertEqual(subagent.childSessionIds, ["ses_child"])
        XCTAssertEqual(subagent.phase, .started)
        XCTAssertTrue(translator.contains(sessionID: "ses_child"))
        _ = translator.translate(event("message.updated", ["info": info(sessionID: "ses_child")]))
        let childPart = textPart("Child reply", complete: true).openCodeSetting("sessionID", .string("ses_child"))
        let childEvents = translator.translate(partEvent(childPart))
        guard case let .message(message)? = childEvents.first else { return XCTFail("Missing child message") }
        XCTAssertEqual(message.metadata["parent_tool_use_id"], .string(subagent.id))
        XCTAssertEqual(message.metadata["opencode_parent_session_id"], .string("ses_root"))
    }

    func testUnrelatedSessionsAndUntrustedDescendantsAreIgnored() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        translator.registerChild(.object(["id": .string("ses_foreign_child"), "parentID": .string("ses_foreign")]))
        XCTAssertFalse(translator.contains(sessionID: "ses_foreign_child"))
        XCTAssertTrue(translator.translate(event("message.updated", ["info": info(sessionID: "ses_foreign")])).isEmpty)
        translator.registerChild(.object(["id": .string("ses_child"), "parentID": .string("ses_root")]))
        translator.registerChild(.object(["id": .string("ses_grandchild"), "parentID": .string("ses_child")]))
        XCTAssertTrue(translator.contains(sessionID: "ses_grandchild"))
    }

    func testIdleAndPermissionEventsNeverCompleteTurnsInTranslator() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        for type in ["session.idle", "session.status", "permission.asked", "question.asked"] {
            XCTAssertTrue(translator.translate(event(type, ["sessionID": .string("ses_root")])).isEmpty)
        }
    }

    func fixture() throws -> [JSONValue] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "opencode-v1-events", withExtension: "json"))
        return try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
    }

    func prepared(part: JSONValue? = nil) -> OpenCodeEventTranslator {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        _ = translator.translate(event("message.updated", ["info": info()]))
        _ = translator.translate(partEvent(part ?? textPart("")))
        return translator
    }

    func info(sessionID: String = "ses_root", messageID: String = "msg_assistant", complete: Bool = false) -> JSONValue {
        var time: [String: JSONValue] = ["created": .number(1000)]
        if complete { time["completed"] = .number(2000) }
        return .object([
            "id": .string(messageID), "sessionID": .string(sessionID), "role": .string("assistant"),
            "parentID": .string("msg_user"), "time": .object(time), "modelID": .string("model"),
            "providerID": .string("provider"), "cost": .number(0.25),
            "tokens": .object(["input": .number(100), "output": .number(20), "reasoning": .number(0),
                               "cache": .object(["read": .number(0), "write": .number(0)])])
        ])
    }

    func textPart(_ text: String, type: String = "text", complete: Bool = false) -> JSONValue {
        var time: [String: JSONValue] = ["start": .number(1001)]
        if complete { time["end"] = .number(1002) }
        return .object([
            "id": .string("prt_text"), "sessionID": .string("ses_root"), "messageID": .string("msg_assistant"),
            "type": .string(type), "text": .string(text), "time": .object(time)
        ])
    }

    func toolPart(status: String, name: String = "bash", child: String? = nil) -> JSONValue {
        .object([
            "id": .string("prt_tool"), "sessionID": .string("ses_root"), "messageID": .string("msg_assistant"),
            "type": .string("tool"), "callID": .string("call_1"), "tool": .string(name),
            "state": .object([
                "status": .string(status), "input": .object(["command": .string("pwd"), "prompt": .string("Investigate")]),
                "output": .string("done"), "error": .string("failed"),
                "metadata": .object(child.map { ["sessionId": .string($0)] } ?? [:]),
                "time": .object(["start": .number(1000), "end": .number(1100)])
            ])
        ])
    }

    func event(_ type: String, _ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string(type), "properties": .object(properties)])
    }

    func partEvent(_ part: JSONValue) -> JSONValue {
        event("message.part.updated", ["part": part])
    }

    func delta(_ text: String) -> JSONValue {
        event("message.part.delta", [
            "sessionID": .string("ses_root"), "messageID": .string("msg_assistant"), "partID": .string("prt_text"),
            "field": .string("text"), "delta": .string(text)
        ])
    }

    func snapshotMessage(info: JSONValue, parts: [JSONValue]) -> JSONValue {
        .object(["info": info, "parts": .array(parts)])
    }

    func messages(_ events: [AgentEvent]) -> [String] {
        events.compactMap { if case let .message(value) = $0 { value.text } else { nil } }
    }

    func deltas(_ events: [AgentEvent]) -> [String] {
        events.compactMap { if case let .messageDelta(value) = $0 { value.text } else { nil } }
    }

    func reasoning(_ events: [AgentEvent]) -> [String] {
        events.compactMap { if case let .reasoning(value) = $0 { value.text } else { nil } }
    }
}

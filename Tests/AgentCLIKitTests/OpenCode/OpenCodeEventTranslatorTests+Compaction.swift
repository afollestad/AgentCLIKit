import XCTest

@testable import AgentCLIKit

extension OpenCodeEventTranslatorTests {
    func testCompactionStartAndSummaryCompleteShareIDWithoutPublishingSummaryAsAssistantText() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let start = translator.translate(partEvent(compactionPart(auto: true)))
        let summaryInfo = info(messageID: "msg_summary", complete: true)
            .openCodeSetting("summary", .bool(true))
        let summaryPart = textPart("Retained context", complete: true)
            .openCodeSetting("messageID", .string("msg_summary"))
        let end = translator.reconcile(messages: [snapshotMessage(info: summaryInfo, parts: [summaryPart])])
        XCTAssertEqual(compactions(start).map(\.phase), [.started])
        XCTAssertEqual(compactions(end).map(\.phase), [.completed])
        XCTAssertEqual(compactions(start).first?.id, compactions(end).first?.id)
        XCTAssertEqual(compactions(end).first?.summary, "Retained context")
        XCTAssertTrue(messages(end).isEmpty)
        XCTAssertTrue(translator.translate(event("session.compacted", ["sessionID": .string("ses_root")])).isEmpty)
    }

    func testCompactionFailureRemainsFailureAfterDuplicateSummaryAndCompletedNotice() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let start = translator.translate(partEvent(compactionPart(auto: false)))
        let failedInfo = info(messageID: "msg_summary", complete: true)
            .openCodeSetting("summary", .bool(true))
            .openCodeSetting("error", .object([
                "name": .string("ContextOverflowError"), "data": .object(["message": .string("Too large to compact")])
            ]))
        let failed = translator.translate(event("message.updated", ["info": failedInfo]))
        XCTAssertEqual(compactions(start).first?.trigger, "manual")
        XCTAssertEqual(compactions(failed).first?.phase, .failed)
        XCTAssertEqual(compactions(failed).first?.errorMessage, "Too large to compact")
        XCTAssertEqual(compactions(start).first?.id, compactions(failed).first?.id)
        XCTAssertTrue(translator.translate(event("message.updated", ["info": failedInfo])).isEmpty)
        XCTAssertTrue(translator.translate(event("session.compacted", ["sessionID": .string("ses_root")])).isEmpty)
    }

    func testResumedCompactionHistoryDoesNotReopenFinishedLifecycle() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let request = info(messageID: "msg_user").openCodeSetting("role", .string("user"))
        let summary = info(messageID: "msg_summary", complete: true).openCodeSetting("summary", .bool(true))
        let snapshots = [
            snapshotMessage(info: request, parts: [compactionPart(auto: true)]),
            snapshotMessage(info: summary, parts: [])
        ]
        translator.seed(messages: snapshots)
        XCTAssertTrue(translator.reconcile(messages: snapshots).isEmpty)
        XCTAssertTrue(translator.translate(partEvent(compactionPart(auto: true))).isEmpty)
    }

    func testRecoverableOverflowDoesNotFailActiveAutomaticCompaction() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        _ = translator.translate(partEvent(compactionPart(auto: true)))
        let overflow = translator.translate(event("session.error", [
            "sessionID": .string("ses_root"),
            "error": .object(["name": .string("ContextOverflowError"), "data": .object(["message": .string("Context is full")])])
        ]))
        XCTAssertTrue(compactions(overflow).isEmpty)
        guard case let .diagnostic(diagnostic)? = overflow.first else { return XCTFail("Missing recovery diagnostic") }
        XCTAssertEqual(diagnostic.severity, .info)
        let completion = translator.translate(event("session.compacted", ["sessionID": .string("ses_root")]))
        XCTAssertEqual(compactions(completion).map(\.phase), [.completed])
    }

    func testInterimErrorUsageCannotCompleteRootTurn() throws {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        translator.registerChild(.object(["id": .string("ses_child"), "parentID": .string("ses_root")]))
        let nativeError: JSONValue = .object(["name": .string("ContextOverflowError")])
        for sessionID in ["ses_root", "ses_child"] {
            let failed = info(sessionID: sessionID, complete: true).openCodeSetting("error", nativeError)
            let events = translator.translate(event("message.updated", ["info": failed]))
            let usage = try XCTUnwrap(events.compactMap { event -> AgentUsageEvent? in
                guard case let .usage(value) = event else { return nil }
                return value
            }.first)
            XCTAssertFalse(usage.isError)
            XCTAssertFalse(usage.isTerminal)
            XCTAssertEqual(usage.stopReason, AgentUsageEvent.interimUsageStopReason)
            XCTAssertEqual(usage.metadata["opencode_error"], nativeError)
        }
    }

    func testChildCompactionDoesNotChangeRootCompactionState() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        translator.registerChild(.object(["id": .string("ses_child"), "parentID": .string("ses_root")]))
        let childPart = compactionPart(auto: true).openCodeSetting("sessionID", .string("ses_child"))
        XCTAssertTrue(translator.translate(partEvent(childPart)).isEmpty)
        XCTAssertTrue(translator.translate(event("session.compacted", ["sessionID": .string("ses_child")])).isEmpty)
    }

    func testTodosMapHostFieldsAndPublishEmptyListToClear() throws {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let todos: JSONValue = .array([.object([
            "content": .string("Implement adapter"), "status": .string("in_progress"), "priority": .string("high")
        ])])
        let changed = event("todo.updated", ["sessionID": .string("ses_root"), "todos": todos])
        let events = translator.translate(changed)
        guard case let .task(task)? = events.first else { return XCTFail("Missing task update") }
        let first = try XCTUnwrap(task.metadata["todos"]?.openCodeArray?.first)
        XCTAssertEqual(first.openCodeValue("subject"), .string("Implement adapter"))
        XCTAssertEqual(first.openCodeValue("status"), .string("inProgress"))
        XCTAssertTrue(translator.translate(changed).isEmpty)
        let cleared = translator.translate(event("todo.updated", ["sessionID": .string("ses_root"), "todos": .array([])]))
        guard case let .task(clear)? = cleared.first else { return XCTFail("Missing clear event") }
        XCTAssertEqual(clear.metadata["todos"], .array([]))
    }

    func testProviderAuthErrorUsesExistingDiagnosticCode() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let events = translator.translate(event("session.error", [
            "sessionID": .string("ses_root"),
            "error": .object([
                "name": .string("ProviderAuthError"), "data": .object(["message": .string("Sign in again")])
            ])
        ]))
        guard case let .diagnostic(diagnostic)? = events.first else { return XCTFail("Missing diagnostic") }
        XCTAssertEqual(diagnostic.code, .harnessAuthenticationRequired)
        XCTAssertEqual(diagnostic.message, "Sign in again")
    }

    func testToolErrorProducesOneFailedResult() {
        var translator = OpenCodeEventTranslator(rootSessionID: "ses_root")
        let events = translator.translate(partEvent(toolPart(status: "error")))
        let results = events.compactMap { event -> AgentToolResultEvent? in
            guard case let .toolResult(result) = event else { return nil }
            return result
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.content, "failed")
        XCTAssertEqual(results.first?.isError, true)
    }

    private func compactionPart(auto: Bool) -> JSONValue {
        .object([
            "id": .string("prt_compaction"), "sessionID": .string("ses_root"), "messageID": .string("msg_user"),
            "type": .string("compaction"), "auto": .bool(auto)
        ])
    }

    private func compactions(_ events: [AgentEvent]) -> [AgentContextCompactionEvent] {
        events.compactMap { if case let .contextCompaction(value) = $0 { value } else { nil } }
    }
}

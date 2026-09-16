import XCTest

@testable import AgentCLIKit

extension OpenCodeRuntimeCompatibilityTests {
    func testCompletedCompactionSurvivesUnavailableFollowupReads() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        _ = try await fixture.launch()
        let events = OpenCodeCompatibilityEvents()
        let stream = await fixture.stream()
        let collector = Task { await events.consume(stream) }
        await fixture.transport.suspendNextRequest(path: "/session/ses_current/summarize")
        let send = Task { try await fixture.send(.userMessage(AgentMessageInput(text: "/compact"))) }
        let submitted = await openCodeWaitUntil { await fixture.transport.requests.contains { $0.path.hasSuffix("/summarize") } }
        XCTAssertTrue(submitted)
        let history = Self.regressionHistory(userID: "msg_compact", compactionID: "prt_compact")
        for message in history {
            await fixture.transport.emit(.object([
                "type": .string("message.updated"), "properties": .object(["info": message[oc: "info"] ?? .null])
            ]))
            for part in message[oc: "parts"]?.ocArray ?? [] {
                await fixture.transport.emit(.object(["type": .string("message.part.updated"), "properties": .object(["part": part])]))
            }
        }
        await fixture.transport.emit(.object([
            "type": .string("session.compacted"), "properties": .object(["sessionID": .string("ses_current")])
        ]))
        let completed = await openCodeWaitUntil {
            await events.values.contains { if case let .usage(value) = $0 { return value.isTerminal }; return false }
        }
        XCTAssertTrue(completed)
        await fixture.transport.failNextRequest(path: "/permission", error: .unavailable("Followup read failed"), count: 2)
        await fixture.transport.releaseRequest(path: "/session/ses_current/summarize")
        do {
            try await send.value
            try await fixture.send(.userMessage(AgentMessageInput(text: "Continue after compaction")))
        } catch {
            await fixture.stop()
            await collector.value
            throw error
        }
        await fixture.stop()
        await collector.value
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/summarize") }.count, 1)
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/prompt_async") }.count, 1)
        let recorded = await events.values
        XCTAssertEqual(recorded.filter { if case let .usage(value) = $0 { return value.isTerminal }; return false }.count, 1)
    }

    func testRejectedSteeringReconcilesOriginalTurnBeforeAcceptingCompaction() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        _ = try await fixture.launch()
        let stream = await fixture.stream()
        try await fixture.send(.userMessage(AgentMessageInput(text: "Original turn")))
        let requests = await fixture.transport.requests
        let originalID = try XCTUnwrap(requests.last { $0.path.hasSuffix("/prompt_async") }?.body?[oc: "messageID"]?.ocString)
        await fixture.transport.setRecovery(history: Self.regressionHistory(userID: originalID))
        let rejection = OpenCodeTransportError.http(status: 400, path: "/session/ses_current/prompt_async")
        await fixture.transport.failNextRequest(path: "/session/ses_current/prompt_async", error: rejection)
        do {
            try await fixture.send(.userMessage(AgentMessageInput(text: "Steering", metadata: [AgentSteeringMetadata.isSteering: .bool(true)])))
            XCTFail("The rejected steering must report its definite HTTP error")
        } catch { XCTAssertEqual(error as? OpenCodeTransportError, rejection) }
        // The original turn completed during the rejected request; compaction must now be allowed.
        try await fixture.send(.userMessage(AgentMessageInput(text: "/compact")))
        await fixture.stop()
        let finalRequests = await fixture.transport.requests
        XCTAssertEqual(finalRequests.filter { $0.path.hasSuffix("/summarize") }.count, 1)
        let terminals = await Self.regressionTerminals(stream)
        XCTAssertEqual(terminals.count, 1)
        XCTAssertFalse(terminals.first?.isError ?? true)
    }

    func testTimedOutCompactionKeepsBusyTurnAndNeverResubmits() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        _ = try await fixture.launch()
        let stream = await fixture.stream()
        await fixture.transport.setRecovery(
            history: [], statuses: .object(["ses_current": .object(["type": .string("busy")])])
        )
        await fixture.transport.failNextRequest(path: "/session/ses_current/summarize", error: .unavailable("Response timed out"))
        try await fixture.send(.userMessage(AgentMessageInput(text: "/compact")))
        await assertCompactionStillActive(fixture)
        await fixture.stop()
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/summarize") }.count, 1)
        let terminals = await Self.regressionTerminals(stream)
        XCTAssertTrue(terminals.isEmpty, "A timeout followed by native busy must not end the ongoing compaction")
    }

    func testSecondCompactionCannotCompleteFromFirstCompactionsPersistedSummary() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        _ = try await fixture.launch()
        let stream = await fixture.stream()
        await fixture.transport.setRecovery(history: Self.regressionHistory(userID: "msg_compact_first", compactionID: "prt_compact_first"))
        try await fixture.send(.userMessage(AgentMessageInput(text: "/compact")))
        // The second summarize is accepted before its new compaction part becomes visible in history.
        try await fixture.send(.userMessage(AgentMessageInput(text: "/compact")))
        await assertCompactionStillActive(fixture)
        await fixture.stop()
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/summarize") }.count, 2)
        let terminals = await Self.regressionTerminals(stream)
        XCTAssertEqual(terminals.count, 1, "Only the first compaction has a completed native summary")
    }

    private func assertCompactionStillActive(_ fixture: OpenCodeCompatibilityFixture) async {
        do {
            try await fixture.send(.userMessage(AgentMessageInput(text: "/compact")))
            XCTFail("An active compaction must reject a second submission")
        } catch let error as AgentCLIError {
            guard case .invalidInput = error else { return XCTFail("Expected active-turn rejection, got \(error)") }
        } catch { XCTFail("Expected a typed active-turn rejection, got \(error)") }
    }

    private static func regressionTerminals(_ stream: AsyncStream<AgentHarnessRuntimeEvent>) async -> [AgentUsageEvent] {
        var terminals: [AgentUsageEvent] = []
        for await item in stream {
            if case let .usage(value) = item.event, value.isTerminal { terminals.append(value) }
        }
        return terminals
    }

    private static func regressionHistory(userID: String, compactionID: String? = nil) -> [JSONValue] {
        let parts: [JSONValue] = compactionID.map { id in [.object([
            "id": .string(id), "sessionID": .string("ses_current"), "messageID": .string(userID),
            "type": .string("compaction"), "auto": .bool(false)
        ])] } ?? []
        return [
            .object([
                "info": .object(["id": .string(userID), "sessionID": .string("ses_current"), "role": .string("user")]),
                "parts": .array(parts)
            ]),
            .object(["info": .object([
                "id": .string("msg_summary"), "sessionID": .string("ses_current"), "parentID": .string(userID),
                "role": .string("assistant"), "summary": .bool(compactionID != nil), "finish": .string("stop"),
                "time": .object(["completed": .number(10)])
            ]), "parts": .array([])])
        ]
    }
}

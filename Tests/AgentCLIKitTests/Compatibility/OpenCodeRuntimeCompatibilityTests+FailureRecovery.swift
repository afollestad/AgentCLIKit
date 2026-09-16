import XCTest

@testable import AgentCLIKit

extension OpenCodeRuntimeCompatibilityTests {
    func testModelErrorKeepsServerAliveForNativeCleanupAndNextPrompt() async throws {
        let fixture = OpenCodeCompatibilityFixture(transport: OpenCodeCompatibilityTransport(promptBehavior: .acceptedWithoutResponse))
        let runtime = DefaultAgentRuntime(adapters: [fixture.adapter])
        let conversationID: AgentConversationID = "model-error"
        do {
            try await runtime.spawn(conversationId: conversationID, config: AgentSpawnConfig(
                harnessId: .opencode, workingDirectory: FileManager.default.temporaryDirectory
            ))
            let stream = await runtime.subscribe(conversationId: conversationID, afterIndex: nil).events
            let events = OpenCodeCompatibilityEvents()
            let collector = Task { for await envelope in stream { await events.append(envelope.event) } }
            try await runtime.send(.userMessage(AgentMessageInput(text: "Start work")), conversationId: conversationID)
            let requests = await fixture.transport.requests
            let id = try XCTUnwrap(requests.last { $0.path.hasSuffix("/prompt_async") }?.body?[oc: "messageID"]?.ocString)
            let error: JSONValue = .object(["name": .string("APIError"), "data": .object(["message": .string("Provider failed")])])
            await fixture.transport.emit(nativeEvent("session.error", ["sessionID": .string("ses_current"), "error": error]))
            await fixture.transport.emit(nativeEvent("session.idle", ["sessionID": .string("ses_current")]))
            let failedTurn = await openCodeWaitUntil {
                await events.values.contains { if case let .usage(value) = $0 { return value.isTerminal && value.isError }; return false }
            }
            XCTAssertTrue(failedTurn)
            let status = await runtime.status(conversationId: conversationID)
            XCTAssertEqual(status?.state, .running)
            XCTAssertEqual(status?.inputAvailability, .available)
            XCTAssertEqual(status?.isTurnActive, false)
            XCTAssertEqual(status?.isProcessRunning, true)
            await emitModelFailureCleanup(fixture, parentID: id, error: error)
            let cleanupReceived = await openCodeWaitUntil {
                await events.values.contains {
                    if case let .message(value) = $0 { return value.text == "Partial result before failure" }; return false
                }
            }
            XCTAssertTrue(cleanupReceived)
            try await runtime.send(.userMessage(AgentMessageInput(text: "Try the next task")), conversationId: conversationID)
            let finalRequests = await fixture.transport.requests
            XCTAssertEqual(finalRequests.filter { $0.path.hasSuffix("/prompt_async") }.count, 2)
            let starts = await fixture.transport.startCount
            XCTAssertEqual(starts, 1)
            await runtime.shutdown()
            await collector.value
            let recorded = await events.values
            XCTAssertEqual(recorded.filter { if case let .usage(value) = $0 { return value.isTerminal }; return false }.count, 1)
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    func testServerCrashRetiresRuntimeAndExplicitResumeDoesNotReplayPrompt() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        let runtime = DefaultAgentRuntime(adapters: [fixture.adapter])
        let conversationID: AgentConversationID = "crash-recovery"
        let config = AgentSpawnConfig(harnessId: .opencode, workingDirectory: FileManager.default.temporaryDirectory)
        do {
            try await runtime.spawn(conversationId: conversationID, config: config)
            try await runtime.send(.userMessage(AgentMessageInput(text: "Interrupted work")), conversationId: conversationID)
            await fixture.transport.emit(partEvent([
                "id": .string("prt_task"), "sessionID": .string("ses_current"), "messageID": .string("msg_assistant"),
                "type": .string("tool"), "tool": .string("task"), "callID": .string("call_task"),
                "state": .object(["status": .string("running"), "input": .object(["description": .string("Child work")])])
            ]))
            await fixture.transport.emit(partEvent([
                "id": .string("prt_compaction"), "sessionID": .string("ses_current"), "messageID": .string("msg_compaction"),
                "type": .string("compaction"), "auto": .bool(true)
            ]))
            await fixture.transport.crash()
            let terminated = await openCodeWaitUntil {
                let status = await runtime.status(conversationId: conversationID)
                return status?.state == .failed && status?.isProcessRunning == false
            }
            XCTAssertTrue(terminated, "The embedded server failure must retire the runtime process.")
            let failedStatus = await runtime.status(conversationId: conversationID)
            let status = try XCTUnwrap(failedStatus)
            XCTAssertEqual(status.waitingState, .idle)
            if case .available = status.inputAvailability { XCTFail("Failed generations must block input") }
            let subscription = await runtime.subscribe(conversationId: conversationID, afterIndex: nil)
            let events = await Self.collect(subscription.events, limit: status.lastEventIndex + 1)
            assertInterruptedWorkEvents(events)
            let interruptedRequests = await fixture.transport.requests
            XCTAssertEqual(interruptedRequests.filter { $0.path.hasSuffix("/prompt_async") }.count, 1)

            await fixture.transport.recover()
            try await runtime.spawn(conversationId: conversationID, config: config)
            let resumed = await runtime.status(conversationId: conversationID)
            XCTAssertEqual(resumed?.state, .running)
            XCTAssertEqual(resumed?.harnessSessionId, status.harnessSessionId)
            let resumedRequests = await fixture.transport.requests
            XCTAssertEqual(resumedRequests.filter { $0.path.hasSuffix("/prompt_async") }.count, 1)
            try await runtime.send(.userMessage(AgentMessageInput(text: "Explicit followup")), conversationId: conversationID)
            let finalRequests = await fixture.transport.requests
            XCTAssertEqual(finalRequests.filter { $0.path.hasSuffix("/prompt_async") }.count, 2)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    func testDefaultModelCompactionUsesNativeSessionModelBeforeConfiguration() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        await fixture.transport.setModels(
            native: .object(["providerID": .string("native"), "id": .string("family/current")]),
            configured: "other/model"
        )
        _ = try await fixture.launch()
        try await fixture.send(.userMessage(AgentMessageInput(text: "/compact")))
        await fixture.stop()
        let requests = await fixture.transport.requests
        let body = try XCTUnwrap(requests.first { $0.path.hasSuffix("/summarize") }?.body)
        XCTAssertEqual(body[oc: "providerID"], .string("native"))
        XCTAssertEqual(body[oc: "modelID"], .string("family/current"))
    }

    func testDefaultModelCompactionRecoversLatestUserModelFromForkHistory() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        await fixture.transport.setModels(native: nil, configured: nil)
        await fixture.transport.setRecovery(history: [
            modelHistory(id: "msg_first", provider: "first", model: "old"),
            modelHistory(id: "msg_second", provider: "latest", model: "family/current")
        ])
        _ = try await fixture.launch()
        try await fixture.send(.userMessage(AgentMessageInput(text: "/compact")))
        await fixture.stop()
        let requests = await fixture.transport.requests
        let body = try XCTUnwrap(requests.first { $0.path.hasSuffix("/summarize") }?.body)
        XCTAssertEqual(body[oc: "providerID"], .string("latest"))
        XCTAssertEqual(body[oc: "modelID"], .string("family/current"))
    }

    private func assertInterruptedWorkEvents(_ events: [AgentEventEnvelope]) {
        let failedChildren = events.filter {
            guard case let .subAgent(value) = $0.event else { return false }
            return value.phase == .terminal && value.status == "failed"
        }
        let failedCompactions = events.filter {
            guard case let .contextCompaction(value) = $0.event else { return false }
            return value.phase == .failed
        }
        XCTAssertEqual(failedChildren.count, 1)
        XCTAssertEqual(failedCompactions.count, 1)
    }

    private func emitModelFailureCleanup(_ fixture: OpenCodeCompatibilityFixture, parentID: String, error: JSONValue) async {
        // Native cleanup publishes final text and the completed message after its error and first idle event.
        await fixture.transport.emit(nativeEvent("message.updated", ["info": .object([
            "id": .string("msg_cleanup"), "sessionID": .string("ses_current"), "role": .string("assistant"),
            "parentID": .string(parentID), "time": .object(["completed": .number(10)]), "error": error
        ])]))
        await fixture.transport.emit(partEvent([
            "id": .string("prt_cleanup"), "sessionID": .string("ses_current"), "messageID": .string("msg_cleanup"),
            "type": .string("text"), "text": .string("Partial result before failure"), "time": .object(["end": .number(10)])
        ]))
        await fixture.transport.emit(nativeEvent("session.idle", ["sessionID": .string("ses_current")]))
    }

    private func partEvent(_ part: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("message.part.updated"), "properties": .object(["part": .object(part)])])
    }

    private func nativeEvent(_ type: String, _ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string(type), "properties": .object(properties)])
    }

    private func modelHistory(id: String, provider: String, model: String) -> JSONValue {
        .object(["info": .object([
            "id": .string(id), "sessionID": .string("ses_current"), "role": .string("user"),
            "model": .object(["providerID": .string(provider), "modelID": .string(model)])
        ]), "parts": .array([])])
    }
}

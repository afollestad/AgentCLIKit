import XCTest

@testable import AgentCLIKit

extension OpenCodeRuntimeCompatibilityTests {
    func testConfirmedPromptAcceptanceSurvivesRecoveryReadFailure() async throws {
        try await assertConfirmedAcceptanceSurvivesRecoveryFailure(steering: false, failurePath: "/permission")
    }

    func testConfirmedSteeringAcceptanceAcknowledgesBeforeRecoveryReadFailure() async throws {
        try await assertConfirmedAcceptanceSurvivesRecoveryFailure(steering: true, failurePath: "/session/ses_current/children")
    }

    func testConfirmedAcceptanceFinishesWhenNativeIdlePrecedesLostResponse() async throws {
        let transport = OpenCodeCompatibilityTransport(promptBehavior: .acceptedWithoutResponse)
        let fixture = OpenCodeCompatibilityFixture(transport: transport)
        _ = try await fixture.launch()
        await transport.suspendNextRequest(path: "/session/ses_current/prompt_async")
        let events = OpenCodeCompatibilityEvents()
        let stream = await fixture.stream()
        let collector = Task { await events.consume(stream) }
        let send = Task { try await fixture.send(.userMessage(AgentMessageInput(text: "Accepted prompt"))) }
        let submitted = await openCodeWaitUntil { await transport.requests.contains { $0.path.hasSuffix("/prompt_async") } }
        XCTAssertTrue(submitted)
        let requests = await transport.requests
        let id = try XCTUnwrap(requests.last { $0.path.hasSuffix("/prompt_async") }?.body?[oc: "messageID"]?.ocString)
        let assistant = Self.completedHistory(userID: id, finish: "stop").last?[oc: "info"] ?? .null
        await transport.emit(Self.event("message.updated", properties: ["info": assistant]))
        await transport.emit(Self.event("session.idle", properties: ["sessionID": .string("ses_current")]))
        await transport.emit(Self.event("todo.updated", properties: ["sessionID": .string("ses_current"), "todos": .array([])]))
        let idleReceived = await openCodeWaitUntil {
            await events.values.contains { if case .task = $0 { return true }; return false }
        }
        XCTAssertTrue(idleReceived)
        await transport.failNextRequest(path: "/session/ses_current/children", error: .unavailable("Recovery read failed"))
        await transport.releaseRequest(path: "/session/ses_current/prompt_async")
        try await send.value
        await fixture.stop()
        await collector.value
        let recorded = await events.values
        XCTAssertEqual(recorded.filter(Self.isTerminal).count, 1)
    }

    func testLostAutomaticApprovalResponseDoesNotLeaveRuntimeWaiting() async throws {
        try await assertAutomaticApprovalRecovery(accepted: true)
    }

    func testRejectedAutomaticApprovalKeepsPendingRequestVisible() async throws {
        try await assertAutomaticApprovalRecovery(accepted: false)
    }

    func testLostAutomaticApprovalResponseRetriesPendingReadWithoutResending() async throws {
        try await assertAutomaticApprovalRecovery(accepted: true, readFailures: 1)
    }

    func testUnverifiableAutomaticApprovalRequiresResumeWithoutStalePrompt() async throws {
        try await assertAutomaticApprovalRecovery(accepted: true, readFailures: 3)
    }

    func testUnverifiableExplicitApprovalRequiresResumeWithoutRestoringWaitingState() async throws {
        try await assertExplicitApprovalRecovery(deliverReplyEvent: false)
    }

    func testExplicitApprovalCanRecoverFromNativeReplyDespiteUnavailablePendingReads() async throws {
        try await assertExplicitApprovalRecovery(deliverReplyEvent: true)
    }

    func testNativeReplyRemainsResolvedWhenEarlierPendingSnapshotArrivesLater() async throws {
        let transport = OpenCodeCompatibilityTransport(losePermissionReplyResponse: true, emitPermissionReplyEvent: false)
        let fixture = OpenCodeCompatibilityFixture(transport: transport)
        let runtime = DefaultAgentRuntime(adapters: [fixture.adapter])
        let conversationID: AgentConversationID = "delayed-pending-snapshot"
        do {
            try await runtime.spawn(conversationId: conversationID, config: AgentSpawnConfig(
                harnessId: .opencode, workingDirectory: FileManager.default.temporaryDirectory
            ))
            let events = OpenCodeCompatibilityEvents()
            let stream = await runtime.subscribe(conversationId: conversationID, afterIndex: nil).events
            let collector = Task { for await event in stream { await events.append(event.event) } }
            let permission: JSONValue = .object([
                "id": .string("per_delayed"), "sessionID": .string("ses_current"), "permission": .string("bash")
            ])
            await transport.askPermission(permission)
            let waiting = await openCodeWaitUntil { await runtime.status(conversationId: conversationID)?.waitingState == .approval }
            XCTAssertTrue(waiting)
            await transport.respondToNextRequest(path: "/permission", response: .array([permission]))
            await transport.suspendNextRequest(path: "/permission")
            let resolution = Task {
                try await runtime.resolveInteraction(
                    AgentInteractionResolution(id: "per_delayed", outcome: .approved), conversationId: conversationID
                )
            }
            let reading = await openCodeWaitUntil { await transport.requests.last?.path == "/permission" }
            XCTAssertTrue(reading)
            await transport.emit(Self.event("permission.replied", properties: [
                "requestID": .string("per_delayed"), "sessionID": .string("ses_current")
            ]))
            await transport.emit(Self.event("todo.updated", properties: ["sessionID": .string("ses_current"), "todos": .array([])]))
            let replied = await openCodeWaitUntil { await events.values.contains { if case .task = $0 { return true }; return false } }
            XCTAssertTrue(replied)
            await transport.releaseRequest(path: "/permission")
            try await resolution.value
            let status = await runtime.status(conversationId: conversationID)
            XCTAssertEqual(status?.waitingState, .idle)
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.path == "/permission/per_delayed/reply" }.count, 1)
            await runtime.shutdown()
            await collector.value
        } catch {
            await transport.releaseRequest(path: "/permission")
            await runtime.shutdown()
            throw error
        }
    }

    private func assertExplicitApprovalRecovery(deliverReplyEvent: Bool) async throws {
        let transport = OpenCodeCompatibilityTransport(
            promptBehavior: .acceptedWithoutResponse, losePermissionReplyResponse: true, emitPermissionReplyEvent: deliverReplyEvent
        )
        let fixture = OpenCodeCompatibilityFixture(transport: transport)
        let runtime = DefaultAgentRuntime(adapters: [fixture.adapter])
        let conversationID: AgentConversationID = "explicit-approval"
        let config = AgentSpawnConfig(harnessId: .opencode, workingDirectory: FileManager.default.temporaryDirectory)
        do {
            try await runtime.spawn(conversationId: conversationID, config: config)
            try await runtime.send(.userMessage(AgentMessageInput(text: "Check status")), conversationId: conversationID)
            await transport.askPermission(.object([
                "id": .string("per_explicit"), "sessionID": .string("ses_current"), "permission": .string("bash")
            ]))
            let waiting = await openCodeWaitUntil { await runtime.status(conversationId: conversationID)?.waitingState == .approval }
            XCTAssertTrue(waiting)
            await transport.failNextRequest(path: "/permission", error: .unavailable("Pending read failed"), count: 3)
            var resolutionError: Error?
            do {
                try await runtime.resolveInteraction(
                    AgentInteractionResolution(id: "per_explicit", outcome: .approved), conversationId: conversationID
                )
            } catch { resolutionError = error }
            XCTAssertEqual(resolutionError == nil, deliverReplyEvent)
            let settled = await openCodeWaitUntil {
                let status = await runtime.status(conversationId: conversationID)
                return status?.waitingState == .idle && status?.state == (deliverReplyEvent ? .running : .failed)
            }
            XCTAssertTrue(settled)
            if !deliverReplyEvent {
                try await runtime.spawn(conversationId: conversationID, config: config)
                let resumed = await runtime.status(conversationId: conversationID)
                XCTAssertEqual(resumed?.state, .running)
                XCTAssertEqual(resumed?.waitingState, .idle)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.path == "/permission/per_explicit/reply" }.count, 1)
            XCTAssertEqual(requests.filter { $0.path.hasSuffix("/prompt_async") }.count, 1)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private func assertAutomaticApprovalRecovery(accepted: Bool, readFailures: Int = 0) async throws {
        let transport = OpenCodeCompatibilityTransport(promptBehavior: .acceptedWithoutResponse, losePermissionReplyResponse: accepted)
        let approvals = InMemoryAgentApprovalPolicyStore()
        let conversationID: AgentConversationID = "automatic-approval"
        _ = await approvals.recordSessionApproval(AgentSessionApprovalGrant(
            harnessId: .opencode, conversationId: conversationID, sessionId: "ses_current", matchKind: .bashExact, matchValue: "git status"
        ))
        let adapter = OpenCodeHarnessAdapter(configuration: .init(
            executablePath: "/test/opencode", sessionApprovalPolicyStore: approvals, makeTransport: { _ in transport }
        ))
        let runtime = DefaultAgentRuntime(adapters: [adapter])
        do {
            let stream = await runtime.subscribe(conversationId: conversationID, afterIndex: nil).events
            let events = OpenCodeCompatibilityEvents()
            let collector = Task { for await event in stream { await events.append(event.event) } }
            try await runtime.spawn(conversationId: conversationID, config: AgentSpawnConfig(
                harnessId: .opencode, workingDirectory: FileManager.default.temporaryDirectory
            ))
            try await runtime.send(.userMessage(AgentMessageInput(text: "Check status")), conversationId: conversationID)
            if !accepted {
                await transport.failNextRequest(path: "/permission/per_automatic/reply", error: .http(status: 400, path: "/permission"))
            }
            if readFailures > 0 {
                await transport.failNextRequest(path: "/permission", error: .unavailable("Pending read failed"), count: readFailures)
            }
            await transport.askPermission(.object([
                "id": .string("per_automatic"), "sessionID": .string("ses_current"), "permission": .string("bash"),
                "metadata": .object(["command": .string("git status")])
            ]))
            // This later event proves the SSE consumer finished processing the automatic reply before checking host waiting state.
            await transport.emit(Self.event("todo.updated", properties: ["sessionID": .string("ses_current"), "todos": .array([])]))
            let handled = await openCodeWaitUntil {
                let failed = await runtime.status(conversationId: conversationID)?.state == .failed
                if failed { return true }
                return await events.values.contains { if case .task = $0 { return true }; return false }
            }
            XCTAssertTrue(handled)
            let status = await runtime.status(conversationId: conversationID)
            XCTAssertEqual(status?.waitingState, accepted ? .idle : .approval)
            XCTAssertEqual(status?.state, readFailures == 3 ? .failed : .running)
            if accepted, readFailures < 3 { XCTAssertEqual(status?.inputAvailability, .available) }
            let recorded = await events.values
            XCTAssertEqual(recorded.filter { if case .interaction = $0 { return true }; return false }.count, accepted ? 0 : 1)
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.path == "/permission/per_automatic/reply" }.count, 1)
            await runtime.shutdown()
            await collector.value
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private func assertConfirmedAcceptanceSurvivesRecoveryFailure(steering: Bool, failurePath: String) async throws {
        let fixture = OpenCodeCompatibilityFixture(
            transport: OpenCodeCompatibilityTransport(promptBehavior: .acceptedWithoutResponse),
            config: AgentSpawnConfig(harnessId: .opencode, workingDirectory: FileManager.default.temporaryDirectory)
        )
        let runtime = DefaultAgentRuntime(adapters: [fixture.adapter])
        let conversationID: AgentConversationID = "confirmed-acceptance"
        do {
            try await runtime.spawn(conversationId: conversationID, config: fixture.context.spawnConfig)
            let events = OpenCodeCompatibilityEvents()
            let stream = await runtime.subscribe(conversationId: conversationID, afterIndex: nil).events
            let collector = Task { for await event in stream { await events.append(event.event) } }
            if steering {
                try await runtime.send(.userMessage(AgentMessageInput(text: "Original turn")), conversationId: conversationID)
            }
            await fixture.transport.failNextRequest(path: failurePath, error: .unavailable("Recovery read failed"))
            let metadata: [String: JSONValue] = steering ? [AgentSteeringMetadata.isSteering: .bool(true)] : [:]
            try await runtime.send(.userMessage(AgentMessageInput(text: "Accepted prompt", metadata: metadata)), conversationId: conversationID)
            let active = await runtime.status(conversationId: conversationID)
            XCTAssertEqual(active?.isTurnActive, true)
            let requests = await fixture.transport.requests
            let prompts = requests.filter { $0.path.hasSuffix("/prompt_async") }
            XCTAssertEqual(prompts.count, steering ? 2 : 1)
            let id = try XCTUnwrap(prompts.last?.body?[oc: "messageID"]?.ocString)
            let assistant = Self.completedHistory(userID: id, finish: "stop").last?[oc: "info"] ?? .null
            // The confirming history is the only user acknowledgment; recovery failed before a second snapshot in the steering case.
            await fixture.transport.emit(Self.event("message.updated", properties: ["info": assistant]))
            await fixture.transport.emit(Self.event("session.idle", properties: ["sessionID": .string("ses_current")]))
            let completed = await openCodeWaitUntil { await runtime.status(conversationId: conversationID)?.isTurnActive == false }
            XCTAssertTrue(completed)
            await runtime.shutdown()
            await collector.value
            let recorded = await events.values
            XCTAssertEqual(recorded.filter(Self.isTerminal).count, 1)
            let acknowledgments = recorded.filter {
                guard case let .message(message) = $0 else { return false }
                return message.metadata[AgentSteeringMetadata.signal] == .string(AgentSteeringMetadata.signalRuntimeInputAccepted)
            }
            XCTAssertEqual(acknowledgments.count, steering ? 1 : 0)
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    func testReconnectRetriesHistoryReadAndDoesNotTerminateDuringRetryStatus() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        _ = try await fixture.launch()
        let events = OpenCodeCompatibilityEvents()
        let stream = await fixture.stream()
        let collector = Task { await events.consume(stream) }
        try await fixture.send(.userMessage(AgentMessageInput(text: "Change the file")))
        let requests = await fixture.transport.requests
        let id = try XCTUnwrap(requests.last { $0.path.hasSuffix("prompt_async") }?.body?[oc: "messageID"]?.ocString)
        let history = Self.completedHistory(userID: id, finish: "tool-calls")
        await fixture.transport.setRecovery(
            history: history, statuses: .object(["ses_current": .object(["type": .string("retry")])]), failures: 1
        )
        await fixture.transport.disconnect()
        let recovered = await openCodeWaitUntil {
            await events.values.contains { if case .usage = $0 { return true }; return false }
        }
        XCTAssertTrue(recovered)
        let retryEvents = await events.values
        XCTAssertFalse(retryEvents.contains(where: Self.isTerminal))
        let readCount = await fixture.transport.requests.filter { $0.path.hasSuffix("/message") }.count
        XCTAssertGreaterThanOrEqual(readCount, 3)
        await fixture.transport.emit(Self.event("session.idle", properties: ["sessionID": .string("ses_current")]))
        let complete = await openCodeWaitUntil { await events.values.contains(where: Self.isTerminal) }
        XCTAssertTrue(complete, "Native idle ends a denied tool-call turn, while retry must not")
        await fixture.stop()
        await collector.value
    }

    func testRecoverableOverflowDoesNotFinishButPersistedTerminalErrorDoes() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        _ = try await fixture.launch()
        let events = OpenCodeCompatibilityEvents()
        let stream = await fixture.stream()
        let collector = Task { await events.consume(stream) }
        try await fixture.send(.userMessage(AgentMessageInput(text: "Continue")))
        let requests = await fixture.transport.requests
        let id = try XCTUnwrap(requests.last { $0.path.hasSuffix("prompt_async") }?.body?[oc: "messageID"]?.ocString)
        let error: JSONValue = .object(["name": .string("ContextOverflowError"), "data": .object(["message": .string("Context is full")])])
        await fixture.transport.emit(Self.event("session.error", properties: ["sessionID": .string("ses_current"), "error": error]))
        let diagnosed = await openCodeWaitUntil {
            await events.values.contains { if case .diagnostic = $0 { return true }; return false }
        }
        XCTAssertTrue(diagnosed)
        let before = await events.values
        XCTAssertFalse(before.contains(where: Self.isTerminal))
        // With automatic compaction disabled, native history persists a terminal error before idle.
        let history = Self.completedHistory(userID: id, finish: "error", error: error)
        for message in history {
            await fixture.transport.emit(Self.event("message.updated", properties: ["info": message[oc: "info"] ?? .null]))
        }
        await fixture.transport.emit(Self.event("session.idle", properties: ["sessionID": .string("ses_current")]))
        let failed = await openCodeWaitUntil {
            await events.values.contains { if case let .usage(value) = $0 { return value.isTerminal && value.isError }; return false }
        }
        XCTAssertTrue(failed)
        await fixture.stop()
        await collector.value
    }

    private static func event(_ type: String, properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string(type), "properties": .object(properties)])
    }

    private static func isTerminal(_ event: AgentEvent) -> Bool {
        if case let .usage(value) = event { return value.isTerminal }
        return false
    }

    private static func completedHistory(userID: String, finish: String, error: JSONValue? = nil) -> [JSONValue] {
        var assistant: [String: JSONValue] = [
            "id": .string("msg_assistant"), "sessionID": .string("ses_current"), "parentID": .string(userID),
            "role": .string("assistant"), "finish": .string(finish), "time": .object(["completed": .number(10)]),
            "tokens": .object(["input": .number(10), "output": .number(2)])
        ]
        assistant["error"] = error
        return [
            .object(["info": .object(["id": .string(userID), "sessionID": .string("ses_current"), "role": .string("user")])]),
            .object(["info": .object(assistant)])
        ]
    }
}

import XCTest

@testable import AgentCLIKit

extension OpenCodeRuntimeCompatibilityTests {
    func testExplicitImageModelPreservesProviderVariantAndPlanMode() async throws {
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        try image.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let config = AgentSpawnConfig(
            harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory,
            model: "alpha/family/model", effort: "high", collaborationMode: .plan
        )
        let fixture = OpenCodeCompatibilityFixture(config: config)
        _ = try await fixture.launch()
        try await fixture.send(.userMessage(AgentMessageInput(text: "Describe this", attachments: [.localImage(id: "image", fileURL: imageURL)])))
        await fixture.stop()
        let requests = await fixture.transport.requests
        let body = try XCTUnwrap(requests.first { $0.path.hasSuffix("/prompt_async") }?.body)
        XCTAssertEqual(body[oc: "model"], .object(["providerID": .string("alpha"), "modelID": .string("family/model")]))
        XCTAssertEqual(body[oc: "variant"], .string("high"))
        XCTAssertEqual(body[oc: "agent"], .string("plan"))
        XCTAssertEqual(body[oc: "parts"]?.ocArray?.last?[oc: "mime"], .string("image/png"))
        XCTAssertEqual(body[oc: "parts"]?.ocArray?.last?[oc: "url"], .string("data:image/png;base64," + image.base64EncodedString()))
    }

    func testUnknownAndTextOnlyModelsRejectImagesBeforeAnyPromptMutation() async throws {
        for model in [nil, "beta/family/model"] as [String?] {
            let fixture = OpenCodeCompatibilityFixture(config: AgentSpawnConfig(
                harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory, model: model
            ))
            _ = try await fixture.launch()
            do {
                try await fixture.send(.userMessage(AgentMessageInput(
                    text: "Describe", attachments: [.localImage(id: "image", fileURL: URL(fileURLWithPath: "/missing.png"))]
                )))
                XCTFail("Image acceptance requires verified model metadata")
            } catch let AgentCLIError.unsupportedInputAttachment(harnessId, attachmentId, _, _) {
                XCTAssertEqual(harnessId, .opencode)
                XCTAssertEqual(attachmentId, "image")
            } catch { XCTFail("Expected typed attachment error, got \(error)") }
            await fixture.stop()
            let requests = await fixture.transport.requests
            XCTAssertFalse(requests.contains { $0.path.hasSuffix("/prompt_async") })
        }
    }

    func testPermissionAndMultiQuestionRepliesKeepNativeRequestIdentity() async throws {
        let permission: JSONValue = .object([
            "id": .string("per_test"), "sessionID": .string("ses_current"), "permission": .string("bash"),
            "metadata": .object(["command": .string("ls")]), "patterns": .array([.string("ls")])
        ])
        let questions: JSONValue = .object([
            "id": .string("que_test"), "sessionID": .string("ses_current"), "questions": .array([
                .object(["question": .string("Choose colors"), "multiple": .bool(true)]),
                .object(["question": .string("Choose size"), "multiple": .bool(false)])
            ])
        ])
        let fixture = OpenCodeCompatibilityFixture(transport: OpenCodeCompatibilityTransport(permissions: [permission], questions: [questions]))
        _ = try await fixture.launch()
        let stream = await fixture.stream()
        try await fixture.send(.interactionResolution(AgentInteractionResolution(id: "per_test", outcome: .approved)))
        try await fixture.send(.interactionResolution(AgentInteractionResolution(
            id: "que_test", outcome: .answered, metadata: ["updated_input": .object(["answers": .object([
                "0": .array([.string("blue"), .string("green")]), "1": .string("large")
            ])])]
        )))
        await fixture.stop()
        var interactions: [AgentInteractionEvent] = []
        for await item in stream { if case let .interaction(value) = item.event { interactions.append(value) } }
        XCTAssertEqual(interactions.map(\.id), ["per_test", "que_test"])
        XCTAssertEqual(interactions.first?.kind, .approval)
        XCTAssertEqual(interactions.first?.metadata["tool_name"], .string("Bash"))
        XCTAssertEqual(interactions.last?.kind, .prompt)
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.first { $0.path == "/permission/per_test/reply" }?.body, .object(["reply": .string("once")]))
        XCTAssertEqual(requests.first { $0.path == "/question/que_test/reply" }?.body, .object([
            "answers": .array([.array([.string("blue"), .string("green")]), .array([.string("large")])])
        ]))
    }

    func testPermissionDenialSessionGrantAndQuestionCancellation() async throws {
        let permissions = ["per_deny", "per_session"].map {
            JSONValue.object(["id": .string($0), "sessionID": .string("ses_current"), "permission": .string("edit")])
        }
        let question: JSONValue = .object(["id": .string("que_cancel"), "sessionID": .string("ses_current"), "questions": .array([])])
        let fixture = OpenCodeCompatibilityFixture(transport: OpenCodeCompatibilityTransport(permissions: permissions, questions: [question]))
        _ = try await fixture.launch()
        try await fixture.send(.interactionResolution(AgentInteractionResolution(id: "per_deny", outcome: .denied)))
        try await fixture.send(.interactionResolution(AgentInteractionResolution(
            id: "per_session", outcome: .approved, metadata: ["approval_grant_kind": .string("session")]
        )))
        try await fixture.send(.interactionResolution(AgentInteractionResolution(id: "que_cancel", outcome: .cancelled)))
        await fixture.stop()
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.first { $0.path == "/permission/per_deny/reply" }?.body, .object(["reply": .string("reject")]))
        XCTAssertEqual(requests.first { $0.path == "/permission/per_session/reply" }?.body, .object(["reply": .string("always")]))
        XCTAssertTrue(requests.contains { $0.path == "/question/que_cancel/reject" && $0.method == "POST" && $0.body == nil })
    }

    func testSteeringAcknowledgesOnlyAfterNativeMessageAndReconnectDoesNotResend() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        _ = try await fixture.launch()
        let events = OpenCodeCompatibilityEvents()
        let stream = await fixture.stream()
        let consumer = Task { await events.consume(stream) }
        try await fixture.send(.userMessage(AgentMessageInput(text: "First turn")))
        try await fixture.send(.userMessage(AgentMessageInput(text: "Use blue", metadata: [AgentSteeringMetadata.isSteering: .bool(true)])))
        let requests = await fixture.transport.requests
        let prompts = requests.filter { $0.path.hasSuffix("/prompt_async") }
        let lastID = try XCTUnwrap(prompts.last?.body?[oc: "messageID"]?.ocString)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/abort") })
        let before = await events.values
        XCTAssertFalse(before.contains { if case let .message(message) = $0 { return message.role == .user }; return false })
        await fixture.transport.emit(.object([
            "type": .string("message.updated"), "properties": .object(["info": .object([
                "id": .string(lastID), "sessionID": .string("ses_current"), "role": .string("user")
            ])])
        ]))
        let accepted = await openCodeWaitUntil {
            await events.values.contains {
                if case let .message(message) = $0 {
                    return message.metadata[AgentSteeringMetadata.signal] == .string(AgentSteeringMetadata.signalRuntimeInputAccepted)
                }
                return false
            }
        }
        XCTAssertTrue(accepted)
        await fixture.transport.disconnect()
        let reconnected = await openCodeWaitUntil { await fixture.transport.eventStreamCount == 2 }
        XCTAssertTrue(reconnected)
        await fixture.stop()
        await consumer.value
        let after = await fixture.transport.requests
        XCTAssertEqual(after.filter { $0.path.hasSuffix("/prompt_async") }.count, 2)
        let recorded = await events.values
        let acknowledgments = recorded.filter {
            if case let .message(message) = $0 { return message.metadata[AgentSteeringMetadata.signal] != nil }
            return false
        }
        XCTAssertEqual(acknowledgments.count, 1)
    }
}

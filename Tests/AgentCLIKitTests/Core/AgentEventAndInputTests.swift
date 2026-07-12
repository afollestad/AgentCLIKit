import XCTest

@testable import AgentCLIKit

final class AgentEventAndInputTests: XCTestCase {
    func testEventEnvelopeRoundTripsThroughJSON() throws {
        let envelope = AgentEventEnvelope(
            generation: 1,
            index: 3,
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: "provider-session",
            source: .stdout,
            event: .message(AgentMessageEvent(role: .assistant, text: "Done.")),
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(AgentEventEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
    }

    func testStreamingAndReasoningEventsRoundTripThroughJSON() throws {
        let events: [AgentEvent] = [
            .messageDelta(AgentMessageDeltaEvent(
                role: .assistant,
                text: "partial",
                metadata: ["parent_tool_use_id": .string("task-1")]
            )),
            .reasoning(AgentReasoningEvent(
                text: "thinking",
                metadata: ["provider": .string("test")]
            ))
        ]

        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([AgentEvent].self, from: data)

        XCTAssertEqual(decoded, events)
    }

    func testRateLimitEventRoundTripsThroughJSON() throws {
        let event = AgentEvent.rateLimit(AgentRateLimitEvent(
            status: .allowedWarning,
            resetDate: Date(timeIntervalSince1970: 1_779_375_000),
            limitType: "five_hour",
            utilization: 0.82,
            overageStatus: .rejected,
            metadata: ["provider": .string("claude")]
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }

    func testCollaborationModeEventRoundTripsThroughJSON() throws {
        let event = AgentEvent.collaborationMode(AgentCollaborationModeEvent(
            mode: .plan,
            metadata: ["provider": .string("codex")]
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }

    func testActivityEventRoundTripsThroughJSONAndDefaultsMetadata() throws {
        let event = AgentEvent.activity(AgentActivityEvent(
            state: .active,
            turnId: "turn-1",
            metadata: ["provider": .string("codex")]
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        let legacyActivity = try JSONDecoder().decode(
            AgentActivityEvent.self,
            from: Data(#"{"state":"idle","turnId":"turn-1"}"#.utf8)
        )

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(legacyActivity.metadata, [:])
    }

    func testContextCompactionEventRoundTripsThroughJSONAndDefaultsMetadata() throws {
        let event = AgentEvent.contextCompaction(AgentContextCompactionEvent(
            id: "compact-1",
            phase: .completed,
            trigger: "auto",
            summary: "Retained recent context.",
            preTokens: 190_000,
            postTokens: 40_000,
            durationMs: 1_250,
            metadata: ["provider": .string("claude")]
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        let legacyCompaction = try JSONDecoder().decode(
            AgentContextCompactionEvent.self,
            from: Data(#"{"id":"compact-1","phase":"started"}"#.utf8)
        )

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(legacyCompaction.metadata, [:])
    }

    func testSubAgentEventRoundTripsThroughJSONAndDefaultsAdditiveFields() throws {
        let event = AgentEvent.subAgent(AgentSubAgentEvent(
            id: "agent-1",
            phase: .terminal,
            description: "Review docs",
            prompt: "Check README",
            agentType: "general-purpose",
            input: .object(["prompt": .string("Check README")]),
            lastToolName: "Agent",
            status: "completed",
            result: "Done",
            toolUses: 2,
            totalTokens: 100,
            durationMs: 250,
            parentToolUseId: "parent-tool",
            callerAgent: "planner",
            parentSessionId: "parent-session",
            childSessionIds: ["child-session"],
            metadata: ["provider": .string("claude")]
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        let legacySubAgent = try JSONDecoder().decode(
            AgentSubAgentEvent.self,
            from: Data(#"{"id":"agent-1","phase":"started"}"#.utf8)
        )

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(legacySubAgent.childSessionIds, [])
        XCTAssertEqual(legacySubAgent.metadata, [:])
    }

    func testSessionMetadataEventRoundTripsThroughJSONAndDefaultsMetadata() throws {
        let event = AgentEvent.sessionMetadata(AgentSessionMetadataEvent(
            providerSessionId: "session-1",
            name: "Generated Name",
            preview: "Generated Preview",
            metadata: ["provider": .string("codex")]
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        let legacyMetadata = try JSONDecoder().decode(
            AgentSessionMetadataEvent.self,
            from: Data(#"{"providerSessionId":"session-1","name":"Generated Name"}"#.utf8)
        )

        XCTAssertEqual(decoded, event)
        XCTAssertNil(legacyMetadata.preview)
        XCTAssertEqual(legacyMetadata.metadata, [:])
    }

    func testInteractionEventRoundTripsPromptOptionsAndDefaultsLegacyFields() throws {
        let event = AgentInteractionEvent(
            id: "prompt",
            kind: .prompt,
            prompt: "Pick one",
            promptOptions: [
                AgentPromptOption(
                    id: "a",
                    label: "Option A",
                    description: "Use A",
                    responseText: "A"
                )
            ],
            metadata: ["provider": .string("codex")]
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentInteractionEvent.self, from: data)
        let legacy = try JSONDecoder().decode(
            AgentInteractionEvent.self,
            from: Data(#"{"id":"prompt","kind":"prompt","prompt":"Pick one"}"#.utf8)
        )

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(legacy.promptOptions, [])
        XCTAssertEqual(legacy.metadata, [:])
    }

    func testMessageAndToolEventsDecodeWhenMetadataIsMissing() throws {
        let messageData = Data(#"{"role":"assistant","text":"Done."}"#.utf8)
        let toolCallData = Data(#"{"id":"tool-1","name":"Edit","input":{"file_path":"README.md"}}"#.utf8)
        let toolResultData = Data(#"{"id":"tool-1","isError":false,"content":"ok"}"#.utf8)

        let message = try JSONDecoder().decode(AgentMessageEvent.self, from: messageData)
        let toolCall = try JSONDecoder().decode(AgentToolCallEvent.self, from: toolCallData)
        let toolResult = try JSONDecoder().decode(AgentToolResultEvent.self, from: toolResultData)

        XCTAssertEqual(message.metadata, [:])
        XCTAssertEqual(toolCall.metadata, [:])
        XCTAssertEqual(toolResult.metadata, [:])
    }

    func testEventEnvelopeDecodesPersistedEventsWithMissingMetadata() throws {
        let envelope = AgentEventEnvelope(
            generation: 1,
            index: 3,
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: "provider-session",
            source: .stdout,
            event: .toolCall(AgentToolCallEvent(
                id: "tool-1",
                name: "Edit",
                input: .object(["file_path": .string("README.md")]),
                metadata: ["parent_tool_use_id": .string("agent-tool-1")]
            )),
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data)
        let legacyData = try JSONSerialization.data(withJSONObject: removingMetadata(from: object))

        let decoded = try JSONDecoder().decode(AgentEventEnvelope.self, from: legacyData)

        XCTAssertEqual(decoded.event, .toolCall(AgentToolCallEvent(
            id: "tool-1",
            name: "Edit",
            input: .object(["file_path": .string("README.md")])
        )))
    }

    func testAgentInputRoundTripsThroughJSON() throws {
        let input = AgentInput.userMessage(
            AgentMessageInput(
                text: "Implement it",
                attachments: [
                    .localImage(id: "image-1", fileURL: URL(fileURLWithPath: "/tmp/screenshot.png"))
                ],
                metadata: ["priority": .string("normal")]
            )
        )

        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(AgentInput.self, from: data)

        XCTAssertEqual(decoded, input)
    }

    func testAttachmentHelpersExposeLocalImageType() {
        let attachment = AgentInputAttachment.localImage(
            id: "image-1",
            fileURL: URL(fileURLWithPath: "/tmp/screenshot.png")
        )

        XCTAssertEqual(attachment.id, "image-1")
        XCTAssertEqual(attachment.type, "localImage")
        XCTAssertTrue(attachment.isLocalImage)
    }

    func testCodexInputMetadataKeysAreStable() {
        XCTAssertEqual(CodexInputMetadata.isAppshot, "codex_input_is_appshot")
    }

    func testSteeringMetadataKeysAreStable() {
        XCTAssertEqual(AgentSteeringMetadata.isSteering, "agent_steering")
        XCTAssertEqual(AgentSteeringMetadata.inputId, "agent_steering_input_id")
        XCTAssertEqual(AgentSteeringMetadata.signal, "agent_steering_signal")
        XCTAssertEqual(AgentSteeringMetadata.signalCodexUserMessageStarted, "codex_user_message_started")
        XCTAssertEqual(AgentSteeringMetadata.signalCodexUserMessageCompleted, "codex_user_message_completed")
        XCTAssertEqual(AgentSteeringMetadata.signalRuntimeInputAccepted, "runtime_input_accepted")
    }

    func testAgentSpawnConfigRoundTripsPermissionAndCollaborationModeThroughJSON() throws {
        let config = hostToolSpawnConfig()

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentSpawnConfig.self, from: data)
        let legacyDecoded = try decodeLegacySpawnConfig(from: data)

        XCTAssertEqual(decoded.reasoningSummaryMode, .auto)
        XCTAssertEqual(decoded.permissionMode, "on-request")
        XCTAssertEqual(decoded.collaborationMode, .plan)
        XCTAssertEqual(decoded.initialPromptAttachments, config.initialPromptAttachments)
        XCTAssertEqual(decoded.initialPromptMetadata, config.initialPromptMetadata)
        XCTAssertEqual(decoded.additionalWorkspaceRoots.map(\.path), ["/tmp/grant-a", "/tmp/grant-b"])
        XCTAssertEqual(decoded.hostToolServer, config.hostToolServer)
        XCTAssertEqual(decoded.hostTools, config.hostTools)
        XCTAssertEqual(decoded, config)
        XCTAssertNil(legacyDecoded.reasoningSummaryMode)
        XCTAssertNil(legacyDecoded.permissionMode)
        XCTAssertNil(legacyDecoded.collaborationMode)
        XCTAssertEqual(legacyDecoded.initialPromptAttachments, [])
        XCTAssertEqual(legacyDecoded.initialPromptMetadata, [:])
        XCTAssertEqual(legacyDecoded.additionalWorkspaceRoots, [])
        XCTAssertEqual(legacyDecoded.hostToolServer, AgentHostToolServerMetadata())
        XCTAssertEqual(legacyDecoded.hostTools, [])
    }

    func testAgentSpawnConfigRoundTripsSessionForkThroughJSON() throws {
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/target"),
            sessionFork: AgentSessionForkRequest(
                sourceSessionId: "source-session",
                sourceWorkingDirectory: URL(fileURLWithPath: "/tmp/source"),
                mode: .worktree
            )
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentSpawnConfig.self, from: data)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "sessionFork")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(AgentSpawnConfig.self, from: legacyData)

        XCTAssertEqual(decoded, config)
        XCTAssertTrue(decoded.forkSession)
        XCTAssertEqual(decoded.sessionFork?.sourceSessionId, "source-session")
        XCTAssertEqual(decoded.sessionFork?.sourceWorkingDirectory?.path, "/tmp/source")
        XCTAssertEqual(decoded.sessionFork?.mode, .worktree)
        XCTAssertNil(legacyDecoded.sessionFork)
        XCTAssertTrue(legacyDecoded.forkSession)
    }

    func testSessionForkDefaultsModeToLocalWhenDecodedFromMinimalPayload() throws {
        let data = Data(#"{"sourceSessionId":"source"}"#.utf8)

        let request = try JSONDecoder().decode(AgentSessionForkRequest.self, from: data)

        XCTAssertEqual(request.sourceSessionId, "source")
        XCTAssertNil(request.sourceWorkingDirectory)
        XCTAssertEqual(request.mode, .local)
    }

    func testPathHelpersExpandTilde() {
        let home = URL(fileURLWithPath: "/Users/example")

        XCTAssertEqual(AgentPathHelpers.expandingTilde(in: "~", homeDirectory: home).path, "/Users/example")
        XCTAssertEqual(AgentPathHelpers.expandingTilde(in: "~/Project", homeDirectory: home).path, "/Users/example/Project")
        XCTAssertEqual(AgentPathHelpers.expandingTilde(in: "/tmp/Project", homeDirectory: home).path, "/tmp/Project")
    }

    func testPathHelpersCanonicalizeTildeAndMatchSymlinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = home.appendingPathComponent("Project", isDirectory: true)
        let link = home.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)

        XCTAssertEqual(AgentPathHelpers.canonicalPath("~/Project", homeDirectory: home), project.path)
        XCTAssertTrue(AgentPathHelpers.isSameCanonicalPath(project.path, "~/Link", homeDirectory: home))
    }

    private func removingMetadata(from value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(removingMetadata)
        }
        guard var dictionary = value as? [String: Any] else {
            return value
        }
        dictionary.removeValue(forKey: "metadata")
        for (key, child) in dictionary {
            dictionary[key] = removingMetadata(from: child)
        }
        return dictionary
    }

    private func hostToolSpawnConfig() -> AgentSpawnConfig {
        AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            reasoningSummaryMode: .auto,
            permissionMode: "on-request",
            collaborationMode: .plan,
            initialPrompt: "Inspect this",
            initialPromptAttachments: [
                .localImage(id: "image-1", fileURL: URL(fileURLWithPath: "/tmp/shot.png"))
            ],
            initialPromptMetadata: ["source": .string("test")],
            additionalWorkspaceRoots: [
                URL(fileURLWithPath: "/tmp/grant-a"),
                URL(fileURLWithPath: "/tmp/grant-a"),
                URL(fileURLWithPath: "/tmp/grant-b")
            ],
            hostToolServer: AgentHostToolServerMetadata(
                name: "alveary_host",
                title: "Alveary",
                instructions: "Open a proposal."
            ),
            hostTools: [AgentHostToolDefinition(
                name: "propose_scheduled_task",
                title: "Propose scheduled task",
                description: "Opens a proposal.",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false)
                ]),
                outputSchema: .object(["type": .string("object")]),
                annotations: AgentHostToolAnnotations(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            )]
        )
    }

    private func decodeLegacySpawnConfig(from data: Data) throws -> AgentSpawnConfig {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let newKeys = [
            "reasoningSummaryMode",
            "permissionMode",
            "collaborationMode",
            "initialPromptAttachments",
            "initialPromptMetadata",
            "additionalWorkspaceRoots",
            "hostToolServer",
            "hostTools"
        ]
        newKeys.forEach { object.removeValue(forKey: $0) }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(AgentSpawnConfig.self, from: legacyData)
    }
}

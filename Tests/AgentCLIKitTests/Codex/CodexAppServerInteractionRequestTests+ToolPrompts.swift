import XCTest

@testable import AgentCLIKit

/// Tool-driven interaction requests: user-input prompts and plan-mode exits.
extension CodexAppServerInteractionRequestTests {
    func testToolRequestUserInputPromptReturnsAnswers() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .string("input-1"), method: "item/tool/requestUserInput", params: toolRequestUserInputParams())

        let interaction = try Self.interaction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(id: interaction.id, outcome: .answered, responseText: "Option A")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let response = await transport.responseLog.first

        XCTAssertEqual(interaction.kind, .prompt)
        XCTAssertEqual(interaction.prompt, "Which option?")
        XCTAssertEqual(interaction.metadata["session_id"], .string("thread-123"))
        XCTAssertEqual(interaction.metadata["tool_name"], .string("AskUserQuestion"))
        XCTAssertEqual(interaction.metadata["tool_input"], .some(toolRequestUserInputParams()))
        XCTAssertEqual(interaction.promptOptions, [
            AgentPromptOption(
                id: "0",
                label: "Option A",
                description: "Use A",
                responseText: "Option A",
                metadata: ["label": .string("Option A"), "description": .string("Use A")]
            )
        ])
        XCTAssertEqual(response?.result, .object([
            "answers": .object([
                "choice": .object(["answers": .array([.string("Option A")])])
            ])
        ]))
    }

    func testToolRequestUserInputPromptReturnsAnswersFromUpdatedInput() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .string("input-2"), method: "item/tool/requestUserInput", params: toolRequestUserInputParams())

        let interaction = try Self.interaction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(
                id: interaction.id,
                outcome: .answered,
                metadata: [
                    "updated_input": .object([
                        "answers": .object(["Which option?": .string("Option A")])
                    ])
                ]
            )),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let response = await transport.responseLog.first

        XCTAssertEqual(response?.result, .object([
            "answers": .object([
                "choice": .object(["answers": .array([.string("Option A")])])
            ])
        ]))
    }

    func testToolRequestUserInputPromptPreservesExplicitCodexAnswers() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .string("input-3"), method: "item/tool/requestUserInput", params: toolRequestUserInputParams())

        let interaction = try Self.interaction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(
                id: interaction.id,
                outcome: .answered,
                metadata: [
                    "codex_answers": .object([
                        "choice": .object([
                            "answers": .array([.string("Option A")]),
                            "source": .string("explicit")
                        ])
                    ]),
                    "updated_input": .object([
                        "answers": .object(["Which option?": .string("Ignored")])
                    ])
                ]
            )),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let response = await transport.responseLog.first

        XCTAssertEqual(response?.result, .object([
            "answers": .object([
                "choice": .object([
                    "answers": .array([.string("Option A")]),
                    "source": .string("explicit")
                ])
            ])
        ]))
    }

    func testToolRequestUserInputPromptNormalizesAnswerKeysAndShapes() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(
            id: .string("input-4"),
            method: "item/tool/requestUserInput",
            params: multiQuestionToolRequestUserInputParams()
        )

        let interaction = try Self.interaction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(
                id: interaction.id,
                outcome: .answered,
                metadata: [
                    "answers": .object([
                        "choice": .array([.string("Option A"), .string("Option B")]),
                        "Notes?": .object(["answers": .array([.string("Ship it")])]),
                        "unknown-key": .string("Unknown")
                    ])
                ]
            )),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let response = await transport.responseLog.first

        XCTAssertEqual(response?.result, .object([
            "answers": .object([
                "choice": .object(["answers": .array([.string("Option A"), .string("Option B")])]),
                "notes": .object(["answers": .array([.string("Ship it")])]),
                "unknown-key": .object(["answers": .array([.string("Unknown")])])
            ])
        ]))
    }

    func testExitPlanModeToolCallRequestsPlanModeExitInteractionAndApproves() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .number(62), method: "item/tool/call", params: exitPlanModeToolCallParams())

        let interaction = try Self.interaction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(id: interaction.id, outcome: .approved)),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let response = await transport.responseLog.first

        XCTAssertEqual(interaction.id.rawValue, "call-exit-plan")
        XCTAssertEqual(interaction.kind, .planModeExit)
        XCTAssertEqual(interaction.prompt, "ExitPlanMode")
        XCTAssertEqual(interaction.metadata["session_id"], .string("thread-123"))
        XCTAssertEqual(interaction.metadata["tool_name"], .string("ExitPlanMode"))
        XCTAssertEqual(interaction.metadata["tool_input"], .object(["plan": .string(Self.exitPlanMarkdown)]))
        XCTAssertEqual(interaction.metadata["plan"], .string(Self.exitPlanMarkdown))
        XCTAssertEqual(response?.id, .number(62))
        XCTAssertEqual(response?.result?.objectValue?["success"], .bool(true))
        XCTAssertEqual(
            response?.result?.objectValue?["contentItems"]?.arrayValue?.first?.objectValue?["text"],
            .string("Plan approved by the host.")
        )
    }

    func testExitPlanModeToolCallDenialReturnsFailureResult() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .number(63), method: "item/tool/call", params: exitPlanModeToolCallParams())

        let interaction = try Self.interaction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(
                id: interaction.id,
                outcome: .denied,
                responseText: "Please revise the plan."
            )),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let response = await transport.responseLog.first

        XCTAssertEqual(interaction.kind, .planModeExit)
        XCTAssertEqual(response?.id, .number(63))
        XCTAssertEqual(response?.result?.objectValue?["success"], .bool(false))
        XCTAssertEqual(
            response?.result?.objectValue?["contentItems"]?.arrayValue?.first?.objectValue?["text"],
            .string("Please revise the plan.")
        )
    }

}

import XCTest

@testable import AgentCLIKit

final class RuntimeInteractionResolutionTests: XCTestCase {
    func testPlanProposalMessageSynthesizesPlanModeExitInteraction() async throws {
        let recorder = PlanProposalRecorder()
        let runtime = DefaultAgentRuntime(adapters: [
            PlanProposalProviderAdapter(recorder: recorder)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            collaborationMode: .plan
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: config)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                guard case let .interaction(interaction) = envelope.event else {
                    return false
                }
                return interaction.kind == .planModeExit
            }
        })
        let status = await runtime.status(conversationId: conversationId)
        let interaction = try XCTUnwrap(events.compactMap { envelope -> AgentInteractionEvent? in
            guard case let .interaction(interaction) = envelope.event else {
                return nil
            }
            return interaction.kind == .planModeExit ? interaction : nil
        }.first)

        await runtime.shutdown()

        let planMessage = try XCTUnwrap(events.compactMap { envelope -> AgentMessageEvent? in
            guard case let .message(message) = envelope.event else {
                return nil
            }
            return message
        }.first)
        XCTAssertEqual(planMessage.role, .assistant)
        XCTAssertEqual(planMessage.text, PlanProposalProviderAdapter.planMarkdown)
        XCTAssertEqual(planMessage.metadata[AgentPlanProposalMetadata.isProposal], .bool(true))
        XCTAssertEqual(planMessage.metadata[AgentPlanProposalMetadata.proposalId], .string("plan-1"))
        XCTAssertEqual(planMessage.metadata[AgentPlanProposalMetadata.planMarkdown], .string(PlanProposalProviderAdapter.planMarkdown))
        XCTAssertEqual(interaction.id, "runtime-plan-exit-plan-1")
        XCTAssertEqual(interaction.prompt, "ExitPlanMode")
        XCTAssertEqual(interaction.metadata["tool_name"], .string("ExitPlanMode"))
        XCTAssertEqual(interaction.metadata["tool_input"], .object(["plan": .string(PlanProposalProviderAdapter.planMarkdown)]))
        XCTAssertEqual(interaction.metadata["plan"], .string(PlanProposalProviderAdapter.planMarkdown))
        XCTAssertEqual(status?.waitingState, .planModeExit)
        XCTAssertEqual(status?.inputAvailability, .blocked(reason: "Waiting for plan-mode approval."))
    }

    func testApprovedSyntheticPlanModeExitSwitchesToDefaultAndStartsImplementation() async throws {
        let recorder = PlanProposalRecorder()
        let runtime = DefaultAgentRuntime(adapters: [
            PlanProposalProviderAdapter(recorder: recorder)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            collaborationMode: .plan
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: config)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                guard case let .interaction(interaction) = envelope.event else {
                    return false
                }
                return interaction.kind == .planModeExit
            }
        })
        let interaction = try XCTUnwrap(events.compactMap { envelope -> AgentInteractionEvent? in
            guard case let .interaction(interaction) = envelope.event else {
                return nil
            }
            return interaction.kind == .planModeExit ? interaction : nil
        }.first)

        try await runtime.resolveInteraction(
            AgentInteractionResolution(id: interaction.id, outcome: .approved),
            conversationId: conversationId
        )
        let recordedInputs = await waitForRecordedInputs(recorder, count: 1)
        let reconfigureContexts = await recorder.reconfigureContexts
        let status = await runtime.status(conversationId: conversationId)

        await runtime.shutdown()

        XCTAssertEqual(reconfigureContexts.count, 1)
        XCTAssertEqual(reconfigureContexts.first?.currentConfig.collaborationMode, .plan)
        XCTAssertEqual(reconfigureContexts.first?.newConfig.collaborationMode, .default)
        XCTAssertEqual(recordedInputs.count, 1)
        guard case let .userMessage(message)? = recordedInputs.first else {
            return XCTFail("Expected approved plan to send a user message.")
        }
        XCTAssertEqual(message.text, "Implement plan")
        XCTAssertEqual(status?.collaborationMode, .default)
        XCTAssertEqual(status?.waitingState, .idle)
    }

    func testApprovedProviderPlanModeExitRespondsThenStartsImplementation() async throws {
        let recorder = PlanProposalRecorder()
        let runtime = DefaultAgentRuntime(adapters: [
            PlanProposalProviderAdapter(recorder: recorder, emitsProviderPlanExit: true)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            collaborationMode: .plan
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: config)
        let events = await Self.collect(subscription.events, until: { envelopes in
            Self.firstPlanModeExit(in: envelopes) != nil
        })
        let interaction = try XCTUnwrap(Self.firstPlanModeExit(in: events))
        async let userMessageEvents = Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                envelope.event == .message(AgentMessageEvent(
                    role: .user,
                    text: "Implement plan",
                    metadata: [
                        "agent_plan_exit_interaction_id": .string("provider-plan-exit"),
                        AgentPlanProposalMetadata.proposalId: .string("provider-plan-exit"),
                        AgentPlanProposalMetadata.planMarkdown: .string(PlanProposalProviderAdapter.planMarkdown)
                    ]
                ))
            }
        })

        try await runtime.resolveInteraction(
            AgentInteractionResolution(id: interaction.id, outcome: .approved),
            conversationId: conversationId
        )
        let recordedInputs = await waitForRecordedInputs(recorder, count: 2)
        let emittedEvents = await userMessageEvents
        let status = await runtime.status(conversationId: conversationId)

        await runtime.shutdown()

        XCTAssertEqual(recordedInputs.count, 2)
        guard case let .interactionResolution(resolution)? = recordedInputs.first else {
            return XCTFail("Expected provider plan exit to be resolved first.")
        }
        guard case let .userMessage(message)? = recordedInputs.last else {
            return XCTFail("Expected approved provider plan to send a user message.")
        }
        XCTAssertEqual(resolution.id, interaction.id)
        XCTAssertEqual(message.text, "Implement plan")
        XCTAssertTrue(emittedEvents.contains {
            $0.event == .message(AgentMessageEvent(
                role: .user,
                text: "Implement plan",
                metadata: [
                    "agent_plan_exit_interaction_id": .string("provider-plan-exit"),
                    AgentPlanProposalMetadata.proposalId: .string("provider-plan-exit"),
                    AgentPlanProposalMetadata.planMarkdown: .string(PlanProposalProviderAdapter.planMarkdown)
                ]
            ))
        })
        XCTAssertEqual(status?.collaborationMode, .default)
        XCTAssertEqual(status?.waitingState, .idle)
    }

    func testApprovedSyntheticPlanModeExitKeepsPlanWithCustomResponseText() async throws {
        let recorder = PlanProposalRecorder()
        let session = try await startPlanProposalRuntime(recorder: recorder)
        let interaction = try XCTUnwrap(Self.firstPlanModeExit(in: session.events))

        try await session.runtime.resolveInteraction(
            AgentInteractionResolution(
                id: interaction.id,
                outcome: .approved,
                responseText: "Keep it minimal."
            ),
            conversationId: session.conversationId
        )
        let recordedInputs = await waitForRecordedInputs(recorder, count: 1)

        await session.runtime.shutdown()

        guard case let .userMessage(message)? = recordedInputs.first else {
            return XCTFail("Expected approved plan to send a user message.")
        }
        XCTAssertEqual(
            message.text,
            """
            Implement plan with this additional instruction:

            Keep it minimal.
            """
        )
    }

    func testDeniedSyntheticPlanModeExitDoesNotStartImplementation() async throws {
        let recorder = PlanProposalRecorder()
        let runtime = DefaultAgentRuntime(adapters: [
            PlanProposalProviderAdapter(recorder: recorder)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            collaborationMode: .plan
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: config)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                guard case let .interaction(interaction) = envelope.event else {
                    return false
                }
                return interaction.kind == .planModeExit
            }
        })
        let interaction = try XCTUnwrap(events.compactMap { envelope -> AgentInteractionEvent? in
            guard case let .interaction(interaction) = envelope.event else {
                return nil
            }
            return interaction.kind == .planModeExit ? interaction : nil
        }.first)

        try await runtime.resolveInteraction(
            AgentInteractionResolution(id: interaction.id, outcome: .denied),
            conversationId: conversationId
        )
        let status = await runtime.status(conversationId: conversationId)
        let recordedInputs = await recorder.inputs
        let reconfigureContexts = await recorder.reconfigureContexts

        await runtime.shutdown()

        XCTAssertTrue(recordedInputs.isEmpty)
        XCTAssertTrue(reconfigureContexts.isEmpty)
        XCTAssertEqual(status?.collaborationMode, .plan)
        XCTAssertEqual(status?.waitingState, .idle)
    }

    func testPlanProposalMessageDoesNotOverwritePendingPrompt() async throws {
        let recorder = PlanProposalRecorder()
        let runtime = DefaultAgentRuntime(adapters: [
            PlanProposalProviderAdapter(recorder: recorder, emitsPromptBeforePlan: true)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            collaborationMode: .plan
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: config)
        let events = await Self.collect(subscription.events, limit: 4)
        let status = await runtime.status(conversationId: conversationId)

        await runtime.shutdown()

        let interactions = events.compactMap { envelope -> AgentInteractionEvent? in
            guard case let .interaction(interaction) = envelope.event else {
                return nil
            }
            return interaction
        }
        XCTAssertEqual(interactions.map(\.kind), [.prompt])
        XCTAssertEqual(status?.waitingState, .prompt)
    }

    func testRuntimeDoesNotReopenResolvedInteractionFromLateProviderFrame() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("""
            printf 'interaction:prompt\\n'
            read resolution
            printf 'interaction:prompt\\n'
            printf "message:$resolution\\n"
            """))
        ])
        let conversationId: AgentConversationID = "conversation"

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let waitingStatus = await waitForWaitingState(.prompt, runtime: runtime, conversationId: conversationId)
        try await runtime.resolveInteraction(
            AgentInteractionResolution(id: "prompt", outcome: .answered, responseText: "yes"),
            conversationId: conversationId
        )
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "yes")) }
        })
        let promptEvents = events.filter {
            $0.event == .interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?"))
        }
        let finalStatus = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(waitingStatus?.waitingState, .prompt)
        XCTAssertEqual(promptEvents.count, 1)
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "yes")) })
        XCTAssertEqual(finalStatus?.waitingState, .idle)
    }

    private func waitForWaitingState(
        _ waitingState: AgentRuntimeWaitingState,
        runtime: DefaultAgentRuntime,
        conversationId: AgentConversationID
    ) async -> AgentRuntimeStatus? {
        for _ in 0..<100 {
            let status = await runtime.status(conversationId: conversationId)
            if status?.waitingState == waitingState {
                return status
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await runtime.status(conversationId: conversationId)
    }

    private func waitForRecordedInputs(_ recorder: PlanProposalRecorder, count: Int) async -> [AgentInput] {
        for _ in 0..<100 {
            let inputs = await recorder.inputs
            if inputs.count >= count {
                return inputs
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await recorder.inputs
    }

    private func startPlanProposalRuntime(
        recorder: PlanProposalRecorder
    ) async throws -> PlanProposalRuntimeSession {
        let runtime = DefaultAgentRuntime(adapters: [
            PlanProposalProviderAdapter(recorder: recorder)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            collaborationMode: .plan
        )
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: config)
        let events = await Self.collect(subscription.events, until: { envelopes in
            Self.firstPlanModeExit(in: envelopes) != nil
        })
        return PlanProposalRuntimeSession(runtime: runtime, conversationId: conversationId, events: events)
    }

    private static func firstPlanModeExit(in events: [AgentEventEnvelope]) -> AgentInteractionEvent? {
        events.compactMap { envelope -> AgentInteractionEvent? in
            guard case let .interaction(interaction) = envelope.event else {
                return nil
            }
            return interaction.kind == .planModeExit ? interaction : nil
        }.first
    }
}

private struct PlanProposalRuntimeSession {
    let runtime: DefaultAgentRuntime
    let conversationId: AgentConversationID
    let events: [AgentEventEnvelope]
}

actor PlanProposalRecorder {
    private(set) var inputs: [AgentInput] = []
    private(set) var reconfigureContexts: [AgentProviderReconfigureContext] = []

    func record(_ input: AgentInput) {
        inputs.append(input)
    }

    func record(_ context: AgentProviderReconfigureContext) -> AgentProviderReconfigureResult {
        reconfigureContexts.append(context)
        return .appliedInPlace
    }
}

struct PlanProposalProviderAdapter: AgentProviderAdapter {
    static let planMarkdown = "# Plan"
    static let revisedPlanMarkdown = "# Revised Plan"
    static let planMetadata = metadata(for: planMarkdown)

    static func metadata(for planMarkdown: String) -> [String: JSONValue] {
        [
            AgentPlanProposalMetadata.isProposal: .bool(true),
            AgentPlanProposalMetadata.proposalId: .string("plan-1"),
            AgentPlanProposalMetadata.planMarkdown: .string(planMarkdown)
        ]
    }

    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let recorder: PlanProposalRecorder
    var emitsPromptBeforePlan = false
    var emitsProviderPlanExit = false
    var emitsPlanRevisionAfterResolution = false

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        if emitsProviderPlanExit {
            return AgentLaunchConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'provider-plan-exit\\n'; while read line; do printf 'resolved:%s\\n' \"$line\"; done"]
            )
        }
        if emitsPromptBeforePlan {
            return AgentLaunchConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'prompt\\n'; printf 'plan:\(Self.planMarkdown)\\n'; sleep 5"]
            )
        }
        if emitsPlanRevisionAfterResolution {
            return AgentLaunchConfiguration(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf 'plan:\(Self.planMarkdown)\\n'; sleep 0.2; printf 'plan:\(Self.revisedPlanMarkdown)\\n'; sleep 5"
                ]
            )
        }
        return AgentLaunchConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'plan:\(Self.planMarkdown)\\n'; sleep 5"]
        )
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line == "prompt" {
            return [.interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?"))]
        }
        if line == "provider-plan-exit" {
            return [.interaction(AgentInteractionEvent(
                id: "provider-plan-exit",
                kind: .planModeExit,
                prompt: "ExitPlanMode",
                metadata: [
                    "tool_name": .string("ExitPlanMode"),
                    "tool_input": .object(["plan": .string(Self.planMarkdown)]),
                    "plan": .string(Self.planMarkdown)
                ]
            ))]
        }
        guard let text = line.removingPrefix("plan:") else {
            return []
        }
        return [.message(AgentMessageEvent(role: .assistant, text: text, metadata: Self.metadata(for: text)))]
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        await recorder.record(input)
        return Data("ok\n".utf8)
    }

    func reconfigure(context: AgentProviderReconfigureContext) async throws -> AgentProviderReconfigureResult {
        await recorder.record(context)
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

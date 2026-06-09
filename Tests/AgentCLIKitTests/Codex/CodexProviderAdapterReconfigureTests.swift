import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexProviderAdapterReconfigureTests: XCTestCase {
    func testRuntimeEventsAppliesCollaborationModeBeforeInitialPromptTurn() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            model: "model-a",
            effort: "high",
            permissionMode: "on-request",
            collaborationMode: .plan,
            initialPrompt: "Implement it"
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        let requestLog = await waitForRequestLog(transport) { log in
            log.map(\.method).contains("turn/start")
        }
        let settingsParams = try XCTUnwrap(requestLog.first { $0.method == "thread/settings/update" }?.params?.objectValue)
        let turnStartParams = try XCTUnwrap(requestLog.first { $0.method == "turn/start" }?.params?.objectValue)

        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "thread/settings/update", "turn/start"])
        XCTAssertEqual(settingsParams["threadId"], .string("thread-123"))
        XCTAssertEqual(settingsParams["cwd"], .string("/tmp/project"))
        XCTAssertEqual(settingsParams["model"], .string("model-a"))
        XCTAssertEqual(settingsParams["effort"], .string("high"))
        XCTAssertEqual(settingsParams["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(settingsParams["collaborationMode"], Self.collaborationModeValue(mode: "plan", model: "model-a", effort: "high"))
        XCTAssertEqual(turnStartParams["collaborationMode"], settingsParams["collaborationMode"])
        XCTAssertEqual(turnStartParams["input"], Self.inputValue("Implement it"))
    }

    func testReconfigureIdleThreadUsesThreadSettingsUpdateAndUpdatesBinding() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            model: "model-a"
        )
        let updatedConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/other-project"),
            model: "model-b",
            effort: "medium",
            permissionMode: "on-request",
            collaborationMode: .default
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()
        let result = try await adapter.reconfigure(context: reconfigureContext(currentConfig: spawnConfig, newConfig: updatedConfig))
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: updatedConfig, isTurnActive: false)
        )

        let requestLog = await transport.requestLog
        let settingsParams = try XCTUnwrap(requestLog.first { $0.method == "thread/settings/update" }?.params?.objectValue)
        let turnStartParams = try XCTUnwrap(requestLog.first { $0.method == "turn/start" }?.params?.objectValue)

        XCTAssertEqual(result, .appliedInPlace)
        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "thread/settings/update", "turn/start"])
        XCTAssertEqual(settingsParams["cwd"], .string("/tmp/other-project"))
        XCTAssertEqual(settingsParams["model"], .string("model-b"))
        XCTAssertEqual(settingsParams["collaborationMode"], Self.collaborationModeValue(mode: "default", model: "model-b", effort: "medium"))
        XCTAssertEqual(turnStartParams["cwd"], .string("/tmp/other-project"))
        XCTAssertEqual(turnStartParams["model"], .string("model-b"))
        XCTAssertEqual(turnStartParams["collaborationMode"], settingsParams["collaborationMode"])
    }

    func testReconfigureAndNextTurnCarrySpeedModeSettingsWhenSupported() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(
            transport: transport,
            featureSupportChecker: FixedCodexFeatureSupportChecker(supportsFastMode: true)
        ))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let updatedConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            speedMode: .standard
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()
        let result = try await adapter.reconfigure(context: reconfigureContext(currentConfig: spawnConfig, newConfig: updatedConfig))
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: updatedConfig, isTurnActive: false)
        )

        let requestLog = await transport.requestLog
        let settingsParams = try XCTUnwrap(requestLog.first { $0.method == "thread/settings/update" }?.params?.objectValue)
        let turnStartParams = try XCTUnwrap(requestLog.first { $0.method == "turn/start" }?.params?.objectValue)

        XCTAssertEqual(result, .appliedInPlace)
        XCTAssertEqual(settingsParams["config"], .object([
            "features": .object(["fast_mode": .bool(false)])
        ]))
        XCTAssertEqual(turnStartParams["config"], settingsParams["config"])
    }

    func testUnsupportedFastModeReconfigureFailsWithoutSettingsUpdate() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(
            transport: transport,
            featureSupportChecker: FixedCodexFeatureSupportChecker(supportsFastMode: false)
        ))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let updatedConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            speedMode: .fast
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()

        do {
            _ = try await adapter.reconfigure(context: reconfigureContext(currentConfig: spawnConfig, newConfig: updatedConfig))
            XCTFail("Expected unsupported fast mode to fail.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
            XCTAssertEqual(error.metadata["provider_id"], .string("codex"))
            XCTAssertEqual(error.metadata["capability"], .string("fast mode"))
        }

        let requestLog = await transport.requestLog
        XCTAssertNil(requestLog.first { $0.method == "thread/settings/update" })
    }

    func testReconfigureActiveTurnReturnsNextTurnRequiredWithoutSettingsUpdate() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            model: "model-a"
        )
        let updatedConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            model: "model-a",
            collaborationMode: .plan
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()
        let result = try await adapter.reconfigure(context: reconfigureContext(
            currentConfig: spawnConfig,
            newConfig: updatedConfig,
            isTurnActive: true
        ))

        let requestMethods = await transport.requestMethods

        XCTAssertEqual(result, .nextTurnRequired)
        XCTAssertEqual(requestMethods, ["initialize", "thread/start"])
    }

    func testReconfigureBindingActiveTurnReturnsNextTurnRequiredWithoutSettingsUpdate() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            model: "model-a"
        )
        let updatedConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            model: "model-a",
            collaborationMode: .plan
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        let result = try await adapter.reconfigure(context: reconfigureContext(currentConfig: spawnConfig, newConfig: updatedConfig))

        let requestMethods = await transport.requestMethods

        XCTAssertEqual(result, .nextTurnRequired)
        XCTAssertEqual(requestMethods, ["initialize", "thread/start", "turn/start"])
    }

    func testReconfigureCollaborationModeRequiresConcreteModel() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        let updatedConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            collaborationMode: .plan
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()

        do {
            _ = try await adapter.reconfigure(context: reconfigureContext(currentConfig: spawnConfig, newConfig: updatedConfig))
            XCTFail("Expected Codex collaboration mode without a model to fail.")
        } catch let error as AgentCLIError {
            guard case let .invalidInput(message) = error else {
                XCTFail("Expected invalidInput, got \(error).")
                return
            }
            XCTAssertTrue(message.contains("requires a concrete model"))
        }
    }

    private func configuration(
        transport: FakeCodexAppServerTransport,
        featureSupportChecker: any CodexFeatureSupportChecking = FixedCodexFeatureSupportChecker(supportsFastMode: false)
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            featureSupportChecker: featureSupportChecker,
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }

    private func runtimeContext(threadId: AgentSessionID, spawnConfig: AgentSpawnConfig) -> AgentProviderRuntimeContext {
        AgentProviderRuntimeContext(
            conversationId: "conversation",
            processToken: fixedProcessToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig
        )
    }

    private func inputContext(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        isTurnActive: Bool
    ) -> AgentProviderInputContext {
        AgentProviderInputContext(
            conversationId: "conversation",
            processToken: fixedProcessToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig,
            isTurnActive: isTurnActive
        )
    }

    private func reconfigureContext(
        currentConfig: AgentSpawnConfig,
        newConfig: AgentSpawnConfig,
        isTurnActive: Bool = false
    ) -> AgentProviderReconfigureContext {
        AgentProviderReconfigureContext(
            conversationId: "conversation",
            processToken: fixedProcessToken,
            providerSessionId: "thread-123",
            currentConfig: currentConfig,
            newConfig: newConfig,
            isTurnActive: isTurnActive
        )
    }

    private var fixedProcessToken: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    }

    private func waitForBinding() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private func waitForRequestLog(
        _ transport: FakeCodexAppServerTransport,
        matches: ([FakeCodexAppServerTransport.Request]) -> Bool
    ) async -> [FakeCodexAppServerTransport.Request] {
        for _ in 0..<100 {
            let requestLog = await transport.requestLog
            if matches(requestLog) {
                return requestLog
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await transport.requestLog
    }

    private static func collaborationModeValue(mode: String, model: String, effort: String?) -> JSONValue {
        var settings: [String: JSONValue] = [
            "model": .string(model),
            "developer_instructions": .null
        ]
        if let effort {
            settings["reasoning_effort"] = .string(effort)
        }
        return .object([
            "mode": .string(mode),
            "settings": .object(settings)
        ])
    }

    private static func inputValue(_ text: String) -> JSONValue {
        .array([.object([
            "type": .string("text"),
            "text": .string(text),
            "text_elements": .array([])
        ])])
    }
}

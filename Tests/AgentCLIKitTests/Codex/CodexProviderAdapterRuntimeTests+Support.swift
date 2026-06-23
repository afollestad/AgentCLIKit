import Foundation

@testable import AgentCLIKit

extension CodexProviderAdapterRuntimeTests {
    func configuration(
        transport: FakeCodexAppServerTransport,
        codexHomeDirectory: URL? = nil,
        featureSupportChecker: any CodexFeatureSupportChecking = FixedCodexFeatureSupportChecker(supportsFastMode: false)
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            codexHomeDirectory: codexHomeDirectory,
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            featureSupportChecker: featureSupportChecker,
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }

    func runtimeContext(threadId: AgentSessionID, spawnConfig: AgentSpawnConfig) -> AgentProviderRuntimeContext {
        runtimeContext(
            threadId: threadId,
            spawnConfig: spawnConfig,
            processToken: fixedProcessToken
        )
    }

    func runtimeContext(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        processToken: UUID
    ) -> AgentProviderRuntimeContext {
        AgentProviderRuntimeContext(
            conversationId: "conversation",
            processToken: processToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig
        )
    }

    func inputContext(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        isTurnActive: Bool,
        processToken: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    ) -> AgentProviderInputContext {
        AgentProviderInputContext(
            conversationId: "conversation",
            processToken: processToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig,
            isTurnActive: isTurnActive
        )
    }

    func interruptContext(threadId: AgentSessionID, spawnConfig: AgentSpawnConfig) -> AgentProviderInterruptContext {
        AgentProviderInterruptContext(
            conversationId: "conversation",
            processToken: fixedProcessToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig
        )
    }

    func turnNotificationParams(status: String) -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turn": .object([
                "id": .string("turn-1"),
                "status": .string(status),
                "items": .array([])
            ])
        ])
    }

    func emitRepresentativeNotifications(_ transport: FakeCodexAppServerTransport) async {
        await transport.emitNotification(method: "thread/status/changed", params: .object([
            "threadId": .string("thread-123"),
            "status": .object(["type": .string("active"), "activeFlags": .array([])])
        ]))
        await transport.emitNotification(method: "turn/started", params: turnNotificationParams(status: "inProgress"))
        await transport.emitNotification(method: "thread/settings/updated", params: .object([
            "threadId": .string("thread-123"),
            "threadSettings": .object([
                "approvalPolicy": .string("on-request"),
                "model": .string("model-a"),
                "modelProvider": .string("openai"),
                "effort": .string("medium"),
                "collaborationMode": .object(["mode": .string("plan")])
            ])
        ]))
        await transport.emitNotification(method: "turn/completed", params: turnNotificationParams(status: "completed"))
    }

    static var representativeSettingsMetadata: [String: JSONValue] {
        [
            "codex_method": .string("thread/settings/updated"),
            "codex_thread_id": .string("thread-123"),
            "codex_model": .string("model-a"),
            "codex_model_provider": .string("openai"),
            "codex_effort": .string("medium"),
            "codex_approval_policy": .string("on-request"),
            "codex_collaboration_mode": .object(["mode": .string("plan")])
        ]
    }

    static let planMarkdown = "# UX Polish Pass\n\n- Tighten the hero.\n- Verify the gallery."

    func waitForBinding() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    func waitForRequestLog(
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

    func waitForIncomingStreamCount(_ transport: FakeCodexAppServerTransport, count: Int) async -> Int {
        for _ in 0..<100 {
            let incomingStreamCount = await transport.incomingStreamCount
            if incomingStreamCount >= count {
                return incomingStreamCount
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await transport.incomingStreamCount
    }

    func tokenUsageParams() -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "total": .object([
                    "inputTokens": .number(10),
                    "outputTokens": .number(5),
                    "cachedInputTokens": .number(3),
                    "totalTokens": .number(15)
                ]),
                "last": .object([
                    "inputTokens": .number(10),
                    "outputTokens": .number(5),
                    "cachedInputTokens": .number(3),
                    "totalTokens": .number(15)
                ]),
                "modelContextWindow": .number(1000)
            ])
        ])
    }

    func writeCodexSessionPlan(codexHome: URL, threadId: String) throws {
        let sessionsDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("16", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let fileURL = sessionsDirectory.appendingPathComponent("rollout-2026-06-16T20-33-05-\(threadId).jsonl")
        let oldPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"" + threadId +
            "\",\"turn_id\":\"turn-0\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-0-plan\",\"text\":\"# Old Plan\"}}}"
        let completedPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"" + threadId +
            "\",\"turn_id\":\"turn-1\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-1-plan\",\"text\":\"" +
            Self.escapedPlanMarkdown + "\"},\"completed_at_ms\":1781660055673}}"
        try [oldPlanLine, completedPlanLine]
            .joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func collect(_ stream: AsyncStream<AgentProviderRuntimeEvent>, count: Int) async -> [AgentProviderRuntimeEvent] {
        var events: [AgentProviderRuntimeEvent] = []
        for await event in stream {
            events.append(event)
            if events.count >= count {
                break
            }
        }
        return events
    }

    private var fixedProcessToken: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    }

    private static let escapedPlanMarkdown = "# UX Polish Pass\\n\\n- Tighten the hero.\\n- Verify the gallery."
}

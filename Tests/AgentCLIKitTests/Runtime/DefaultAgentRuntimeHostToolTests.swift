import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeHostToolTests: XCTestCase {
    func testHostToolRegistrationPrecedesContextAwareLaunchAndShutdownCleansUp() async throws {
        let probe = HostToolRuntimeProbe()
        let hostToolServer = RecordingHostToolServer(probe: probe)
        let runtime = DefaultAgentRuntime(
            adapters: [ContextAwareHostToolAdapter(command: shell("sleep 5"), probe: probe)],
            hostToolServer: hostToolServer
        )

        try await runtime.spawn(conversationId: "conversation", config: hostToolConfig(toolName: "list_tasks"))

        let eventsBeforeShutdown = await probe.events
        let registeredTokens = await probe.registeredTokens
        let launchContexts = await probe.launchContexts
        XCTAssertEqual(eventsBeforeShutdown.prefix(2).map(\.kind), [.registered, .contextLaunch])
        XCTAssertEqual(registeredTokens.count, 1)
        XCTAssertEqual(launchContexts.count, 1)
        XCTAssertEqual(launchContexts.first?.processToken, registeredTokens.first)
        XCTAssertEqual(launchContexts.first?.hostToolEndpoint?.enabledToolNames, ["list_tasks"])

        await runtime.shutdown()

        let invalidatedTokens = await probe.invalidatedTokens
        let terminatedTokens = await probe.providerTerminatedTokens
        let shutdownCount = await probe.serverShutdownCount
        XCTAssertEqual(invalidatedTokens, registeredTokens)
        XCTAssertEqual(terminatedTokens, registeredTokens)
        XCTAssertEqual(shutdownCount, 1)
    }

    func testContextAwareLaunchFailureInvalidatesRegisteredHostTools() async {
        let probe = HostToolRuntimeProbe()
        let hostToolServer = RecordingHostToolServer(probe: probe)
        let adapter = ContextAwareHostToolAdapter(
            command: shell("sleep 5"),
            probe: probe,
            launchError: .invalidInput("launch failed")
        )
        let runtime = DefaultAgentRuntime(adapters: [adapter], hostToolServer: hostToolServer)

        do {
            try await runtime.spawn(conversationId: "conversation", config: hostToolConfig(toolName: "list_tasks"))
            XCTFail("Expected context-aware launch failure.")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .invalidInput("launch failed"))
        }

        let events = await probe.events
        let registeredTokens = await probe.registeredTokens
        let invalidatedTokens = await probe.invalidatedTokens
        let terminatedTokens = await probe.providerTerminatedTokens
        XCTAssertEqual(events.map(\.kind), [.registered, .contextLaunch, .invalidated, .providerTerminated])
        XCTAssertEqual(invalidatedTokens, registeredTokens)
        XCTAssertEqual(terminatedTokens, registeredTokens)

        await runtime.shutdown()
    }

    func testDestroyInvalidatesHostToolsWhileContextLaunchIsSuspended() async throws {
        let probe = HostToolRuntimeProbe()
        let launchGate = HostToolLaunchGate()
        let hostToolServer = RecordingHostToolServer(probe: probe)
        let runtime = DefaultAgentRuntime(
            adapters: [ContextAwareHostToolAdapter(command: shell("sleep 5"), probe: probe, launchGate: launchGate)],
            hostToolServer: hostToolServer
        )
        let config = hostToolConfig(toolName: "list_tasks")
        let spawnTask = Task {
            try await runtime.spawn(conversationId: "conversation", config: config)
        }
        await launchGate.waitUntilSuspended()

        await runtime.destroy(conversationId: "conversation")

        let registeredTokens = await probe.registeredTokens
        let invalidatedTokens = await probe.invalidatedTokens
        XCTAssertEqual(invalidatedTokens, registeredTokens)
        await launchGate.resume()
        do {
            try await spawnTask.value
            XCTFail("Expected the destroyed start to be cancelled.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Start was cancelled"))
        }
        await runtime.shutdown()
    }

    func testNonemptyHostToolsWithoutInjectedHandlerThrowsTypedErrorBeforeProviderLaunch() async {
        let probe = HostToolRuntimeProbe()
        let runtime = DefaultAgentRuntime(adapters: [
            ContextAwareHostToolAdapter(command: shell("sleep 5"), probe: probe)
        ])

        do {
            try await runtime.spawn(conversationId: "conversation", config: hostToolConfig(toolName: "list_tasks"))
            XCTFail("Expected missing host tool handling to fail the launch.")
        } catch {
            let expected = AgentCLIError.hostToolsUnavailable(
                reason: "No host tool handler was injected into the runtime."
            )
            XCTAssertEqual(error as? AgentCLIError, expected)
            XCTAssertEqual((error as? AgentCLIError)?.code, .hostToolsUnavailable)
        }

        let events = await probe.events
        let status = await runtime.status(conversationId: "conversation")
        XCTAssertEqual(events, [])
        XCTAssertNil(status)

        await runtime.shutdown()
    }

    func testIdleHostToolChangeRestartsAndInvalidatesPreviousRegistration() async throws {
        let probe = HostToolRuntimeProbe()
        let hostToolServer = RecordingHostToolServer(probe: probe)
        let runtime = DefaultAgentRuntime(
            adapters: [ContextAwareHostToolAdapter(command: shell("sleep 5"), probe: probe)],
            hostToolServer: hostToolServer
        )

        try await runtime.spawn(conversationId: "conversation", config: hostToolConfig(toolName: "list_tasks"))
        let result = try await runtime.reconfigure(
            conversationId: "conversation",
            config: hostToolConfig(toolName: "propose_task")
        )

        let registeredTokens = await probe.registeredTokens
        let invalidatedTokens = await probe.invalidatedTokens
        let launchContexts = await probe.launchContexts
        XCTAssertEqual(result, .restarted)
        XCTAssertEqual(registeredTokens.count, 2)
        XCTAssertEqual(launchContexts.compactMap { $0.hostToolEndpoint?.enabledToolNames }, [["list_tasks"], ["propose_task"]])
        XCTAssertTrue(invalidatedTokens.contains(registeredTokens[0]))

        await runtime.shutdown()

        let finalInvalidatedTokens = await probe.invalidatedTokens
        XCTAssertTrue(finalInvalidatedTokens.contains(registeredTokens[1]))
    }

    func testActiveHostToolChangeDefersWithoutRegisteringReplacement() async throws {
        let probe = HostToolRuntimeProbe()
        let hostToolServer = RecordingHostToolServer(probe: probe)
        let runtime = DefaultAgentRuntime(
            adapters: [ContextAwareHostToolAdapter(command: shell("sleep 5"), probe: probe)],
            hostToolServer: hostToolServer
        )

        try await runtime.spawn(
            conversationId: "conversation",
            config: hostToolConfig(toolName: "list_tasks", initialPrompt: "Start work")
        )
        let result = try await runtime.reconfigure(
            conversationId: "conversation",
            config: hostToolConfig(toolName: "propose_task")
        )

        let registeredTokens = await probe.registeredTokens
        let launchContexts = await probe.launchContexts
        XCTAssertEqual(result, .nextTurnRequired)
        XCTAssertEqual(registeredTokens.count, 1)
        XCTAssertEqual(launchContexts.count, 1)

        await runtime.shutdown()
    }

    func testWaitingHostToolChangeDefersWithoutRegisteringReplacement() async throws {
        let probe = HostToolRuntimeProbe()
        let hostToolServer = RecordingHostToolServer(probe: probe)
        let runtime = DefaultAgentRuntime(
            adapters: [ContextAwareHostToolAdapter(command: shell("sleep 5"), probe: probe)],
            hostToolServer: hostToolServer
        )

        try await runtime.spawn(conversationId: "conversation", config: hostToolConfig(toolName: "list_tasks"))
        await runtime.append(
            .interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?")),
            source: .runtime,
            conversationId: "conversation"
        )
        let result = try await runtime.reconfigure(
            conversationId: "conversation",
            config: hostToolConfig(toolName: "propose_task")
        )

        let registeredTokens = await probe.registeredTokens
        let launchContexts = await probe.launchContexts
        XCTAssertEqual(result, .nextTurnRequired)
        XCTAssertEqual(registeredTokens.count, 1)
        XCTAssertEqual(launchContexts.count, 1)

        await runtime.shutdown()
    }

    func testProviderOutputRedactsProcessScopedHostBearer() async throws {
        let probe = HostToolRuntimeProbe()
        let hostToolServer = RecordingHostToolServer(probe: probe, bearerToken: "sensitive-test-token")
        let runtime = DefaultAgentRuntime(
            adapters: [ContextAwareHostToolAdapter(command: shell("sleep 5"), probe: probe)],
            hostToolServer: hostToolServer
        )
        try await runtime.spawn(conversationId: "conversation", config: hostToolConfig(toolName: "list_tasks"))
        let registeredTokens = await probe.registeredTokens
        let processToken = try XCTUnwrap(registeredTokens.first)

        await runtime.consumeLine(
            "Authorization: Bearer sensitive-test-token",
            source: .stderr,
            conversationId: "conversation",
            processToken: processToken
        )
        let subscription = await runtime.subscribe(conversationId: "conversation", afterIndex: nil)
        var diagnosticMessage: String?
        for await envelope in subscription.events {
            if case let .diagnostic(diagnostic) = envelope.event,
               diagnostic.code == .providerStderr {
                diagnosticMessage = diagnostic.message
                break
            }
        }

        XCTAssertEqual(diagnosticMessage, "Authorization: Bearer <redacted>")
        await runtime.shutdown()
    }

    func testNaturalProcessExitInvalidatesHostToolRegistration() async throws {
        let probe = HostToolRuntimeProbe()
        let runtime = DefaultAgentRuntime(
            adapters: [ContextAwareHostToolAdapter(command: shell("exit 0"), probe: probe)],
            hostToolServer: RecordingHostToolServer(probe: probe)
        )

        try await runtime.spawn(conversationId: "conversation", config: hostToolConfig(toolName: "list_tasks"))
        for _ in 0..<100 {
            if !(await probe.invalidatedTokens).isEmpty {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let registeredTokens = await probe.registeredTokens
        let invalidatedTokens = await probe.invalidatedTokens
        let terminatedTokens = await probe.providerTerminatedTokens
        XCTAssertEqual(registeredTokens.count, 1)
        XCTAssertEqual(invalidatedTokens, registeredTokens)
        XCTAssertEqual(terminatedTokens, registeredTokens)

        await runtime.shutdown()
    }

    func testFailedReplacementInvalidatesNewRegistrationButPreservesOldRegistration() async throws {
        let probe = HostToolRuntimeProbe()
        let launches = LaunchSequence([
            shell("sleep 5"),
            AgentLaunchConfiguration(executable: "/definitely/missing/agentclikit-provider")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedHostToolAdapter(launches: launches, probe: probe)],
            hostToolServer: RecordingHostToolServer(probe: probe)
        )
        try await runtime.spawn(conversationId: "conversation", config: hostToolConfig(toolName: "list_tasks"))

        do {
            _ = try await runtime.reconfigure(
                conversationId: "conversation",
                config: hostToolConfig(toolName: "propose_task")
            )
            XCTFail("Expected replacement launch failure.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .commandLaunchFailed)
        }

        let registeredTokens = await probe.registeredTokens
        let invalidatedTokens = await probe.invalidatedTokens
        let status = await runtime.status(conversationId: "conversation")
        XCTAssertEqual(registeredTokens.count, 2)
        XCTAssertFalse(invalidatedTokens.contains(registeredTokens[0]))
        XCTAssertTrue(invalidatedTokens.contains(registeredTokens[1]))
        XCTAssertEqual(status?.state, .running)

        await runtime.shutdown()
    }

    private func hostToolConfig(toolName: String, initialPrompt: String? = nil) -> AgentSpawnConfig {
        AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            initialPrompt: initialPrompt,
            hostTools: [AgentHostToolDefinition(
                name: toolName,
                description: "A test host tool.",
                inputSchema: .object(["type": .string("object")])
            )]
        )
    }
}

private enum HostToolRuntimeEventKind: Equatable, Sendable {
    case registered
    case contextLaunch
    case legacyLaunch
    case providerTerminated
    case invalidated
    case serverShutdown
}

private struct HostToolRuntimeEvent: Equatable, Sendable {
    let kind: HostToolRuntimeEventKind
    let processToken: UUID?
}

private actor HostToolRuntimeProbe {
    private(set) var events: [HostToolRuntimeEvent] = []
    private(set) var launchContexts: [AgentProviderLaunchContext] = []

    var registeredTokens: [UUID] {
        tokens(for: .registered)
    }

    var providerTerminatedTokens: [UUID] {
        tokens(for: .providerTerminated)
    }

    var invalidatedTokens: [UUID] {
        tokens(for: .invalidated)
    }

    var serverShutdownCount: Int {
        events.filter { $0.kind == .serverShutdown }.count
    }

    func record(_ kind: HostToolRuntimeEventKind, processToken: UUID? = nil) {
        events.append(HostToolRuntimeEvent(kind: kind, processToken: processToken))
    }

    func recordLaunch(_ context: AgentProviderLaunchContext) {
        launchContexts.append(context)
        record(.contextLaunch, processToken: context.processToken)
    }

    private func tokens(for kind: HostToolRuntimeEventKind) -> [UUID] {
        events.compactMap { event in
            event.kind == kind ? event.processToken : nil
        }
    }
}

private actor RecordingHostToolServer: AgentHostToolServing {
    let probe: HostToolRuntimeProbe
    let bearerToken: String?

    init(probe: HostToolRuntimeProbe, bearerToken: String? = nil) {
        self.probe = probe
        self.bearerToken = bearerToken
    }

    func register(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        processToken: UUID,
        server: AgentHostToolServerMetadata,
        tools: [AgentHostToolDefinition]
    ) async throws -> AgentHostToolEndpoint {
        await probe.record(.registered, processToken: processToken)
        guard let url = URL(string: "http://127.0.0.1:1234/mcp/\(processToken.uuidString)") else {
            throw AgentCLIError.invalidInput("Could not construct the test host tool URL.")
        }
        return AgentHostToolEndpoint(
            serverName: server.name,
            url: url,
            bearerToken: bearerToken ?? "test-token-\(processToken.uuidString)",
            enabledToolNames: tools.map(\.name)
        )
    }

    func invalidate(processToken: UUID) async {
        await probe.record(.invalidated, processToken: processToken)
    }

    func shutdown() async {
        await probe.record(.serverShutdown)
    }
}

private actor HostToolLaunchGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        suspensionWaiters.forEach { $0.resume() }
        suspensionWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else {
            return
        }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private struct ContextAwareHostToolAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Context-aware", executableNames: ["context-aware"])
    let command: AgentLaunchConfiguration
    let probe: HostToolRuntimeProbe
    let launchError: AgentCLIError?
    let launchGate: HostToolLaunchGate?

    init(
        command: AgentLaunchConfiguration,
        probe: HostToolRuntimeProbe,
        launchError: AgentCLIError? = nil,
        launchGate: HostToolLaunchGate? = nil
    ) {
        self.command = command
        self.probe = probe
        self.launchError = launchError
        self.launchGate = launchGate
    }

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await probe.record(.legacyLaunch)
        return command
    }

    func makeLaunchConfiguration(context: AgentProviderLaunchContext) async throws -> AgentLaunchConfiguration {
        await probe.recordLaunch(context)
        await launchGate?.suspend()
        if let launchError {
            throw launchError
        }
        return command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func processDidTerminate(processToken: UUID) async {
        await probe.record(.providerTerminated, processToken: processToken)
    }
}

private struct SequencedHostToolAdapter: AgentProviderAdapter {
    let launches: LaunchSequence
    let probe: HostToolRuntimeProbe
    let definition = AgentProviderDefinition(id: .claude, displayName: "Sequenced", executableNames: ["sequenced"])

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await launches.next()
    }

    func makeLaunchConfiguration(context: AgentProviderLaunchContext) async throws -> AgentLaunchConfiguration {
        await probe.recordLaunch(context)
        return await launches.next()
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func processDidTerminate(processToken: UUID) async {
        await probe.record(.providerTerminated, processToken: processToken)
    }
}

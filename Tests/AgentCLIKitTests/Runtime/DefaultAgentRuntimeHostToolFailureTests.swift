import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeHostToolFailureTests: XCTestCase {
    private static let listenerFailureMessage = "Host tool listener stopped unexpectedly."

    func testListenerFailureEmitsReplacementRequiredDiagnostic() async throws {
        let hostToolServer = DiagnosticHostToolServer()
        let runtime = DefaultAgentRuntime(
            adapters: [DiagnosticHostToolAdapter(command: shell("sleep 5"))],
            hostToolServer: hostToolServer
        )
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: Self.hostToolConfig)
        let registeredTokens = await hostToolServer.registeredTokens
        let processToken = try XCTUnwrap(registeredTokens.first)
        let receivedDiagnostic = expectation(description: "Received host tool listener failure diagnostic")
        let diagnosticTask = Task { () -> AgentDiagnosticEvent? in
            for await envelope in subscription.events {
                guard case let .diagnostic(diagnostic) = envelope.event,
                      diagnostic.code == .hostToolServerUnavailable else {
                    continue
                }
                receivedDiagnostic.fulfill()
                return diagnostic
            }
            return nil
        }

        await hostToolServer.emitFailure(processToken: processToken)
        await fulfillment(of: [receivedDiagnostic], timeout: 1)
        diagnosticTask.cancel()
        let diagnostic = await diagnosticTask.value

        XCTAssertEqual(diagnostic?.severity, .error)
        XCTAssertEqual(diagnostic?.metadata["host_tools_unavailable"], .bool(true))
        XCTAssertEqual(diagnostic?.metadata["replacement_required"], .bool(true))
        await runtime.shutdown()
    }

    func testListenerFailureDuringInFlightStartThrowsHostToolsUnavailable() async throws {
        let hostToolServer = DiagnosticHostToolServer()
        let launchGate = DiagnosticHostToolLaunchGate()
        let runtime = DefaultAgentRuntime(
            adapters: [DiagnosticHostToolAdapter(command: shell("sleep 5"), launchGate: launchGate)],
            hostToolServer: hostToolServer
        )
        addTeardownBlock {
            await launchGate.resume()
            await runtime.shutdown()
        }
        let conversationId: AgentConversationID = "listener-failure"
        let config = Self.hostToolConfig
        let spawnTask = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await launchGate.waitUntilSuspended()
        let registeredTokens = await hostToolServer.registeredTokens
        let processToken = try XCTUnwrap(registeredTokens.first)

        await hostToolServer.emitFailure(processToken: processToken)

        let storedError = await waitForStartCancellationError(runtime)
        XCTAssertEqual(storedError, .hostToolsUnavailable(reason: Self.listenerFailureMessage))
        await launchGate.resume()
        do {
            try await spawnTask.value
            XCTFail("Expected the listener failure to cancel the in-flight start.")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .hostToolsUnavailable(reason: Self.listenerFailureMessage))
        }
    }

    func testDestroyOverridesInFlightHostToolFailureCancellationCause() async throws {
        let hostToolServer = DiagnosticHostToolServer()
        let launchGate = DiagnosticHostToolLaunchGate()
        let runtime = DefaultAgentRuntime(
            adapters: [DiagnosticHostToolAdapter(command: shell("sleep 5"), launchGate: launchGate)],
            hostToolServer: hostToolServer
        )
        addTeardownBlock {
            await launchGate.resume()
            await runtime.shutdown()
        }
        let conversationId: AgentConversationID = "destroy-ordering"
        let config = Self.hostToolConfig
        let spawnTask = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await launchGate.waitUntilSuspended()
        let registeredTokens = await hostToolServer.registeredTokens
        let processToken = try XCTUnwrap(registeredTokens.first)
        await hostToolServer.emitFailure(processToken: processToken)
        let storedError = await waitForStartCancellationError(runtime)
        XCTAssertEqual(storedError, .hostToolsUnavailable(reason: Self.listenerFailureMessage))

        await runtime.destroy(conversationId: conversationId)
        await launchGate.resume()

        do {
            try await spawnTask.value
            XCTFail("Expected destroy to cancel the in-flight start.")
        } catch {
            XCTAssertEqual(
                error as? AgentCLIError,
                .invalidInput("Start was cancelled for conversation '\(conversationId.rawValue)'.")
            )
        }
    }

    func testShutdownOverridesInFlightHostToolFailureCancellationCause() async throws {
        let hostToolServer = DiagnosticHostToolServer()
        let launchGate = DiagnosticHostToolLaunchGate()
        let runtime = DefaultAgentRuntime(
            adapters: [DiagnosticHostToolAdapter(command: shell("sleep 5"), launchGate: launchGate)],
            hostToolServer: hostToolServer
        )
        addTeardownBlock {
            await launchGate.resume()
            await runtime.shutdown()
        }
        let conversationId: AgentConversationID = "shutdown-ordering"
        let config = Self.hostToolConfig
        let spawnTask = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await launchGate.waitUntilSuspended()
        let registeredTokens = await hostToolServer.registeredTokens
        let processToken = try XCTUnwrap(registeredTokens.first)
        await hostToolServer.emitFailure(processToken: processToken)
        let storedError = await waitForStartCancellationError(runtime)
        XCTAssertEqual(storedError, .hostToolsUnavailable(reason: Self.listenerFailureMessage))

        await runtime.shutdown()
        await launchGate.resume()

        do {
            try await spawnTask.value
            XCTFail("Expected shutdown to cancel the in-flight start.")
        } catch {
            XCTAssertEqual(
                error as? AgentCLIError,
                .invalidInput("Start was cancelled for conversation '\(conversationId.rawValue)'.")
            )
        }
    }

    func testLateHostToolFailureCannotOverrideDestroyCancellationCause() async throws {
        let hostToolServer = DiagnosticHostToolServer()
        let launchGate = DiagnosticHostToolLaunchGate()
        let runtime = DefaultAgentRuntime(
            adapters: [DiagnosticHostToolAdapter(command: shell("sleep 5"), launchGate: launchGate)],
            hostToolServer: hostToolServer
        )
        addTeardownBlock {
            await launchGate.resume()
            await runtime.shutdown()
        }
        let conversationId: AgentConversationID = "destroy-before-listener-failure"
        let config = Self.hostToolConfig
        let spawnTask = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await launchGate.waitUntilSuspended()

        await runtime.destroy(conversationId: conversationId)
        await runtime.cancelStartForHostToolFailure(
            conversationId: conversationId,
            reason: Self.listenerFailureMessage
        )

        let cancellationErrors = await runtime.startCancellationErrors
        XCTAssertTrue(cancellationErrors.isEmpty)
        await launchGate.resume()
        do {
            try await spawnTask.value
            XCTFail("Expected destroy to remain the authoritative cancellation cause.")
        } catch {
            XCTAssertEqual(
                error as? AgentCLIError,
                .invalidInput("Start was cancelled for conversation '\(conversationId.rawValue)'.")
            )
        }
    }

    private func waitForStartCancellationError(
        _ runtime: DefaultAgentRuntime
    ) async -> AgentCLIError? {
        for _ in 0..<100 {
            let errors = await runtime.startCancellationErrors
            if let error = errors.values.first {
                return error
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private static let hostToolConfig = AgentSpawnConfig(
        providerId: .claude,
        workingDirectory: FileManager.default.temporaryDirectory,
        hostTools: [AgentHostToolDefinition(
            name: "list_tasks",
            description: "A test host tool.",
            inputSchema: .object(["type": .string("object")])
        )]
    )
}

private actor DiagnosticHostToolServer: AgentHostToolServing {
    private(set) var registeredTokens: [UUID] = []
    private var failureContinuation: AsyncStream<AgentHostToolServerFailure>.Continuation?

    func register(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        processToken: UUID,
        server: AgentHostToolServerMetadata,
        tools: [AgentHostToolDefinition]
    ) async throws -> AgentHostToolEndpoint {
        registeredTokens.append(processToken)
        guard let url = URL(string: "http://127.0.0.1:1234/mcp/diagnostic") else {
            throw AgentCLIError.invalidInput("Could not construct the test host tool URL.")
        }
        return AgentHostToolEndpoint(
            serverName: server.name,
            url: url,
            bearerToken: "test-token",
            enabledToolNames: tools.map(\.name)
        )
    }

    func failures() async -> AsyncStream<AgentHostToolServerFailure> {
        let stream = AsyncStream<AgentHostToolServerFailure>.makeStream()
        failureContinuation = stream.continuation
        return stream.stream
    }

    func emitFailure(processToken: UUID) {
        failureContinuation?.yield(AgentHostToolServerFailure(
            processTokens: [processToken],
            message: "Host tool listener stopped unexpectedly."
        ))
    }

    func invalidate(processToken: UUID) async {}

    func shutdown() async {
        failureContinuation?.finish()
        failureContinuation = nil
    }
}

private struct DiagnosticHostToolAdapter: AgentProviderAdapter {
    let command: AgentLaunchConfiguration
    let launchGate: DiagnosticHostToolLaunchGate?
    let definition = AgentProviderDefinition(id: .claude, displayName: "Diagnostic", executableNames: ["diagnostic"])

    init(
        command: AgentLaunchConfiguration,
        launchGate: DiagnosticHostToolLaunchGate? = nil
    ) {
        self.command = command
        self.launchGate = launchGate
    }

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func makeLaunchConfiguration(context: AgentProviderLaunchContext) async throws -> AgentLaunchConfiguration {
        await launchGate?.suspend()
        return command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

private actor DiagnosticHostToolLaunchGate {
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

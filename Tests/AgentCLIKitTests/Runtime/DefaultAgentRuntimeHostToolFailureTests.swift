import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeHostToolFailureTests: XCTestCase {
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
    let definition = AgentProviderDefinition(id: .claude, displayName: "Diagnostic", executableNames: ["diagnostic"])

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func makeLaunchConfiguration(context: AgentProviderLaunchContext) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

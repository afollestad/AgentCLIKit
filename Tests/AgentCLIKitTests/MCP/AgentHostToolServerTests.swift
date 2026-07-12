import Foundation
import XCTest

@testable import AgentCLIKit

final class AgentHostToolServerTests: XCTestCase {
    func testLiveInitializeListAndCallRoundTripUsesTrustedRegistrationContext() async throws {
        let calls = AgentHostToolCallRecorder()
        let processToken = UUID()
        let server = DefaultAgentHostToolServer(handling: AgentHostToolHandling { context, call in
            await calls.record(context: context, call: call)
            return AgentHostToolResult(
                text: "Proposal opened",
                structuredContent: .object(["status": .string("pending_confirmation")])
            )
        })
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await server.register(
            conversationId: "trusted-conversation",
            providerId: .codex,
            processToken: processToken,
            server: AgentHostToolServerMetadata(
                name: "alveary_host",
                title: "Alveary",
                instructions: "Open a native proposal before changing schedules."
            ),
            tools: [Self.proposalTool]
        )

        let initialize = try await Self.initialize(endpoint)
        let list = try await Self.post(
            endpoint,
            body: Self.request(id: "list-1", method: "tools/list", parameters: [:])
        )
        let arguments: [String: Any] = [
            "action": "create",
            "conversation_id": "untrusted-conversation",
            "provider_id": "claude",
            "process_token": UUID().uuidString
        ]
        let call = try await Self.post(
            endpoint,
            body: Self.request(
                id: "call-1",
                method: "tools/call",
                parameters: ["name": "propose_scheduled_task", "arguments": arguments]
            )
        )
        let recorded = await calls.values()

        XCTAssertEqual(initialize.statusCode, 200)
        XCTAssertNotNil(initialize.jsonObject?["result"] as? [String: Any])
        try Self.assertListedProposalTool(list)
        try Self.assertProposalCallResult(call)
        Self.assertTrustedCall(recorded, processToken: processToken)
    }

    func testRouteTokenHostAndOriginRejectBeforeMalformedJSONIsParsed() async throws {
        let server = DefaultAgentHostToolServer(handling: Self.echoHandling)
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server)
        let malformedBody = Data("{malformed".utf8)
        let missingURL = endpoint.url.appendingPathExtension("missing")

        let wrongRoute = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            url: missingURL,
            body: malformedBody
        )
        let wrongToken = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            body: malformedBody,
            bearerToken: "wrong-token"
        )
        let wrongOrigin = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            body: malformedBody,
            headers: ["Origin": "https://attacker.example"]
        )
        let wrongHost = try await AgentHostToolHTTPTestClient.sendRaw(
            to: endpoint,
            body: malformedBody,
            hostHeader: "attacker.example"
        )

        XCTAssertEqual(wrongRoute.statusCode, 404)
        XCTAssertEqual(wrongToken.statusCode, 401)
        XCTAssertEqual(wrongToken.headers["www-authenticate"], "Bearer")
        XCTAssertEqual(wrongOrigin.statusCode, 403)
        XCTAssertEqual(wrongHost.statusCode, 421)
    }

    func testHTTPValidationRejectsContentAcceptMethodProtocolAndOversizedBody() async throws {
        let server = DefaultAgentHostToolServer(
            handling: Self.echoHandling,
            configuration: DefaultAgentHostToolServer.Configuration(maxBodyBytes: 512)
        )
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server)
        let initializeBody = try Self.initializeRequest()

        let contentType = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            body: initializeBody,
            headers: ["Content-Type": "text/plain"]
        )
        let accept = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            body: initializeBody,
            headers: ["Accept": "text/plain"]
        )
        let method = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            method: "GET"
        )
        let protocolVersion = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            body: Self.request(id: "list-1", method: "tools/list", parameters: [:]),
            headers: ["MCP-Protocol-Version": "1900-01-01"]
        )
        let oversizedBody = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            body: Data(repeating: 0x20, count: 513)
        )

        XCTAssertEqual(contentType.statusCode, 415)
        XCTAssertEqual(accept.statusCode, 406)
        XCTAssertEqual(method.statusCode, 405)
        XCTAssertEqual(method.headers["allow"], "POST")
        XCTAssertEqual(protocolVersion.statusCode, 400)
        XCTAssertEqual(oversizedBody.statusCode, 413)
    }

    func testRegistrationRejectsDuplicateToolNames() async {
        let server = DefaultAgentHostToolServer(handling: Self.echoHandling)
        addTeardownBlock { await server.shutdown() }

        do {
            _ = try await server.register(
                conversationId: "conversation",
                providerId: .claude,
                processToken: UUID(),
                server: AgentHostToolServerMetadata(),
                tools: [Self.proposalTool, Self.proposalTool]
            )
            XCTFail("Expected duplicate host tool names to fail registration.")
        } catch {
            XCTAssertEqual(
                error as? AgentCLIError,
                .invalidInput("Duplicate host tool name 'propose_scheduled_task'.")
            )
        }
    }

    func testRegistrationRejectsServerNamesThatCannotFormOneCodexConfigSegment() async {
        let server = DefaultAgentHostToolServer(handling: Self.echoHandling)
        addTeardownBlock { await server.shutdown() }

        do {
            _ = try await server.register(
                conversationId: "conversation",
                providerId: .codex,
                processToken: UUID(),
                server: AgentHostToolServerMetadata(name: "company.host"),
                tools: [Self.proposalTool]
            )
            XCTFail("Expected dotted host tool server names to fail registration.")
        } catch {
            XCTAssertEqual(
                error as? AgentCLIError,
                .invalidInput("Host tool server names must be 1 to 128 ASCII letters, numbers, underscores, or hyphens.")
            )
        }
    }

    func testRegistrationRequiresObjectRootInputAndOutputSchemas() async {
        let server = DefaultAgentHostToolServer(handling: Self.echoHandling)
        addTeardownBlock { await server.shutdown() }
        let invalidInput = AgentHostToolDefinition(
            name: "invalid_input",
            description: "Invalid input schema",
            inputSchema: .object(["properties": .object([:])])
        )
        let invalidOutput = AgentHostToolDefinition(
            name: "invalid_output",
            description: "Invalid output schema",
            inputSchema: .object(["type": .string("object")]),
            outputSchema: .object(["type": .string("string")])
        )

        await Self.assertRegistrationFails(
            server: server,
            tool: invalidInput,
            message: "Host tool 'invalid_input' input schema must declare root type 'object'."
        )
        await Self.assertRegistrationFails(
            server: server,
            tool: invalidOutput,
            message: "Host tool 'invalid_output' output schema must declare root type 'object'."
        )
    }

    func testInvalidationRemovesRouteAndShutdownRejectsNewRegistrations() async throws {
        let processToken = UUID()
        let server = DefaultAgentHostToolServer(handling: Self.echoHandling)
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server, processToken: processToken)

        await server.invalidate(processToken: processToken)
        let invalidated = try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            body: try Self.initializeRequest()
        )
        await server.shutdown()

        XCTAssertEqual(invalidated.statusCode, 404)
        do {
            _ = try await Self.register(server: server)
            XCTFail("Expected a shut down host tool server to reject registration.")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .invalidInput("Host tool server has shut down."))
        }
    }

    static let protocolVersion = "2025-06-18"

    static let echoHandling = AgentHostToolHandling { _, call in
        AgentHostToolResult(text: call.name)
    }

    private static let proposalTool = AgentHostToolDefinition(
        name: "propose_scheduled_task",
        title: "Schedule a task",
        description: "Open a native confirmation proposal for an explicit scheduling request.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["action": .object(["type": .string("string")])]),
            "required": .array([.string("action")]),
            "additionalProperties": .bool(false)
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object(["status": .object(["type": .string("string")])])
        ]),
        annotations: AgentHostToolAnnotations(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    static func simpleTool(named name: String) -> AgentHostToolDefinition {
        AgentHostToolDefinition(
            name: name,
            description: "Test tool",
            inputSchema: .object(["type": .string("object")])
        )
    }

    private static func assertRegistrationFails(
        server: DefaultAgentHostToolServer,
        tool: AgentHostToolDefinition,
        message: String
    ) async {
        do {
            _ = try await server.register(
                conversationId: "conversation",
                providerId: .claude,
                processToken: UUID(),
                server: AgentHostToolServerMetadata(),
                tools: [tool]
            )
            XCTFail("Expected invalid host tool schema to fail registration.")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .invalidInput(message))
        }
    }

    static func register(
        server: DefaultAgentHostToolServer,
        processToken: UUID = UUID()
    ) async throws -> AgentHostToolEndpoint {
        try await server.register(
            conversationId: "conversation",
            providerId: .claude,
            processToken: processToken,
            server: AgentHostToolServerMetadata(),
            tools: [simpleTool(named: "echo")]
        )
    }

    static func initialize(_ endpoint: AgentHostToolEndpoint) async throws -> AgentHostToolHTTPTestResponse {
        let response = try await post(endpoint, body: initializeRequest(), includeProtocolVersion: false)
        guard response.statusCode == 200 else {
            return response
        }
        let initialized = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ])
        let initializedResponse = try await post(endpoint, body: initialized)
        XCTAssertEqual(initializedResponse.statusCode, 202)
        return response
    }

    static func initializeRequest() throws -> Data {
        try request(
            id: "initialize-1",
            method: "initialize",
            parameters: [
                "protocolVersion": protocolVersion,
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "AgentCLIKitTests", "version": "1.0"]
            ]
        )
    }

    static func call(
        _ endpoint: AgentHostToolEndpoint,
        id: String,
        toolName: String
    ) async throws -> AgentHostToolHTTPTestResponse {
        try await post(
            endpoint,
            body: request(
                id: id,
                method: "tools/call",
                parameters: ["name": toolName, "arguments": [:] as [String: Any]]
            )
        )
    }

    private static func assertListedProposalTool(_ response: AgentHostToolHTTPTestResponse) throws {
        XCTAssertEqual(response.statusCode, 200)
        let result = try XCTUnwrap(response.jsonObject?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String, "propose_scheduled_task")
        XCTAssertEqual(tools.first?["title"] as? String, "Schedule a task")
        let annotations = try XCTUnwrap(tools.first?["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
        XCTAssertEqual(annotations["idempotentHint"] as? Bool, true)
        XCTAssertEqual(annotations["openWorldHint"] as? Bool, false)
    }

    private static func assertProposalCallResult(_ response: AgentHostToolHTTPTestResponse) throws {
        XCTAssertEqual(response.statusCode, 200)
        let result = try XCTUnwrap(response.jsonObject?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Proposal opened")
        let structuredContent = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structuredContent["status"] as? String, "pending_confirmation")
    }

    private static func assertTrustedCall(
        _ values: [AgentHostToolCallRecorder.Value],
        processToken: UUID
    ) {
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.context.conversationId, "trusted-conversation")
        XCTAssertEqual(values.first?.context.providerId, .codex)
        XCTAssertEqual(values.first?.context.processToken, processToken)
        XCTAssertEqual(values.first?.context.requestId, "string:call-1")
        XCTAssertEqual(values.first?.call.name, "propose_scheduled_task")
        XCTAssertEqual(values.first?.call.arguments["conversation_id"], .string("untrusted-conversation"))
    }

    static func post(
        _ endpoint: AgentHostToolEndpoint,
        body: Data,
        includeProtocolVersion: Bool = true
    ) async throws -> AgentHostToolHTTPTestResponse {
        var headers = [String: String]()
        if includeProtocolVersion {
            headers["MCP-Protocol-Version"] = protocolVersion
        }
        return try await AgentHostToolHTTPTestClient.send(
            to: endpoint,
            body: body,
            headers: headers
        )
    }

    static func request(
        id: String,
        method: String,
        parameters: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": parameters
        ])
    }
}

private actor AgentHostToolCallRecorder {
    struct Value: Sendable {
        let context: AgentHostToolCallContext
        let call: AgentHostToolCall
    }

    private var recordedValues = [Value]()

    func record(context: AgentHostToolCallContext, call: AgentHostToolCall) {
        recordedValues.append(Value(context: context, call: call))
    }

    func values() -> [Value] {
        recordedValues
    }
}

import XCTest

@testable import AgentCLIKit

extension AgentHostToolServerTests {
    func testHandlerTimeoutAndOutputLimitReturnHandledToolErrors() async throws {
        let server = DefaultAgentHostToolServer(
            handling: AgentHostToolHandling { _, call in
                if call.name == "slow_tool" {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return AgentHostToolResult(text: "Late response")
                }
                return AgentHostToolResult(text: String(repeating: "x", count: 10_000))
            },
            configuration: DefaultAgentHostToolServer.Configuration(
                maxOutputBytes: 2_000,
                toolTimeoutNanoseconds: 5_000_000
            )
        )
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await server.register(
            conversationId: "conversation",
            providerId: .claude,
            processToken: UUID(),
            server: AgentHostToolServerMetadata(),
            tools: [Self.simpleTool(named: "slow_tool"), Self.simpleTool(named: "large_tool")]
        )
        _ = try await Self.initialize(endpoint)

        let timeout = try await Self.call(endpoint, id: "slow-1", toolName: "slow_tool")
        let oversized = try await Self.call(endpoint, id: "large-1", toolName: "large_tool")
        let timeoutResult = try XCTUnwrap(timeout.jsonObject?["result"] as? [String: Any])
        let timeoutContent = try XCTUnwrap(timeoutResult["content"] as? [[String: Any]])
        let oversizedResult = try XCTUnwrap(oversized.jsonObject?["result"] as? [String: Any])
        let oversizedContent = try XCTUnwrap(oversizedResult["content"] as? [[String: Any]])

        XCTAssertEqual(timeout.statusCode, 200)
        XCTAssertEqual(timeoutResult["isError"] as? Bool, true)
        XCTAssertEqual(timeoutContent.first?["text"] as? String, "Host tool call timed out.")
        XCTAssertEqual(oversized.statusCode, 200)
        XCTAssertEqual(oversizedResult["isError"] as? Bool, true)
        XCTAssertEqual(
            oversizedContent.first?["text"] as? String,
            "Host tool output exceeded the configured size limit."
        )
    }

    func testInvalidationCancelsRunningHostHandler() async throws {
        let handlerStarted = expectation(description: "handler started")
        let handlerCancelled = expectation(description: "handler cancelled")
        let processToken = UUID()
        let server = DefaultAgentHostToolServer(handling: AgentHostToolHandling { _, _ in
            handlerStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return AgentHostToolResult(text: "Unexpected completion")
            } catch {
                handlerCancelled.fulfill()
                return AgentHostToolResult(text: "Cancelled", isError: true)
            }
        })
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server, processToken: processToken)
        _ = try await Self.initialize(endpoint)
        async let response = Self.call(endpoint, id: "cancel-1", toolName: "echo")

        await fulfillment(of: [handlerStarted], timeout: 1)
        await server.invalidate(processToken: processToken)
        await fulfillment(of: [handlerCancelled], timeout: 1)
        _ = try await response
    }

    func testEscapingExpansionStillReturnsValidBoundedMCPResponse() async throws {
        let output = String(repeating: "\"\\\n", count: 120)
        let server = DefaultAgentHostToolServer(
            handling: AgentHostToolHandling { _, _ in AgentHostToolResult(text: output) },
            configuration: DefaultAgentHostToolServer.Configuration(maxOutputBytes: 512)
        )
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server)
        _ = try await Self.initialize(endpoint)

        let response = try await Self.call(endpoint, id: "escaping-1", toolName: "echo")
        let result = try XCTUnwrap(response.jsonObject?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(content.first?["text"] as? String, output)
    }

    func testUnknownToolNameIsNotReflectedPastOutputLimit() async throws {
        let server = DefaultAgentHostToolServer(
            handling: Self.echoHandling,
            configuration: DefaultAgentHostToolServer.Configuration(maxOutputBytes: 512)
        )
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server)
        _ = try await Self.initialize(endpoint)

        let response = try await Self.call(
            endpoint,
            id: "unknown-1",
            toolName: String(repeating: "x", count: 1_000)
        )
        let result = try XCTUnwrap(response.jsonObject?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(content.first?["text"] as? String, "Unknown host tool.")
    }

    func testNonObjectStructuredContentBecomesHandledToolError() async throws {
        let server = DefaultAgentHostToolServer(handling: AgentHostToolHandling { _, _ in
            AgentHostToolResult(text: "Invalid", structuredContent: .string("not-an-object"))
        })
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server)
        _ = try await Self.initialize(endpoint)

        let response = try await Self.call(endpoint, id: "structured-1", toolName: "echo")
        let result = try XCTUnwrap(response.jsonObject?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(content.first?["text"] as? String, "Host tool structured content must be a JSON object.")
        XCTAssertNil(result["structuredContent"])
    }

    func testNonFiniteStructuredContentBecomesHandledToolError() async throws {
        let server = DefaultAgentHostToolServer(handling: AgentHostToolHandling { _, _ in
            AgentHostToolResult(
                text: "Invalid",
                structuredContent: .object(["value": .number(.nan)])
            )
        })
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server)
        _ = try await Self.initialize(endpoint)

        let response = try await Self.call(endpoint, id: "non-finite-1", toolName: "echo")
        let result = try XCTUnwrap(response.jsonObject?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(content.first?["text"] as? String, "Host tool structured content could not be encoded.")
        XCTAssertNil(result["structuredContent"])
    }
}

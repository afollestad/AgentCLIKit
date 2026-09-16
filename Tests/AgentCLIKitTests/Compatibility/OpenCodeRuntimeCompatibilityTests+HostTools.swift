import XCTest

@testable import AgentCLIKit

extension OpenCodeRuntimeCompatibilityTests {
    func testHostMCPInjectionPreservesPermissionOrderAndIsolatesGenerationCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("opencode.jsonc")
        let prefix = """
        {
          // Later permission rules must retain their position.
          "permission": {"*":"ask", "bash":{"*":"ask", "ls*":"allow", "ls sensitive*":"deny"}},
          "mcp":
        """
        let suffix = """
        ,
          "model":"alpha/family/model",
        }
        """
        let inline = prefix + #"{"user":{"type":"remote","url":"https://example.com/mcp","oauth":true}}"# + suffix
        try inline.write(to: file, atomically: true, encoding: .utf8)
        let client = OpenCodeClient(configuration: .init(executablePath: "/test/opencode"))
        let config = AgentSpawnConfig(
            harnessId: .opencode, workingDirectory: directory,
            environment: ["OPENCODE_CONFIG_CONTENT": inline, "OPENCODE_CONFIG": file.path]
        )
        let first = try hostEndpoint(suffix: "first", token: "secret-first-generation")
        let second = try hostEndpoint(suffix: "second", token: "secret-second-generation")
        let firstConfig = try await client.serverConfiguration(config: config, endpoint: first)
        let secondConfig = try await client.serverConfiguration(config: config, endpoint: second)
        let firstText = try XCTUnwrap(firstConfig.environment["OPENCODE_CONFIG_CONTENT"])
        let secondText = try XCTUnwrap(secondConfig.environment["OPENCODE_CONFIG_CONTENT"])
        for text in [firstText, secondText] {
            XCTAssertTrue(text.hasPrefix(prefix))
            XCTAssertTrue(text.hasSuffix(suffix))
            let document = try OpenCodeJSONCDocument(data: Data(text.utf8))
            XCTAssertEqual(document.root["mcp"]?[oc: "user"]?[oc: "oauth"], .bool(true))
            XCTAssertEqual(document.root["mcp"]?[oc: "agentclikit_host"]?[oc: "oauth"], .bool(false))
        }
        XCTAssertTrue(firstText.contains(first.bearerToken))
        XCTAssertFalse(firstText.contains(second.bearerToken))
        XCTAssertTrue(secondText.contains(second.bearerToken))
        XCTAssertFalse(secondText.contains(first.bearerToken))
        XCTAssertFalse(secondText.contains(first.url.absoluteString))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), inline)
        await client.shutdown()
    }

    func testHostEndpointCredentialsAreRedactedFromRuntimeDiagnostics() async throws {
        let transport = OpenCodeCompatibilityTransport()
        let adapter = OpenCodeHarnessAdapter(configuration: .init(executablePath: "/test/opencode", makeTransport: { _ in transport }))
        let endpoint = try hostEndpoint(suffix: "private-route", token: "private-token-1234")
        let config = AgentSpawnConfig(
            harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory,
            hostTools: [AgentHostToolDefinition(name: "host_tool", description: "Fixture", inputSchema: .object(["type": .string("object")]))]
        )
        let token = UUID()
        _ = try await adapter.makeLaunchConfiguration(context: AgentHarnessLaunchContext(
            conversationId: "private-conversation", processToken: token, spawnConfig: config, resumedSession: nil, hostToolEndpoint: endpoint
        ))
        let stream = await adapter.runtimeEvents(context: AgentHarnessRuntimeContext(
            conversationId: "private-conversation", processToken: token, harnessSessionId: "ses_current", spawnConfig: config
        ))
        let events = OpenCodeCompatibilityEvents()
        let consumer = Task { await events.consume(stream) }
        await transport.emit(.object([
            "type": .string("session.error"), "properties": .object([
                "sessionID": .string("ses_current"), "error": .object([
                    "name": .string("FixtureError"),
                    "data": .object(["message": .string("Endpoint \(endpoint.url.absoluteString) used Bearer \(endpoint.bearerToken)")])
                ])
            ])
        ]))
        let diagnosed = await openCodeWaitUntil {
            await events.values.contains { if case .diagnostic = $0 { return true }; return false }
        }
        XCTAssertTrue(diagnosed)
        await adapter.shutdownHarnessResources()
        await consumer.value
        let values = await events.values
        let encoded = try XCTUnwrap(String(bytes: JSONEncoder().encode(values), encoding: .utf8))
        XCTAssertFalse(encoded.contains(endpoint.bearerToken))
        XCTAssertFalse(encoded.contains(endpoint.url.absoluteString))
        XCTAssertTrue(encoded.contains("FixtureError"))
    }

    func testDisconnectedProviderAndDisabledVariantRejectBeforePromptMutation() async throws {
        for (model, effort) in [("disconnected/family/model", nil), ("alpha/family/model", "hidden")] as [(String, String?)] {
            let fixture = OpenCodeCompatibilityFixture(config: AgentSpawnConfig(
                harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory, model: model, effort: effort
            ))
            _ = try await fixture.launch()
            do {
                try await fixture.send(.userMessage(AgentMessageInput(text: "Must be rejected")))
                XCTFail("An unavailable model or variant must fail")
            } catch let error as AgentCLIError {
                guard case .invalidInput = error else { return XCTFail("Expected invalid input, got \(error)") }
            }
            await fixture.stop()
            let requests = await fixture.transport.requests
            XCTAssertFalse(requests.contains { $0.path.hasSuffix("/prompt_async") })
        }
    }

    private func hostEndpoint(suffix: String, token: String) throws -> AgentHostToolEndpoint {
        AgentHostToolEndpoint(
            serverName: "agentclikit_host", url: try XCTUnwrap(URL(string: "http://127.0.0.1:43210/mcp/\(suffix)")),
            bearerToken: token, enabledToolNames: ["host_tool"]
        )
    }
}

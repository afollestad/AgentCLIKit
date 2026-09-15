import XCTest

@testable import AgentCLIKit

extension ClaudeHarnessAdapterTests {
    func testInitializerAcceptsHostOwnedApprovalPolicyStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let adapter = ClaudeHarnessAdapter(approvalPolicyStore: approvalPolicyStore, hookSupportDirectory: directory)
        addTeardownBlock {
            await adapter.shutdownHarnessResources()
            try? FileManager.default.removeItem(at: directory)
        }
        let launch = try await adapter.prepareLaunchConfiguration(
            AgentLaunchConfiguration(executable: "/usr/bin/env", arguments: ["claude"]),
            spawnConfig: AgentSpawnConfig(harnessId: .claude, workingDirectory: directory, permissionMode: "default"),
            conversationId: "conversation",
            processToken: UUID()
        )
        let request = try approvalHookRequest(from: launch, toolUseID: "without-grant")
        let withoutGrant = try await sendApprovalHook(request)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: withoutGrant), .deferDecision)

        // Mutate the host's store after launch preparation so a copied/default store cannot satisfy the assertion.
        let approvalRequest = AgentSessionApprovalRequest(
            harnessId: .claude,
            conversationId: "conversation",
            sessionId: "session-123",
            toolName: "Bash",
            toolInput: .object(["command": .string("git add Package.swift")])
        )
        let grant = try XCTUnwrap(approvalRequest.sessionApprovalGrant(for: .group))
        _ = await approvalPolicyStore.recordSessionApproval(grant)

        let withGrant = try await sendApprovalHook(approvalHookRequest(from: launch, toolUseID: "with-grant"))
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: withGrant), .allow)
    }

    private func approvalHookRequest(from launch: AgentLaunchConfiguration, toolUseID: String) throws -> URLRequest {
        let settingsIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "--settings"))
        let data = try Data(contentsOf: URL(fileURLWithPath: launch.arguments[settingsIndex + 1]))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let matchers = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let transports = try XCTUnwrap(matchers.first?["hooks"] as? [[String: Any]])
        let transport = try XCTUnwrap(transports.first)
        let urlString = try XCTUnwrap(transport["url"] as? String)
        let variables = try XCTUnwrap(transport["allowedEnvVars"] as? [String])
        let variable = try XCTUnwrap(variables.first)
        let token = try XCTUnwrap(launch.environment[variable])
        var request = URLRequest(url: try XCTUnwrap(URL(string: urlString)))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "session_id": .string("session-123"),
            "tool_name": .string("Bash"),
            "tool_use_id": .string(toolUseID),
            "tool_input": .object(["command": .string("git add Sources/App.swift")])
        ]))
        return request
    }

    private func sendApprovalHook(_ request: URLRequest) async throws -> AgentHookResponse {
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        let response = try XCTUnwrap(urlResponse as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)
        return AgentHookResponse(statusCode: response.statusCode, body: try JSONDecoder().decode(JSONValue.self, from: data))
    }
}

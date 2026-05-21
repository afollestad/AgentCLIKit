import Foundation
import XCTest

@testable import AgentCLIKit

final class ClaudeHookHTTPListenerTests: XCTestCase {
    func testHTTPHookRequestAcceptsDuplicateHeadersWithoutTrapping() throws {
        let body = #"{"tool_name":"Edit","tool_use_id":"tool-1"}"#
        let rawRequest = """
        POST /claude/hooks/pre-tool-use?conversation_id=conversation&conversation_id=other HTTP/1.1\r
        Host: 127.0.0.1\r
        X-Duplicate: one\r
        X-Duplicate: two\r
        Authorization: Bearer token\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """

        let request = try XCTUnwrap(HTTPHookRequest(buffer: Data(rawRequest.utf8), maxBodyBytes: 1_000_000))

        XCTAssertEqual(request.path, "/claude/hooks/pre-tool-use")
        XCTAssertEqual(request.query["conversation_id"], "conversation")
        XCTAssertEqual(request.bearerToken, "token")
        XCTAssertEqual(request.body, Data(body.utf8))
    }

    func testHookListenerStartsOnEphemeralLoopbackPortAndRoutesRequest() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let token = await tokenStore.issue(validFor: 60)
        let listener = ClaudeHookHTTPListener(server: server)
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let response = try await postHook(port: port, token: token.value, body: #"{"tool_name":"Edit","tool_use_id":"tool-1"}"#)
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertEqual(pending.first?.approvalRequest?.operation, "Edit")
    }

    func testHookListenerDeniesInvalidTokenWithSuccessStatus() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let listener = ClaudeHookHTTPListener(server: server)
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let response = try await postHook(port: port, token: "bad", body: #"{"tool_name":"Edit","tool_use_id":"tool-1"}"#)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deny)
    }

    private func postHook(port: Int, token: String, body: String) async throws -> AgentHookResponse {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/claude/hooks/pre-tool-use?conversation_id=conversation"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return AgentHookResponse(statusCode: httpResponse.statusCode, body: json)
    }
}

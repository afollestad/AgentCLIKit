import XCTest

@testable import AgentCLIKit

extension AgentHostToolServerTests {
    func testUnexpectedListenerFailureInvalidatesOldRoutesAndAllowsFreshRegistration() async throws {
        let listener = AgentHostToolHTTPListener(maxBodyBytes: 1_000_000)
        let server = DefaultAgentHostToolServer(handling: Self.echoHandling, listener: listener)
        addTeardownBlock { await server.shutdown() }
        let firstToken = UUID()
        let firstEndpoint = try await Self.register(server: server, processToken: firstToken)
        _ = try await Self.initialize(firstEndpoint)
        let failures = await server.failures()
        var failureIterator = failures.makeAsyncIterator()

        listener.simulateUnexpectedFailure()

        let nextFailure = await failureIterator.next()
        let failure = try XCTUnwrap(nextFailure)
        XCTAssertEqual(failure.processTokens, [firstToken])
        XCTAssertEqual(
            failure.message,
            "Host tools became unavailable because the local listener stopped unexpectedly. "
                + "Replace the affected provider process before using host tools again."
        )
        let firstRegistrationRemains = await server.isRegistered(processToken: firstToken)
        XCTAssertFalse(firstRegistrationRemains)

        let secondEndpoint = try await Self.register(server: server)
        let initialized = try await Self.initialize(secondEndpoint)
        let call = try await Self.call(secondEndpoint, id: "recovered-1", toolName: "echo")
        var oldRouteComponents = try XCTUnwrap(URLComponents(url: secondEndpoint.url, resolvingAgainstBaseURL: false))
        oldRouteComponents.path = firstEndpoint.url.path
        let oldRouteURL = try XCTUnwrap(oldRouteComponents.url)
        let oldRoute = try await AgentHostToolHTTPTestClient.send(
            to: firstEndpoint,
            url: oldRouteURL,
            body: try Self.initializeRequest()
        )
        let result = try XCTUnwrap(call.jsonObject?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])

        XCTAssertEqual(initialized.statusCode, 200)
        XCTAssertEqual(call.statusCode, 200)
        XCTAssertEqual(oldRoute.statusCode, 404)
        XCTAssertEqual(content.first?["text"] as? String, "echo")
    }

    func testFailureStreamFinishesOnShutdown() async {
        let server = DefaultAgentHostToolServer(handling: Self.echoHandling)
        let failures = await server.failures()

        await server.shutdown()

        var iterator = failures.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next)
    }
}

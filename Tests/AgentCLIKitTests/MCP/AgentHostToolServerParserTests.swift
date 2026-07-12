import XCTest

@testable import AgentCLIKit

extension AgentHostToolServerTests {
    func testRawParserRejectsAmbiguousLengthHeadersAndRoutes() async throws {
        let server = DefaultAgentHostToolServer(handling: Self.echoHandling)
        addTeardownBlock { await server.shutdown() }
        let endpoint = try await Self.register(server: server)
        let body = try Self.initializeRequest()
        let duplicateHeader = Self.rawRequest(
            endpoint: endpoint,
            body: body,
            extraHeaderLines: ["Host: \(Self.hostHeader(endpoint))"]
        )
        let transferEncoding = Self.rawRequest(
            endpoint: endpoint,
            body: body,
            extraHeaderLines: ["Transfer-Encoding: chunked"]
        )
        let extraBytes = Self.rawRequest(endpoint: endpoint, body: body, trailingBytes: Data("extra".utf8))
        let encodedRoute = Self.rawRequest(endpoint: endpoint, path: endpoint.url.path + "%2F", body: body)
        let queryRoute = Self.rawRequest(endpoint: endpoint, path: endpoint.url.path + "?query=1", body: body)
        let missingLength = Self.rawRequest(endpoint: endpoint, body: body, contentLength: nil)
        let invalidLength = Self.rawRequest(endpoint: endpoint, body: body, contentLength: "invalid")

        let requests = [
            duplicateHeader,
            transferEncoding,
            extraBytes,
            encodedRoute,
            queryRoute,
            missingLength,
            invalidLength
        ]
        for request in requests {
            let response = try await AgentHostToolHTTPTestClient.sendRawRequest(to: endpoint, request: request)
            XCTAssertEqual(response.statusCode, 400)
        }
    }

    private static func rawRequest(
        endpoint: AgentHostToolEndpoint,
        path: String? = nil,
        body: Data,
        contentLength: String? = "actual",
        extraHeaderLines: [String] = [],
        trailingBytes: Data = Data()
    ) -> Data {
        var headerLines = [
            "Host: \(hostHeader(endpoint))",
            "Authorization: Bearer \(endpoint.bearerToken)",
            "Accept: application/json",
            "Content-Type: application/json",
            "Connection: close"
        ]
        if let contentLength {
            headerLines.append("Content-Length: \(contentLength == "actual" ? String(body.count) : contentLength)")
        }
        headerLines.append(contentsOf: extraHeaderLines)
        var request = Data("POST \(path ?? endpoint.url.path) HTTP/1.1\r\n\(headerLines.joined(separator: "\r\n"))\r\n\r\n".utf8)
        request.append(body)
        request.append(trailingBytes)
        return request
    }

    private static func hostHeader(_ endpoint: AgentHostToolEndpoint) -> String {
        "127.0.0.1:\(endpoint.url.port ?? 0)"
    }
}

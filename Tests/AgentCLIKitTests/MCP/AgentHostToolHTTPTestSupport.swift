import Foundation
import Network

@testable import AgentCLIKit

struct AgentHostToolHTTPTestResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    var jsonObject: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

enum AgentHostToolHTTPTestClient {
    static func send(
        to endpoint: AgentHostToolEndpoint,
        url: URL? = nil,
        method: String = "POST",
        body: Data? = nil,
        bearerToken: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> AgentHostToolHTTPTestResponse {
        var request = URLRequest(url: url ?? endpoint.url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(bearerToken ?? endpoint.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (responseBody, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentHostToolHTTPTestError.invalidResponse
        }
        return AgentHostToolHTTPTestResponse(
            statusCode: httpResponse.statusCode,
            headers: normalizedHeaders(httpResponse.allHeaderFields),
            body: responseBody
        )
    }

    static func sendRaw(
        to endpoint: AgentHostToolEndpoint,
        method: String = "POST",
        body: Data? = nil,
        hostHeader: String,
        bearerToken: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> AgentHostToolHTTPTestResponse {
        guard let portValue = endpoint.url.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw AgentHostToolHTTPTestError.invalidEndpoint
        }
        let requestBody = body ?? Data()
        var requestHeaders = [
            "Accept": "application/json",
            "Authorization": "Bearer \(bearerToken ?? endpoint.bearerToken)",
            "Connection": "close",
            "Content-Length": String(requestBody.count),
            "Content-Type": "application/json",
            "Host": hostHeader
        ]
        requestHeaders.merge(headers) { _, new in new }
        let headerText = requestHeaders
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        var requestData = Data("\(method) \(endpoint.url.path) HTTP/1.1\r\n\(headerText)\r\n\r\n".utf8)
        requestData.append(requestBody)

        let exchange = AgentHostToolRawHTTPExchange(
            connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp),
            request: requestData
        )
        return try Self.parseRawResponse(try await exchange.perform())
    }

    static func sendRawRequest(
        to endpoint: AgentHostToolEndpoint,
        request: Data
    ) async throws -> AgentHostToolHTTPTestResponse {
        guard let portValue = endpoint.url.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw AgentHostToolHTTPTestError.invalidEndpoint
        }
        let exchange = AgentHostToolRawHTTPExchange(
            connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp),
            request: request
        )
        return try Self.parseRawResponse(try await exchange.perform())
    }

    private static func parseRawResponse(_ data: Data) throws -> AgentHostToolHTTPTestResponse {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw AgentHostToolHTTPTestError.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw AgentHostToolHTTPTestError.invalidResponse
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw AgentHostToolHTTPTestError.invalidResponse
        }
        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            guard let separator = line.firstIndex(of: ":") else {
                return
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[name.lowercased()] = value
        }
        return AgentHostToolHTTPTestResponse(
            statusCode: statusCode,
            headers: headers,
            body: Data(data[separator.upperBound...])
        )
    }

    private static func normalizedHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        headers.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String else {
                return
            }
            result[name.lowercased()] = String(describing: entry.value)
        }
    }
}

private enum AgentHostToolHTTPTestError: Error {
    case cancelled
    case invalidEndpoint
    case invalidResponse
    case timedOut
}

private final class AgentHostToolRawHTTPExchange: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "AgentCLIKitTests.AgentHostToolRawHTTPExchange")

    private let connection: NWConnection
    private let request: Data
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var received = Data()

    init(connection: NWConnection, request: Data) {
        self.connection = connection
        self.request = request
    }

    func perform() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                }
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.send()
                    case .failed(let error):
                        self?.finish(.failure(error))
                    case .cancelled:
                        self?.finish(.failure(AgentHostToolHTTPTestError.cancelled))
                    default:
                        break
                    }
                }
                connection.start(queue: Self.queue)
                Self.queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
                    self?.finish(.failure(AgentHostToolHTTPTestError.timedOut))
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func send() {
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failure(error))
            } else {
                self?.receive()
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data {
                lock.withLock {
                    received.append(data)
                }
            }
            if isComplete {
                finish(.success(lock.withLock { received }))
            } else if let error {
                let received = lock.withLock { received }
                finish(received.isEmpty ? .failure(error) : .success(received))
            } else {
                receive()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let continuation = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        guard let continuation else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

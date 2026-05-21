import Foundation
import Network

/// Loopback HTTP listener for Claude hook callbacks.
public final class ClaudeHookHTTPListener: ClaudeHookListeningTransport, @unchecked Sendable {
    private let server: ClaudeHookServer
    private let maxBodyBytes: Int
    private let queue = DispatchQueue(label: "AgentCLIKit.ClaudeHookHTTPListener")
    private let lock = NSLock()
    private var listener: NWListener?

    /// Creates a Claude hook HTTP listener.
    public init(server: ClaudeHookServer, maxBodyBytes: Int = 1_000_000) {
        self.server = server
        self.maxBodyBytes = maxBodyBytes
    }

    /// Starts a loopback listener on an ephemeral port.
    public func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let state = ListenerStartState(continuation: continuation)
            listener.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        state.resume(throwing: AgentCLIError.invalidInput("Claude hook listener started without a port."))
                        return
                    }
                    self?.store(listener)
                    state.resume(returning: Int(port))
                case .failed(let error):
                    state.resume(throwing: error)
                case .cancelled:
                    state.resume(throwing: AgentCLIError.invalidInput("Claude hook listener was cancelled before startup."))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Stops listening and closes the listener.
    public func stop() async {
        let listener = lock.withLock {
            let current = self.listener
            self.listener = nil
            return current
        }
        listener?.cancel()
    }

    private func store(_ listener: NWListener) {
        lock.withLock {
            self.listener = listener
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                self.sendDeny(on: connection)
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if nextBuffer.count > self.maxBodyBytes {
                self.sendDeny(on: connection)
                return
            }
            if let request = HTTPHookRequest(buffer: nextBuffer, maxBodyBytes: self.maxBodyBytes) {
                Task {
                    let response = await self.handle(request)
                    self.send(response, on: connection)
                }
                return
            }
            if isComplete {
                self.sendDeny(on: connection)
                return
            }
            self.receive(on: connection, buffer: nextBuffer)
        }
    }

    private func handle(_ request: HTTPHookRequest) async -> AgentHookResponse {
        guard request.path == "/claude/hooks/pre-tool-use",
              let conversationId = request.query["conversation_id"],
              let payload = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return Self.denyResponse(reason: "malformed_request")
        }
        return await server.handle(ClaudeHookRequest(
            bearerToken: request.bearerToken,
            hookName: "PreToolUse",
            conversationId: AgentConversationID(rawValue: conversationId),
            payload: payload
        ))
    }

    private func sendDeny(on connection: NWConnection) {
        send(Self.denyResponse(reason: "malformed_request"), on: connection)
    }

    private func send(_ response: AgentHookResponse, on connection: NWConnection) {
        let body = (try? JSONEncoder().encode(response.body ?? .object([:]))) ?? Data(#"{"decision":"deny"}"#.utf8)
        let status = response.statusCode == 200 ? "200 OK" : "\(response.statusCode) Error"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func denyResponse(reason: String) -> AgentHookResponse {
        AgentHookResponse(statusCode: 200, body: .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PreToolUse"),
                "permissionDecision": .string("deny"),
                "permissionDecisionReason": .string(reason)
            ])
        ]))
    }
}

private final class ListenerStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?

    init(continuation: CheckedContinuation<Int, Error>) {
        self.continuation = continuation
    }

    func resume(returning port: Int) {
        takeContinuation()?.resume(returning: port)
    }

    func resume(throwing error: Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Int, Error>? {
        lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
    }
}

struct HTTPHookRequest {
    let path: String
    let query: [String: String]
    let bearerToken: String?
    let body: Data

    init?(buffer: Data, maxBodyBytes: Int) {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0] == "POST" else {
            return nil
        }
        let headers = lines.dropFirst().reduce(into: [String: String]()) { headers, line in
            guard let separator = line.firstIndex(of: ":") else {
                return
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = headers[key] ?? value
        }
        guard let contentLengthText = headers["content-length"],
              let contentLength = Int(contentLengthText),
              contentLength >= 0,
              contentLength <= maxBodyBytes else {
            self.init(pathAndQuery: parts[1], bearerToken: Self.bearerToken(headers: headers), body: Data())
            return
        }
        let bodyStart = headerRange.upperBound
        guard buffer.count - bodyStart >= contentLength else {
            return nil
        }
        self.init(
            pathAndQuery: parts[1],
            bearerToken: Self.bearerToken(headers: headers),
            body: Data(buffer[bodyStart..<bodyStart + contentLength])
        )
    }

    private init(pathAndQuery: String, bearerToken: String?, body: Data) {
        let components = URLComponents(string: pathAndQuery)
        self.path = components?.path ?? pathAndQuery
        self.query = (components?.queryItems ?? []).reduce(into: [String: String]()) { query, item in
            guard let value = item.value else {
                return
            }
            query[item.name] = query[item.name] ?? value
        }
        self.bearerToken = bearerToken
        self.body = body
    }

    private static func bearerToken(headers: [String: String]) -> String? {
        guard let authorization = headers["authorization"] else {
            return nil
        }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else {
            return nil
        }
        return String(authorization.dropFirst(prefix.count))
    }
}

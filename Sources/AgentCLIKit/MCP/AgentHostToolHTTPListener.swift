import Foundation
import MCP
import Network

struct AgentHostToolHTTPListenerFailure: Sendable {
    struct AffectedRoute: Sendable {
        let path: String
        let processToken: UUID
    }

    let affectedRoutes: [AffectedRoute]
}

typealias AgentHostToolUnexpectedFailureHandler = @Sendable (AgentHostToolHTTPListenerFailure) -> Void

private final class AgentHostToolHTTPRoute: @unchecked Sendable {
    let transport: StatelessHTTPServerTransport
    let bearerToken: String
    let port: Int
    let processToken: UUID
    private let lock = NSLock()
    private var active = true

    init(transport: StatelessHTTPServerTransport, bearerToken: String, port: Int, processToken: UUID) {
        self.transport = transport
        self.bearerToken = bearerToken
        self.port = port
        self.processToken = processToken
    }

    var isActive: Bool {
        lock.withLock { active }
    }

    func deactivate() {
        lock.withLock { active = false }
    }
}

private struct AgentHostToolHTTPListenerFailureState {
    let connections: [NWConnection]
    let routes: [String: AgentHostToolHTTPRoute]
    let handler: AgentHostToolUnexpectedFailureHandler?
}

final class AgentHostToolHTTPListener: @unchecked Sendable {
    private let maxBodyBytes: Int
    private let maxResponseBytes: Int
    private let maxHeaderBytes: Int
    private let startupTimeout: DispatchTimeInterval
    private let connectionTimeout: DispatchTimeInterval
    private let queue = DispatchQueue(label: "AgentCLIKit.AgentHostToolHTTPListener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyPort: Int?
    private var isStopped = false
    private var unexpectedFailureHandler: AgentHostToolUnexpectedFailureHandler?
    private var routes: [String: AgentHostToolHTTPRoute] = [:]
    private var activeConnections: [UUID: NWConnection] = [:]

    init(
        maxBodyBytes: Int,
        maxResponseBytes: Int = 1_000_000,
        maxHeaderBytes: Int = 64 * 1_024,
        startupTimeout: DispatchTimeInterval = .seconds(5),
        connectionTimeout: DispatchTimeInterval = .seconds(40)
    ) {
        self.maxBodyBytes = maxBodyBytes
        self.maxResponseBytes = maxResponseBytes
        self.maxHeaderBytes = maxHeaderBytes
        self.startupTimeout = startupTimeout
        self.connectionTimeout = connectionTimeout
    }

    func start() async throws -> Int {
        let existingState = lock.withLock { (isStopped, readyPort, listener != nil) }
        guard !existingState.0 else {
            throw AgentCLIError.invalidInput("Host tool listener has stopped.")
        }
        if let port = existingState.1 {
            return port
        }
        guard !existingState.2 else {
            throw AgentCLIError.invalidInput("Host tool listener is already starting.")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        guard store(listener) else {
            listener.cancel()
            throw AgentCLIError.invalidInput("Host tool listener stopped during startup.")
        }
        return try await waitUntilReady(listener)
    }

    private func waitUntilReady(_ listener: NWListener) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let state = AgentHostListenerStartState(continuation: continuation)
            listener.stateUpdateHandler = { [weak self, weak listener] newState in
                guard let listener else {
                    return
                }
                self?.handleStateUpdate(newState, listener: listener, state: state)
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let listener else {
                    connection.cancel()
                    return
                }
                self?.accept(connection, from: listener)
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + startupTimeout) { [weak self, weak listener] in
                self?.handleStartupTimeout(listener: listener, state: state)
            }
        }
    }

    private func handleStateUpdate(
        _ newState: NWListener.State,
        listener: NWListener,
        state: AgentHostListenerStartState
    ) {
        switch newState {
        case .ready:
            guard let continuation = state.takeContinuation() else {
                return
            }
            guard let port = listener.port?.rawValue else {
                clearFailedListener(listener)
                listener.cancel()
                continuation.resume(throwing: AgentCLIError.invalidInput("Host tool listener started without a port."))
                return
            }
            markReady(listener, port: Int(port))
            continuation.resume(returning: Int(port))
        case .failed(let error):
            let continuation = state.takeContinuation()
            clearFailedListener(listener)
            continuation?.resume(throwing: error)
        case .cancelled:
            let continuation = state.takeContinuation()
            clearFailedListener(listener)
            continuation?.resume(throwing: AgentCLIError.invalidInput("Host tool listener was cancelled before startup."))
        default:
            break
        }
    }

    private func handleStartupTimeout(listener: NWListener?, state: AgentHostListenerStartState) {
        guard let listener,
              let continuation = state.takeContinuation() else {
            return
        }
        clearFailedListener(listener)
        listener.cancel()
        continuation.resume(throwing: AgentCLIError.invalidInput("Host tool listener startup timed out."))
    }

    func setUnexpectedFailureHandler(_ handler: @escaping AgentHostToolUnexpectedFailureHandler) {
        lock.withLock { unexpectedFailureHandler = handler }
    }

    func addRoute(
        path: String,
        transport: StatelessHTTPServerTransport,
        bearerToken: String,
        port: Int,
        processToken: UUID
    ) -> Bool {
        lock.withLock {
            guard readyPort == port, listener != nil else {
                return false
            }
            routes[path] = AgentHostToolHTTPRoute(
                transport: transport,
                bearerToken: bearerToken,
                port: port,
                processToken: processToken
            )
            return true
        }
    }

    var activePort: Int? {
        lock.withLock { readyPort }
    }

#if DEBUG
    func simulateUnexpectedFailure() {
        let activeListener = lock.withLock { listener }
        guard let activeListener else {
            return
        }
        clearFailedListener(activeListener)
        activeListener.cancel()
    }
#endif

    func removeRoute(path: String) {
        let route = lock.withLock { routes.removeValue(forKey: path) }
        route?.deactivate()
    }

    func stop() async {
        let (current, connections, activeRoutes) = lock.withLock {
            isStopped = true
            let current = listener
            listener = nil
            readyPort = nil
            let connections = Array(activeConnections.values)
            activeConnections.removeAll()
            let activeRoutes = Array(routes.values)
            routes.removeAll()
            return (current, connections, activeRoutes)
        }
        activeRoutes.forEach { $0.deactivate() }
        connections.forEach { $0.cancel() }
        current?.cancel()
    }

    private func store(_ listener: NWListener) -> Bool {
        lock.withLock {
            guard !isStopped, self.listener == nil else {
                return false
            }
            self.listener = listener
            readyPort = nil
            return true
        }
    }

    private func markReady(_ listener: NWListener, port: Int) {
        lock.withLock {
            guard self.listener === listener else {
                return
            }
            readyPort = port
        }
    }

    private func clearFailedListener(_ listener: NWListener) {
        let state: AgentHostToolHTTPListenerFailureState = lock.withLock {
            guard self.listener === listener else {
                return AgentHostToolHTTPListenerFailureState(connections: [], routes: [:], handler: nil)
            }
            let failureHandler = readyPort == nil ? nil : unexpectedFailureHandler
            self.listener = nil
            readyPort = nil
            let connections = Array(activeConnections.values)
            activeConnections.removeAll()
            let failedRoutes = routes
            routes.removeAll()
            return AgentHostToolHTTPListenerFailureState(
                connections: connections,
                routes: failedRoutes,
                handler: failureHandler
            )
        }
        state.routes.values.forEach { $0.deactivate() }
        state.connections.forEach { $0.cancel() }
        guard let failureHandler = state.handler else {
            return
        }
        failureHandler(
            AgentHostToolHTTPListenerFailure(
                affectedRoutes: state.routes.map { path, route in
                    AgentHostToolHTTPListenerFailure.AffectedRoute(
                        path: path,
                        processToken: route.processToken
                    )
                }
            )
        )
    }

    private func accept(_ connection: NWConnection, from sourceListener: NWListener) {
        let connectionId = UUID()
        let shouldAccept = lock.withLock {
            guard listener === sourceListener else {
                return false
            }
            activeConnections[connectionId] = connection
            return true
        }
        guard shouldAccept else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.removeConnection(connectionId)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak self] in
            self?.finishConnection(connectionId, connection: connection)
        }
        receive(on: connection, connectionId: connectionId, buffer: Data())
    }

    private func receive(on connection: NWConnection, connectionId: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            self.handleReceivedChunk(
                data,
                isComplete: isComplete,
                error: error,
                buffer: buffer,
                connectionContext: (connectionId, connection)
            )
        }
    }

    private func handleReceivedChunk(
        _ data: Data?,
        isComplete: Bool,
        error: NWError?,
        buffer: Data,
        connectionContext: (id: UUID, connection: NWConnection)
    ) {
        let (connectionId, connection) = connectionContext
        guard error == nil else {
            finishConnection(connectionId, connection: connection)
            return
        }
        var nextBuffer = buffer
        if let data {
            nextBuffer.append(data)
        }
        switch AgentHostHTTPRequestParser.parse(nextBuffer, maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes) {
        case .incomplete where !isComplete:
            receive(on: connection, connectionId: connectionId, buffer: nextBuffer)
        case .incomplete:
            send(statusCode: 400, headers: [:], body: nil, connectionId: connectionId, on: connection)
        case .failure(let statusCode):
            send(statusCode: statusCode, headers: [:], body: nil, connectionId: connectionId, on: connection)
        case .request(let path, let request):
            handleRequest(path: path, request: request, connectionId: connectionId, connection: connection)
        }
    }

    private func handleRequest(
        path: String,
        request: HTTPRequest,
        connectionId: UUID,
        connection: NWConnection
    ) {
        guard let route = lock.withLock({ routes[path] }), route.isActive else {
            send(statusCode: 404, headers: [:], body: nil, connectionId: connectionId, on: connection)
            return
        }
        if let rejection = Self.securityRejection(request, route: route) {
            let headers = rejection == 401 ? [HTTPHeaderName.wwwAuthenticate: "Bearer"] : [:]
            send(statusCode: rejection, headers: headers, body: nil, connectionId: connectionId, on: connection)
            return
        }
        Task {
            let response = await route.transport.handleRequest(request)
            guard route.isActive else {
                send(statusCode: 404, headers: [:], body: nil, connectionId: connectionId, on: connection)
                return
            }
            send(
                statusCode: response.statusCode,
                headers: response.headers,
                body: response.bodyData,
                connectionId: connectionId,
                on: connection
            )
        }
    }

    private static func securityRejection(_ request: HTTPRequest, route: AgentHostToolHTTPRoute) -> Int? {
        let expectedHosts = ["127.0.0.1:\(route.port)", "localhost:\(route.port)"]
        guard let host = request.header(HTTPHeaderName.host), expectedHosts.contains(host) else {
            return 421
        }
        if let origin = request.header(HTTPHeaderName.origin) {
            let expectedOrigins = ["http://127.0.0.1:\(route.port)", "http://localhost:\(route.port)"]
            guard expectedOrigins.contains(origin) else {
                return 403
            }
        }
        let prefix = "Bearer "
        guard let authorization = request.header(HTTPHeaderName.authorization),
              authorization.hasPrefix(prefix) else {
            return 401
        }
        return constantTimeEqual(String(authorization.dropFirst(prefix.count)), route.bearerToken) ? nil : 401
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }

    private func send(
        statusCode requestedStatusCode: Int,
        headers responseHeaders: [String: String],
        body: Data?,
        connectionId: UUID,
        on connection: NWConnection
    ) {
        let requestedBody = body ?? Data()
        let statusCode = requestedBody.count <= maxResponseBytes ? requestedStatusCode : 500
        let body = requestedBody.count <= maxResponseBytes ? requestedBody : Data()
        var headers = responseHeaders
        headers["Content-Length"] = String(body.count)
        headers["Cache-Control"] = "no-store"
        headers["Connection"] = "close"
        let headerLines = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        let statusLine = "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(statusCode))"
        var data = Data("\(statusLine)\r\n\(headerLines)\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finishConnection(connectionId, connection: connection)
        })
    }

    private func finishConnection(_ id: UUID, connection: NWConnection) {
        removeConnection(id)
        connection.cancel()
    }

    private func removeConnection(_ id: UUID) {
        _ = lock.withLock { activeConnections.removeValue(forKey: id) }
    }

    private static func reasonPhrase(_ statusCode: Int) -> String {
        reasonPhrases[statusCode] ?? "Error"
    }

    private static let reasonPhrases = [
        200: "OK",
        202: "Accepted",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        406: "Not Acceptable",
        413: "Content Too Large",
        415: "Unsupported Media Type",
        421: "Misdirected Request"
    ]
}

private final class AgentHostListenerStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?

    init(continuation: CheckedContinuation<Int, Error>) {
        self.continuation = continuation
    }

    func takeContinuation() -> CheckedContinuation<Int, Error>? {
        lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
    }
}

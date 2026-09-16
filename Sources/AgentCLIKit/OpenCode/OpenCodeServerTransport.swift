import Foundation

/// Process settings for one authenticated, loopback-only OpenCode server.
public struct OpenCodeServerConfiguration: Sendable {
    public let executablePath: String
    public let workingDirectory: URL
    public let environment: [String: String]
    public let startupTimeout: TimeInterval
    public let requestTimeout: TimeInterval
    public let shutdownTimeout: TimeInterval

    public init(
        executablePath: String,
        workingDirectory: URL,
        environment: [String: String] = [:],
        startupTimeout: TimeInterval = 10,
        requestTimeout: TimeInterval = 30,
        shutdownTimeout: TimeInterval = 3
    ) {
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        self.shutdownTimeout = shutdownTimeout
    }
}

/// The V1 API boundary is injectable so recovery can be tested without a model provider.
public protocol OpenCodeServerTransport: Sendable {
    func start() async throws
    func request(method: String, path: String, body: JSONValue?) async throws -> JSONValue
    func events() async throws -> AsyncThrowingStream<JSONValue, Error>
    func stop() async
}

/// Errors distinguish a definite API rejection from a submission whose outcome is unknown.
public enum OpenCodeTransportError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case http(status: Int, path: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message): return "OpenCode is unavailable: \(message)"
        case let .http(status, path): return "OpenCode returned HTTP \(status) for \(path)."
        case let .invalidResponse(message): return "Invalid OpenCode response: \(message)"
        }
    }
}

/// Owns its server and credentials; stopping the process never deletes native session storage.
public actor OpenCodeHTTPServerTransport: OpenCodeServerTransport {
    private let configuration: OpenCodeServerConfiguration
    private let processRegistry: OpenCodeServerProcessRegistry
    private let password = UUID().uuidString + UUID().uuidString
    private var process: Process?
    private var ownedProcess: OpenCodeOwnedServerProcess?
    private var stopTask: Task<Void, Never>?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var baseURL: URL?
    private var addressDecoder = OpenCodeServerAddressDecoder()
    private var stopped = false
    private let session: URLSession

    public init(configuration: OpenCodeServerConfiguration) {
        self.init(configuration: configuration, processRegistry: .shared)
    }

    init(configuration: OpenCodeServerConfiguration, processRegistry: OpenCodeServerProcessRegistry) {
        self.configuration = configuration
        self.processRegistry = processRegistry
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = 24 * 60 * 60
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        self.session = URLSession(configuration: sessionConfiguration, delegate: OpenCodeRedirectPolicy(), delegateQueue: nil)
    }

    public func start() async throws {
        guard !stopped else { throw CancellationError() }
        if baseURL != nil, process?.isRunning == true { return }
        guard process == nil else { throw OpenCodeTransportError.unavailable("Server startup already attempted.") }
        let child = Process()
        let out = Pipe()
        let err = Pipe()
        child.executableURL = URL(fileURLWithPath: configuration.executablePath)
        child.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]
        child.currentDirectoryURL = configuration.workingDirectory
        var environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, value in value }
        environment["OPENCODE_SERVER_USERNAME"] = "opencode"
        environment["OPENCODE_SERVER_PASSWORD"] = password
        environment["OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS"] = "false"
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
        child.environment = environment
        child.standardOutput = out
        child.standardError = err
        child.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.received(data) }
        }
        // Drain stderr without retaining configuration or credentials emitted by native plugins.
        err.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process = child
        stdout = out
        stderr = err
        do {
            ownedProcess = try processRegistry.launch(child)
            let deadline = Date().addingTimeInterval(configuration.startupTimeout)
            while baseURL == nil {
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                guard child.isRunning else { throw OpenCodeTransportError.unavailable("Server exited during startup.") }
                guard Date() < deadline else { throw OpenCodeTransportError.unavailable("Server startup timed out.") }
                try await Task.sleep(for: .milliseconds(25))
            }
            _ = try await request(method: "GET", path: "/global/health", body: nil)
        } catch {
            await stop()
            throw error
        }
    }

    public func request(method: String, path: String, body: JSONValue? = nil) async throws -> JSONValue {
        var request = try makeRequest(path: path)
        request.httpMethod = method
        // V1 summarize waits for model inference; unlike prompt_async it is not an acceptance-only response.
        if path.hasSuffix("/summarize") { request.timeoutInterval = max(configuration.requestTimeout, 300) }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Never retry a mutation: an interrupted response can follow a successful native operation.
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, path: path)
        guard !data.isEmpty else { return .null }
        do { return try JSONDecoder().decode(JSONValue.self, from: data) } catch {
            throw OpenCodeTransportError.invalidResponse("Expected JSON for \(path).")
        }
    }

    public func events() async throws -> AsyncThrowingStream<JSONValue, Error> {
        var request = try makeRequest(path: "/event")
        request.timeoutInterval = 24 * 60 * 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response, path: "/event")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var frame = OpenCodeSSEDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let event = try frame.consume(byte: byte) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() async {
        if let stopTask { return await stopTask.value }
        guard !stopped else { return }
        stopped = true
        let owned = ownedProcess
        ownedProcess = nil
        process = nil
        baseURL = nil
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        session.invalidateAndCancel()
        let timeout = configuration.shutdownTimeout
        let task = Task { if let owned { await owned.stop(grace: timeout) } }
        stopTask = task
        await task.value
        stdout = nil
        stderr = nil
        addressDecoder = OpenCodeServerAddressDecoder()
    }

    private func received(_ data: Data) {
        guard !stopped, baseURL == nil else { return }
        baseURL = addressDecoder.consume(data)
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard !stopped, process?.isRunning == true, let baseURL else {
            throw OpenCodeTransportError.unavailable("Server is not running.")
        }
        guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OpenCodeTransportError.invalidResponse("Invalid API path.")
        }
        components.path = path
        components.queryItems = [URLQueryItem(name: "directory", value: configuration.workingDirectory.path)]
        guard let url = components.url else { throw OpenCodeTransportError.invalidResponse("Invalid server URL.") }
        var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
        let credential = Data("opencode:\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func validate(_ response: URLResponse, path: String) throws {
        guard let response = response as? HTTPURLResponse else {
            throw OpenCodeTransportError.invalidResponse("Expected an HTTP response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenCodeTransportError.http(status: response.statusCode, path: path)
        }
    }
}

/// Decodes one SSE frame at a time with a bounded payload, including multiline data fields.
struct OpenCodeSSEDecoder {
    static let maximumFrameBytes = 16 * 1_024 * 1_024
    private var dataLines: [String] = []
    private var byteCount = 0
    private var lineBytes = Data()
    private var previousWasCarriageReturn = false

    /// SSE separators are ASCII CR/LF, not Unicode newlines that may legally appear inside JSON strings.
    mutating func consume(byte: UInt8) throws -> JSONValue? {
        if byte == 10, previousWasCarriageReturn {
            previousWasCarriageReturn = false
            return nil
        }
        previousWasCarriageReturn = byte == 13
        if byte == 10 || byte == 13 {
            defer { lineBytes = Data() }
            guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                throw OpenCodeTransportError.invalidResponse("SSE data is not valid UTF-8.")
            }
            return try consume(line: line)
        }
        guard lineBytes.count < Self.maximumFrameBytes else {
            throw OpenCodeTransportError.invalidResponse("SSE line exceeds the size limit.")
        }
        lineBytes.append(byte)
        return nil
    }

    mutating func consume(line: String) throws -> JSONValue? {
        if line.isEmpty {
            defer { dataLines = []; byteCount = 0 }
            guard !dataLines.isEmpty else { return nil }
            return try JSONDecoder().decode(JSONValue.self, from: Data(dataLines.joined(separator: "\n").utf8))
        }
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        byteCount += value.utf8.count + 1
        guard byteCount <= Self.maximumFrameBytes else {
            throw OpenCodeTransportError.invalidResponse("SSE frame exceeds the size limit.")
        }
        dataLines.append(value)
        return nil
    }
}

/// Waits for a whole startup line so a split port number cannot become the server address.
struct OpenCodeServerAddressDecoder {
    private var pending = Data()

    mutating func consume(_ data: Data) -> URL? {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let bytes = pending[..<newline]
            pending.removeSubrange(...newline)
            guard let line = String(bytes: bytes, encoding: .utf8) else { continue }
            let marker = "opencode server listening on "
            guard let range = line.range(of: marker) else { continue }
            let address = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
                  let port = url.port, port > 0, port <= 65_535,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { continue }
            return url
        }
        if pending.count > 65_536 { pending = pending.suffix(65_536) }
        return nil
    }
}

/// Server endpoints are local API calls; a redirect must never forward a prompt to another origin.
private final class OpenCodeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

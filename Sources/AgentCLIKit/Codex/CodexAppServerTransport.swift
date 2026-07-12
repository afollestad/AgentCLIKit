import Foundation

/// Codex App Server transport family used by `CodexProviderAdapter`.
public enum CodexAppServerTransportKind: String, Codable, Hashable, Sendable {
    /// Newline-delimited JSON-RPC over the App Server process standard input and output.
    case stdio
}

/// Transport contract for Codex App Server JSON-RPC requests.
public protocol CodexAppServerTransport: Sendable {
    /// Starts the underlying transport if it is not already running.
    func start() async throws

    /// Returns incoming server notifications and server-originated requests.
    func incomingMessages() -> AsyncStream<CodexAppServerIncomingMessage>

    /// Sends a JSON-RPC request and returns the result payload.
    func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue

    /// Sends a JSON-RPC notification without waiting for a response.
    func sendNotification(method: String, params: JSONValue?) async throws

    /// Sends a successful response to a server-originated JSON-RPC request.
    func sendResponse(id: JSONValue, result: JSONValue?) async throws

    /// Sends an error response to a server-originated JSON-RPC request.
    func sendErrorResponse(id: JSONValue, code: Int, message: String, data: JSONValue?) async throws

    /// Registers process-scoped values that must be redacted from provider diagnostics and echoed protocol payloads.
    func registerSensitiveValues(_ values: [String], processToken: UUID) async

    /// Retires process-scoped values while retaining a small bounded window for late provider frames.
    func unregisterSensitiveValues(processToken: UUID) async

    /// Shuts down the underlying transport and releases resources.
    func shutdown() async
}

/// Incoming JSON-RPC message sent by Codex App Server.
public enum CodexAppServerIncomingMessage: Sendable {
    /// Server notification that does not require a response.
    case notification(CodexAppServerNotification)
    /// Server request that requires a response.
    case request(CodexAppServerRequest)
}

/// Codex App Server notification payload.
public struct CodexAppServerNotification: Sendable {
    /// Notification method.
    public let method: String
    /// Optional notification parameters.
    public let params: JSONValue?

    /// Creates an App Server notification payload.
    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}

/// Codex App Server request payload.
public struct CodexAppServerRequest: Sendable {
    /// JSON-RPC request identifier.
    public let id: JSONValue
    /// Request method.
    public let method: String
    /// Optional request parameters.
    public let params: JSONValue?

    /// Creates an App Server request payload.
    public init(id: JSONValue, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Errors produced while bootstrapping or communicating with Codex App Server.
public enum CodexAppServerError: Error, Sendable {
    /// The configured transport is not implemented by AgentCLIKit.
    case unsupportedTransport(CodexAppServerTransportKind)
    /// A JSON-RPC request timed out before the App Server responded.
    case requestTimeout(method: String, seconds: TimeInterval)
    /// The App Server returned a JSON-RPC error response.
    case jsonRPCError(method: String, code: Int?, message: String)
    /// A successful thread response did not contain a thread identifier.
    case missingThreadID(method: String)
    /// The App Server process exited while requests were still active.
    case appServerExited(exitCode: Int32, stderrTail: String)
    /// The App Server process could not be stopped within the configured timeout.
    case shutdownTimeout(seconds: TimeInterval)
}

extension CodexAppServerError: LocalizedError {
    /// Diagnostic code matching this App Server failure.
    public var diagnosticCode: AgentDiagnosticCode {
        switch self {
        case .appServerExited:
            .codexAppServerCrash
        case .jsonRPCError:
            .codexAppServerJSONRPCError
        case .requestTimeout:
            .codexAppServerRequestTimeout
        case .missingThreadID, .unsupportedTransport:
            .codexAppServerResponseFailure
        case .shutdownTimeout:
            .codexAppServerShutdownTimeout
        }
    }

    /// Human-readable error summary.
    public var errorDescription: String? {
        switch self {
        case let .unsupportedTransport(kind):
            "Unsupported Codex App Server transport: \(kind.rawValue)."
        case let .requestTimeout(method, seconds):
            "Codex App Server request '\(method)' timed out after \(seconds) seconds."
        case let .jsonRPCError(method, code, message):
            "Codex App Server request '\(method)' failed with JSON-RPC error \(code.map(String.init) ?? "unknown"): \(message)"
        case let .missingThreadID(method):
            "Codex App Server response for '\(method)' did not include a thread id."
        case let .appServerExited(exitCode, stderrTail):
            stderrTail.isEmpty
                ? "Codex App Server exited with status \(exitCode)."
                : "Codex App Server exited with status \(exitCode): \(stderrTail)"
        case let .shutdownTimeout(seconds):
            "Codex App Server did not stop within \(seconds) seconds."
        }
    }
}

/// Stdio-backed Codex App Server transport.
public actor CodexStdioAppServerTransport: CodexAppServerTransport {
    private struct PendingResponse {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let configuration: CodexProviderAdapter.Configuration
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutReadHandle: FileHandle?
    private var stderrReadHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var pendingResponses: [Int: PendingResponse] = [:]
    private var incomingContinuations: [UUID: AsyncStream<CodexAppServerIncomingMessage>.Continuation] = [:]
    private var stderrTail: [String] = []
    private var stderrBuffer = CodexStderrRedactingBuffer()
    private var sensitiveValuesByProcessToken: [UUID: Set<String>] = [:]
    private var retiredSensitiveValues: [String] = []
    private var rawEventNotificationParser = CodexAppServerRawEventNotificationParser()
    private var isShutdown = false

    /// Creates a stdio App Server transport.
    public init(configuration: CodexProviderAdapter.Configuration) {
        self.configuration = configuration
    }

    /// Returns an incoming App Server message stream.
    public nonisolated func incomingMessages() -> AsyncStream<CodexAppServerIncomingMessage> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.addIncomingContinuation(continuation, id: id)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeIncomingContinuation(id: id)
                }
            }
        }
    }

    /// Starts `codex app-server --stdio` when needed.
    public func start() async throws {
        guard !isShutdown else {
            throw AgentCLIError.invalidInput("Codex App Server transport has shut down.")
        }
        if process?.isRunning == true {
            return
        }

        guard configuration.transportKind == .stdio else {
            throw CodexAppServerError.unsupportedTransport(configuration.transportKind)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        let launch = launchArguments()
        var environment = ProcessInfo.processInfo.environment
        environment.merge(configuration.environment) { _, new in new }
        if let codexHomeDirectory = configuration.codexHomeDirectory {
            environment["CODEX_HOME"] = codexHomeDirectory.path
        }

        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeStdout(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeStderr(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.processExited(exitCode: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            throw AgentCLIError.commandLaunchFailed(executable: launch.executable, reason: error.localizedDescription)
        }

        self.process = process
        self.stdin = stdin.fileHandleForWriting
        self.stdoutReadHandle = stdout.fileHandleForReading
        self.stderrReadHandle = stderr.fileHandleForReading
    }

    /// Sends a request object and waits for the matching response id.
    public func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        try await start()
        return try await withCheckedThrowingContinuation { continuation in
            let id = nextRequestID
            nextRequestID += 1
            let requestTimeout = timeout(for: method)
            let timeoutTask = Task {
                let nanoseconds = UInt64(max(0, requestTimeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                await self.failPendingResponse(
                    id: id,
                    error: CodexAppServerError.requestTimeout(method: method, seconds: requestTimeout)
                )
            }
            pendingResponses[id] = PendingResponse(method: method, continuation: continuation, timeoutTask: timeoutTask)
            do {
                try writeMessage(id: id, method: method, params: params)
            } catch {
                pendingResponses[id] = nil
                timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Sends a notification object.
    public func sendNotification(method: String, params: JSONValue?) async throws {
        try await start()
        try writeMessage(id: nil, method: method, params: params)
    }

    /// Sends a successful response to an App Server request.
    public func sendResponse(id: JSONValue, result: JSONValue?) async throws {
        try await start()
        try writeObject(.object([
            "id": id,
            "result": result ?? .null
        ]))
    }

    /// Sends an error response to an App Server request.
    public func sendErrorResponse(id: JSONValue, code: Int, message: String, data: JSONValue?) async throws {
        try await start()
        var error: [String: JSONValue] = [
            "code": .number(Double(code)),
            "message": .string(message)
        ]
        if let data {
            error["data"] = data
        }
        try writeObject(.object([
            "id": id,
            "error": .object(error)
        ]))
    }

    /// Redacts registered bearer values from all subsequent protocol and stderr processing.
    public func registerSensitiveValues(_ values: [String], processToken: UUID) async {
        guard !isShutdown else {
            return
        }
        sensitiveValuesByProcessToken[processToken] = Set(values.filter { !$0.isEmpty })
    }

    /// Retires one process's values after route invalidation while keeping late App Server frames redacted.
    public func unregisterSensitiveValues(processToken: UUID) async {
        guard let values = sensitiveValuesByProcessToken.removeValue(forKey: processToken) else {
            return
        }
        for value in values {
            retiredSensitiveValues.removeAll { $0 == value }
            retiredSensitiveValues.append(value)
        }
        if retiredSensitiveValues.count > 64 {
            retiredSensitiveValues.removeFirst(retiredSensitiveValues.count - 64)
        }
    }

    var retainedSensitiveValueCount: Int {
        allSensitiveValues.count
    }

    /// Terminates the App Server process and fails any pending responses.
    public func shutdown() async {
        guard !isShutdown else {
            return
        }
        isShutdown = true
        pendingResponses.values.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: AgentCLIError.invalidInput("Codex App Server shut down."))
        }
        pendingResponses.removeAll()
        incomingContinuations.values.forEach { $0.finish() }
        incomingContinuations.removeAll()
        stdin = nil
        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil
        stdoutReadHandle = nil
        stderrReadHandle = nil
        let processToStop = process
        processToStop?.terminate()
        if let processToStop {
            await CodexProcessShutdown.waitForExitOrKill(
                processToStop,
                timeout: configuration.shutdownTimeout
            )
        }
        if let finalLine = stderrBuffer.flush(sensitiveValues: allSensitiveValues) {
            appendStderrLines([finalLine])
        }
        process = nil
        stdoutBuffer.removeAll()
        sensitiveValuesByProcessToken.removeAll()
        retiredSensitiveValues.removeAll()
    }

    private func launchArguments() -> (executable: String, arguments: [String]) {
        if configuration.executablePath == "/usr/bin/env" {
            return (configuration.executablePath, ["codex", "app-server", "--stdio"])
        }
        return (configuration.executablePath, ["app-server", "--stdio"])
    }

    private func timeout(for method: String) -> TimeInterval {
        method == "initialize" ? configuration.probeTimeout : configuration.requestTimeout
    }

    private func writeMessage(id: Int?, method: String, params: JSONValue?) throws {
        var object: [String: JSONValue] = ["method": .string(method)]
        if let id {
            object["id"] = .number(Double(id))
        }
        if let params {
            object["params"] = params
        }
        try writeObject(.object(object))
    }

    private func writeObject(_ value: JSONValue) throws {
        guard let stdin else {
            throw AgentCLIError.invalidInput("Codex App Server stdin is unavailable.")
        }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func consumeStdout(_ data: Data) {
        guard !isShutdown, !data.isEmpty else {
            return
        }
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(stdoutBuffer[..<newlineIndex])
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            stdoutBuffer.removeSubrange(...newlineIndex)
            handleStdoutLine(lineData)
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !isShutdown, !data.isEmpty else {
            return
        }
        let lines = stderrBuffer.append(data, sensitiveValues: allSensitiveValues)
        appendStderrLines(lines)
    }

    private func handleStdoutLine(_ lineData: Data) {
        guard let decodedValue = try? JSONDecoder().decode(JSONValue.self, from: lineData) else {
            return
        }
        let value = decodedValue.transportRedacting(sensitiveValues: allSensitiveValues)
        guard case let .object(object) = value else {
            return
        }
        if let id = object["id"]?.transportIntValue,
           let pending = pendingResponses.removeValue(forKey: id) {
            handleResponse(object, pending: pending)
            return
        }
        if let notification = rawEventNotificationParser.notification(from: object) {
            publishIncoming(.notification(notification))
            return
        }
        guard case let .string(method)? = object["method"] else {
            return
        }
        if let id = object["id"] {
            publishIncoming(.request(CodexAppServerRequest(id: id, method: method, params: object["params"])))
        } else {
            publishIncoming(.notification(CodexAppServerNotification(method: method, params: object["params"])))
        }
    }

    private func handleResponse(_ object: [String: JSONValue], pending: PendingResponse) {
        pending.timeoutTask.cancel()
        if let error = object["error"]?.transportJSONRPCError {
            pending.continuation.resume(throwing: CodexAppServerError.jsonRPCError(
                method: pending.method,
                code: error.code,
                message: error.message
            ))
        } else {
            pending.continuation.resume(returning: object["result"] ?? .null)
        }
    }

    private func addIncomingContinuation(_ continuation: AsyncStream<CodexAppServerIncomingMessage>.Continuation, id: UUID) {
        guard !isShutdown else {
            continuation.finish()
            return
        }
        incomingContinuations[id] = continuation
    }

    private func removeIncomingContinuation(id: UUID) {
        incomingContinuations[id] = nil
    }

    private func publishIncoming(_ message: CodexAppServerIncomingMessage) {
        incomingContinuations.values.forEach { $0.yield(message) }
    }

    private func failPendingResponse(id: Int, error: Error) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func processExited(exitCode: Int32) {
        if let finalLine = stderrBuffer.flush(sensitiveValues: allSensitiveValues) {
            appendStderrLines([finalLine])
        }
        let error = CodexAppServerError.appServerExited(exitCode: exitCode, stderrTail: stderrTail.suffix(5).joined(separator: "\n"))
        pendingResponses.values.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()
        incomingContinuations.values.forEach { $0.finish() }
        incomingContinuations.removeAll()
        process = nil
        stdin = nil
    }

    private var allSensitiveValues: Set<String> {
        sensitiveValuesByProcessToken.values.reduce(into: Set(retiredSensitiveValues)) { result, values in
            result.formUnion(values)
        }
    }

    private func appendStderrLines(_ lines: [String]) {
        stderrTail.append(contentsOf: lines)
        if stderrTail.count > 20 {
            stderrTail.removeFirst(stderrTail.count - 20)
        }
    }

}

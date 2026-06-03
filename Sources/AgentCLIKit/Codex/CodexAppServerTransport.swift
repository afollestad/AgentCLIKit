import Darwin
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

    /// Sends a JSON-RPC request and returns the result payload.
    func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue

    /// Sends a JSON-RPC notification without waiting for a response.
    func sendNotification(method: String, params: JSONValue?) async throws

    /// Shuts down the underlying transport and releases resources.
    func shutdown() async
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
    private var stderrTail: [String] = []

    /// Creates a stdio App Server transport.
    public init(configuration: CodexProviderAdapter.Configuration) {
        self.configuration = configuration
    }

    /// Starts `codex app-server --stdio` when needed.
    public func start() async throws {
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

    /// Terminates the App Server process and fails any pending responses.
    public func shutdown() async {
        pendingResponses.values.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: AgentCLIError.invalidInput("Codex App Server shut down."))
        }
        pendingResponses.removeAll()
        stdin = nil
        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil
        stdoutReadHandle = nil
        stderrReadHandle = nil
        let processToStop = process
        processToStop?.terminate()
        if let processToStop {
            await waitForExitOrKill(processToStop)
        }
        process = nil
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
        guard let stdin else {
            throw AgentCLIError.invalidInput("Codex App Server stdin is unavailable.")
        }
        var object: [String: JSONValue] = ["method": .string(method)]
        if let id {
            object["id"] = .number(Double(id))
        }
        if let params {
            object["params"] = params
        }
        var data = try JSONEncoder().encode(JSONValue.object(object))
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else {
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
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return
        }
        stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
        if stderrTail.count > 20 {
            stderrTail.removeFirst(stderrTail.count - 20)
        }
    }

    private func handleStdoutLine(_ lineData: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: lineData),
              case let .object(object) = value,
              let id = object["id"]?.intValue,
              let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()
        if let error = object["error"]?.jsonRPCError {
            pending.continuation.resume(throwing: CodexAppServerError.jsonRPCError(
                method: pending.method,
                code: error.code,
                message: error.message
            ))
        } else {
            pending.continuation.resume(returning: object["result"] ?? .null)
        }
    }

    private func failPendingResponse(id: Int, error: Error) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func processExited(exitCode: Int32) {
        let error = CodexAppServerError.appServerExited(exitCode: exitCode, stderrTail: stderrTail.suffix(5).joined(separator: "\n"))
        pendingResponses.values.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()
        process = nil
        stdin = nil
    }

    private func waitForExitOrKill(_ process: Process) async {
        let sleepNanoseconds: UInt64 = 50_000_000
        let attempts = max(1, Int(configuration.shutdownTimeout * 1_000_000_000 / Double(sleepNanoseconds)))
        for _ in 0..<attempts {
            guard process.isRunning else {
                return
            }
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        guard process.isRunning else {
            return
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

private struct CodexJSONRPCError {
    let code: Int?
    let message: String
}

private extension JSONValue {
    var intValue: Int? {
        switch self {
        case let .number(value):
            Int(value)
        case let .string(value):
            Int(value)
        default:
            nil
        }
    }

    var jsonRPCError: CodexJSONRPCError? {
        guard case let .object(object) = self else {
            return nil
        }
        let code = object["code"]?.intValue
        let message: String
        if case let .string(value)? = object["message"] {
            message = value
        } else {
            message = "Unknown JSON-RPC error."
        }
        return CodexJSONRPCError(code: code, message: message)
    }
}

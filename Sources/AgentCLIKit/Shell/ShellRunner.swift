import Foundation

/// Shell command description used by provider detection and process helpers.
public struct ShellCommand: Codable, Equatable, Hashable, Sendable {
    /// Executable path or name.
    public let executable: String
    /// Command-line arguments.
    public let arguments: [String]
    /// Environment overrides. Values are merged over the process environment.
    public let environment: [String: String]
    /// Optional working directory.
    public let workingDirectory: URL?
    /// Optional text written to standard input, then closed.
    public let standardInput: String?

    /// Creates a shell command.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        standardInput: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
    }

    /// Decodes a shell command, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.executable = try container.decode(String.self, forKey: .executable)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        self.workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
        self.standardInput = try container.decodeIfPresent(String.self, forKey: .standardInput)
    }
}

/// Collected output from a completed shell command.
public struct ShellCommandResult: Codable, Equatable, Sendable {
    /// Process exit code.
    public let exitCode: Int32
    /// Collected standard output as UTF-8 text.
    public let stdout: String
    /// Collected standard error as UTF-8 text.
    public let stderr: String

    /// Creates a shell command result.
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Abstraction for running short-lived shell commands.
public protocol ShellRunning: Sendable {
    /// Runs a command and returns collected output after the process exits.
    func run(_ command: ShellCommand) async throws -> ShellCommandResult
}

/// `Process`-backed shell runner for short-lived commands.
public struct ProcessShellRunner: ShellRunning {
    /// Creates a process shell runner.
    public init() {}

    /// Runs a command with `Process` and collects stdout and stderr after exit.
    public func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        let process = Process()
        let cancellationHandler = ProcessCancellationHandler()
        let terminationObserver = ProcessTerminationObserver()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            cancellationHandler.setProcess(process)
            defer { cancellationHandler.clearProcess() }

            let pipes = Self.prepareProcess(process, for: command, terminationObserver: terminationObserver)
            defer { process.terminationHandler = nil }

            try Task.checkCancellation()

            do {
                try process.run()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw AgentCLIError.commandLaunchFailed(executable: command.executable, reason: error.localizedDescription)
            }
            if Task.isCancelled {
                cancellationHandler.terminate()
            }

            let stdinWriter = Self.writeStandardInput(command.standardInput, to: pipes.stdin)

            // Drain both pipes while the process runs so verbose commands cannot block on a full pipe buffer.
            async let stdoutData = Task.detached { pipes.stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderrData = Task.detached { pipes.stderr.fileHandleForReading.readDataToEndOfFile() }.value

            await terminationObserver.waitForTermination()
            if let stdinWriter {
                await stdinWriter.value
            }
            let output = await (
                stdout: stdoutData,
                stderr: stderrData
            )
            try Task.checkCancellation()

            return ShellCommandResult(
                exitCode: process.terminationStatus,
                stdout: String(data: output.stdout, encoding: .utf8) ?? "",
                stderr: String(data: output.stderr, encoding: .utf8) ?? ""
            )
        } onCancel: {
            cancellationHandler.terminate()
        }
    }

    private static func prepareProcess(
        _ process: Process,
        for command: ShellCommand,
        terminationObserver: ProcessTerminationObserver
    ) -> ProcessPipes {
        let launch = launchConfiguration(for: command)
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        }
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdin = command.standardInput == nil ? nil : Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        if let stdin {
            process.standardInput = stdin
        }
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in
            terminationObserver.signalTermination()
        }
        return ProcessPipes(stdin: stdin, stdout: stdout, stderr: stderr)
    }

    private static func writeStandardInput(_ standardInput: String?, to pipe: Pipe?) -> Task<Void, Never>? {
        guard let standardInput,
              let pipe else {
            return nil
        }
        return Task.detached {
            let data = Data(standardInput.utf8)
            pipe.fileHandleForWriting.write(data)
            try? pipe.fileHandleForWriting.close()
        }
    }

    private static func launchConfiguration(for command: ShellCommand) -> (executableURL: URL, arguments: [String]) {
        guard !command.executable.contains("/") else {
            return (URL(fileURLWithPath: command.executable), command.arguments)
        }
        // Bare executable names are resolved through PATH so the public shell command model can accept either paths or names.
        return (URL(fileURLWithPath: "/usr/bin/env"), [command.executable] + command.arguments)
    }
}

private struct ProcessPipes {
    let stdin: Pipe?
    let stdout: Pipe
    let stderr: Pipe
}

private final class ProcessCancellationHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    // Cancellation can arrive before or after launch, so keep process lookup synchronized for teardown.
    func setProcess(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func clearProcess() {
        lock.withLock {
            process = nil
        }
    }

    func terminate() {
        let process = lock.withLock { self.process }
        guard process?.isRunning == true else {
            return
        }
        process?.terminate()
    }
}

private final class ProcessTerminationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var terminated = false

    // A short-lived process can exit before the waiter installs its continuation.
    func signalTermination() {
        let continuation = lock.withLock {
            terminated = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func waitForTermination() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if terminated {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

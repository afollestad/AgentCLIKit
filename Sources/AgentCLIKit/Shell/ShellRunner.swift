import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Shell command description used by harness detection and process helpers.
public struct ShellCommand: Codable, Equatable, Hashable, Sendable {
    /// Executable path or name.
    public let executable: String
    /// Command-line arguments.
    public let arguments: [String]
    /// Environment values, interpreted according to `inheritsEnvironment`.
    public let environment: [String: String]
    /// Whether environment values override the parent process environment. False replaces it completely.
    public let inheritsEnvironment: Bool
    /// Optional working directory.
    public let workingDirectory: URL?
    /// Optional text written to standard input, then closed.
    public let standardInput: String?

    /// Creates a shell command.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        inheritsEnvironment: Bool = true,
        workingDirectory: URL? = nil,
        standardInput: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.inheritsEnvironment = inheritsEnvironment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
    }

    /// Decodes a shell command, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.executable = try container.decode(String.self, forKey: .executable)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        self.inheritsEnvironment = try container.decodeIfPresent(Bool.self, forKey: .inheritsEnvironment) ?? true
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
            cancellationHandler.didLaunch()
            if Task.isCancelled {
                cancellationHandler.terminate()
            }

            let stdinWriter = Self.writeStandardInput(command.standardInput, to: pipes.stdin)

            // Drain both pipes while the process runs so verbose commands cannot block on a full pipe buffer.
            async let stdoutData = Task.detached { pipes.stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderrData = Task.detached { pipes.stderr.fileHandleForReading.readDataToEndOfFile() }.value

            await terminationObserver.waitForTermination()
            cancellationHandler.terminate()
            await cancellationHandler.waitForTeardown()
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
        if !command.inheritsEnvironment {
            process.environment = command.environment
        } else if !command.environment.isEmpty {
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

/// Cancellation before launch publication is completed by the runner's post-launch check, once group ownership is known.
final class ProcessCancellationHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var ownedGroup: pid_t?
    private var hasLaunched = false
    private var teardown: Task<Void, Never>?

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

    /// Foundation creates a child process group on supported platforms; confirm ownership before ever signaling it.
    func didLaunch() {
        lock.withLock {
            guard let process else { return }
            hasLaunched = true
            let identifier = process.processIdentifier
            guard identifier > 0, identifier != getpgrp() else { return }
            if getpgid(identifier) == identifier || !process.isRunning && Self.groupExists(identifier) {
                ownedGroup = identifier
            }
        }
    }

    func terminate() {
        lock.withLock {
            guard hasLaunched, teardown == nil, let process,
                  process.isRunning || ownedGroup.map(Self.groupExists) == true else { return }
            let group = ownedGroup
            if let group { kill(-group, SIGTERM) } else if process.isRunning { process.terminate() }
            // Retire the owned group before removing resources, including children that inherited no output pipes.
            teardown = Task.detached {
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning || group.map(Self.groupExists) == true {
                    if Date() >= deadline {
                        // SIGKILL prevents more user-mode work; orphan zombies may retain the group until their new parent reaps them.
                        if let group { kill(-group, SIGKILL) } else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        return
                    }
                    // Stop tracking as soon as the owned group disappears, before its identifier can be reused.
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    func waitForTeardown() async {
        let task = lock.withLock { teardown }
        await task?.value
    }

    private static func groupExists(_ identifier: pid_t) -> Bool {
        kill(-identifier, 0) == 0 || errno == EPERM
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

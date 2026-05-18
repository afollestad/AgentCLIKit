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

    /// Creates a shell command.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
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
        try await Task.detached(priority: nil) {
            let process = Process()
            let launch = Self.launchConfiguration(for: command)
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            if !command.environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
            }
            if let workingDirectory = command.workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw AgentCLIError.commandLaunchFailed(executable: command.executable, reason: error.localizedDescription)
            }

            // Drain both pipes while the process runs so verbose commands cannot block on a full pipe buffer.
            async let stdoutData = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderrData = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value

            process.waitUntilExit()

            return ShellCommandResult(
                exitCode: process.terminationStatus,
                stdout: String(data: await stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: await stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }

    private static func launchConfiguration(for command: ShellCommand) -> (executableURL: URL, arguments: [String]) {
        guard !command.executable.contains("/") else {
            return (URL(fileURLWithPath: command.executable), command.arguments)
        }
        // Bare executable names are resolved through PATH so the public shell command model can accept either paths or names.
        return (URL(fileURLWithPath: "/usr/bin/env"), [command.executable] + command.arguments)
    }
}

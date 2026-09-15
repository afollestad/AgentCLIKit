import Foundation

/// Tool policy for a sessionless one-shot harness prompt.
public enum AgentOneShotToolPolicy: String, Codable, Equatable, Sendable {
    /// Allow harness-native file inspection tools only.
    case readOnly
}

/// Request for a harness prompt that should not create a runtime conversation.
public struct AgentOneShotPromptRequest: Codable, Equatable, Sendable {
    /// Harness to invoke.
    public let harnessId: AgentHarnessID
    /// Working directory for the harness process.
    public let workingDirectory: URL
    /// Prompt text written to harness stdin.
    public let prompt: String
    /// Additional harness arguments. Safety flags from `toolPolicy` remain authoritative.
    public let arguments: [String]
    /// Environment overrides.
    public let environment: [String: String]
    /// Optional model name.
    public let model: String?
    /// Optional harness effort setting.
    public let effort: String?
    /// Maximum time to wait for the harness command.
    public let timeout: TimeInterval?
    /// Tool policy for the one-shot prompt.
    public let toolPolicy: AgentOneShotToolPolicy

    /// Creates a one-shot prompt request.
    public init(
        harnessId: AgentHarnessID,
        workingDirectory: URL,
        prompt: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        model: String? = nil,
        effort: String? = nil,
        timeout: TimeInterval? = nil,
        toolPolicy: AgentOneShotToolPolicy = .readOnly
    ) {
        self.harnessId = harnessId
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.arguments = arguments
        self.environment = environment
        self.model = model
        self.effort = effort
        self.timeout = timeout
        self.toolPolicy = toolPolicy
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case harnessId = "providerId"
        case workingDirectory
        case prompt
        case arguments
        case environment
        case model
        case effort
        case timeout
        case toolPolicy
    }
}

/// Result from a completed one-shot harness prompt.
public struct AgentOneShotPromptResult: Codable, Equatable, Sendable {
    /// Harness that produced the result.
    public let harnessId: AgentHarnessID
    /// Final assistant text.
    public let text: String
    /// Raw harness stdout.
    public let stdout: String
    /// Raw harness stderr diagnostics.
    public let stderr: String

    /// Creates a one-shot prompt result.
    public init(harnessId: AgentHarnessID, text: String, stdout: String, stderr: String) {
        self.harnessId = harnessId
        self.text = text
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case harnessId = "providerId"
        case text
        case stdout
        case stderr
    }
}

/// Errors thrown by sessionless one-shot prompt runners.
public enum AgentOneShotPromptError: Error, Equatable, Sendable, LocalizedError {
    /// The harness is not supported by the runner.
    case unsupportedHarness(AgentHarnessID)
    /// The requested tool policy is unsupported.
    case unsupportedToolPolicy(AgentHarnessID, AgentOneShotToolPolicy)
    /// The harness command could not be launched.
    case commandLaunchFailed(harnessId: AgentHarnessID, reason: String)
    /// The harness command exited unsuccessfully.
    case commandFailed(harnessId: AgentHarnessID, exitCode: Int32, stdout: String, stderr: String)
    /// The harness command exceeded its timeout.
    case timedOut(harnessId: AgentHarnessID, timeout: TimeInterval)
    /// The one-shot task was cancelled.
    case cancelled(harnessId: AgentHarnessID)
    /// The harness reported that a selected model is unavailable.
    case unavailableModel(harnessId: AgentHarnessID, message: String)
    /// The harness asked for an approval, which one-shot read-only runs cannot service.
    case approvalRequired(harnessId: AgentHarnessID, message: String)
    /// The harness asked a user prompt, which one-shot runs cannot service.
    case promptRequired(harnessId: AgentHarnessID, message: String)
    /// The harness exited successfully but did not produce final assistant text.
    case emptyOutput(harnessId: AgentHarnessID, stdout: String, stderr: String)
    /// The harness stdout was not valid for its declared structured output mode.
    case malformedOutput(harnessId: AgentHarnessID, message: String, stdout: String, stderr: String)
    /// The harness reported an error through structured output.
    case harnessReportedError(harnessId: AgentHarnessID, message: String, stdout: String, stderr: String)

    /// Human-readable description suitable for diagnostics and host UI.
    public var errorDescription: String? {
        switch self {
        case let .unsupportedHarness(harnessId):
            "Harness '\(harnessId.rawValue)' does not support one-shot prompts."
        case let .unsupportedToolPolicy(harnessId, toolPolicy):
            "Harness '\(harnessId.rawValue)' does not support one-shot tool policy '\(toolPolicy.rawValue)'."
        case let .commandLaunchFailed(harnessId, reason):
            "Could not launch '\(harnessId.rawValue)' one-shot prompt: \(reason)"
        case let .commandFailed(harnessId, exitCode, _, stderr):
            "Harness '\(harnessId.rawValue)' one-shot prompt failed with exit code \(exitCode). \(stderr)"
        case let .timedOut(harnessId, timeout):
            "Harness '\(harnessId.rawValue)' one-shot prompt timed out after \(timeout) seconds."
        case let .cancelled(harnessId):
            "Harness '\(harnessId.rawValue)' one-shot prompt was cancelled."
        case let .unavailableModel(harnessId, message):
            "Harness '\(harnessId.rawValue)' model is unavailable. \(message)"
        case let .approvalRequired(harnessId, message):
            "Harness '\(harnessId.rawValue)' requested approval during a read-only one-shot prompt. \(message)"
        case let .promptRequired(harnessId, message):
            "Harness '\(harnessId.rawValue)' requested user input during a one-shot prompt. \(message)"
        case let .emptyOutput(harnessId, _, stderr):
            "Harness '\(harnessId.rawValue)' one-shot prompt completed without final output. \(stderr)"
        case let .malformedOutput(harnessId, message, _, stderr):
            "Harness '\(harnessId.rawValue)' one-shot prompt returned malformed structured output. \(message) \(stderr)"
        case let .harnessReportedError(harnessId, message, _, stderr):
            "Harness '\(harnessId.rawValue)' one-shot prompt reported an error. \(message) \(stderr)"
        }
    }
}

/// Service that runs a single harness prompt without creating a runtime conversation.
public protocol AgentOneShotPromptRunning: Sendable {
    /// Runs a one-shot harness prompt and returns the final assistant text.
    func generate(_ request: AgentOneShotPromptRequest) async throws -> AgentOneShotPromptResult
}

/// Default CLI-backed one-shot prompt runner.
public struct DefaultAgentOneShotPromptRunner: AgentOneShotPromptRunning {
    private let shellRunner: any ShellRunning
    private let adapters: [AgentHarnessID: any AgentHarnessAdapter]

    /// Creates a CLI-backed one-shot prompt runner.
    /// - Parameters:
    ///   - adapterSet: Harness adapters used to construct and parse one-shot harness commands.
    ///   - shellRunner: Runner used for the harness command.
    public init(
        adapterSet: AgentHarnessAdapterSet = .default,
        shellRunner: any ShellRunning = ProcessShellRunner()
    ) {
        self.shellRunner = shellRunner
        self.adapters = Dictionary(adapterSet.adapters.map { ($0.definition.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Creates a CLI-backed one-shot prompt runner from explicit harness adapters.
    public init(
        adapters: [any AgentHarnessAdapter],
        shellRunner: any ShellRunning = ProcessShellRunner()
    ) {
        self.init(adapterSet: AgentHarnessAdapterSet(adapters: adapters), shellRunner: shellRunner)
    }

    /// Runs a one-shot harness prompt and returns the final assistant text.
    public func generate(_ request: AgentOneShotPromptRequest) async throws -> AgentOneShotPromptResult {
        guard request.toolPolicy == .readOnly else {
            throw AgentOneShotPromptError.unsupportedToolPolicy(request.harnessId, request.toolPolicy)
        }
        guard let adapter = adapters[request.harnessId] else {
            throw AgentOneShotPromptError.unsupportedHarness(request.harnessId)
        }

        let command = try await adapter.makeOneShotPromptCommand(request: request)
        let result = try await run(command, request: request)
        if result.exitCode != 0 {
            throw classifyFailure(harnessId: request.harnessId, result: result)
        }

        let text = try await adapter.finalOneShotPromptText(stdout: result.stdout, stderr: result.stderr, request: request)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentOneShotPromptError.emptyOutput(
                harnessId: request.harnessId,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        return AgentOneShotPromptResult(harnessId: request.harnessId, text: trimmed, stdout: result.stdout, stderr: result.stderr)
    }

    private func run(_ command: ShellCommand, request: AgentOneShotPromptRequest) async throws -> ShellCommandResult {
        do {
            return try await runWithTimeout(command, timeout: request.timeout, harnessId: request.harnessId)
        } catch let error as AgentOneShotPromptError {
            throw error
        } catch is CancellationError {
            throw AgentOneShotPromptError.cancelled(harnessId: request.harnessId)
        } catch {
            throw AgentOneShotPromptError.commandLaunchFailed(
                harnessId: request.harnessId,
                reason: error.localizedDescription
            )
        }
    }

    private func runWithTimeout(
        _ command: ShellCommand,
        timeout: TimeInterval?,
        harnessId: AgentHarnessID
    ) async throws -> ShellCommandResult {
        try await withThrowingTaskGroup(of: ShellCommandResult.self) { group in
            group.addTask {
                try await shellRunner.run(command)
            }
            if let timeout {
                group.addTask {
                    let seconds = max(timeout, 0)
                    let nanoseconds = UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
                    try await Task.sleep(nanoseconds: nanoseconds)
                    throw AgentOneShotPromptError.timedOut(harnessId: harnessId, timeout: timeout)
                }
            }
            guard let result = try await group.next() else {
                throw AgentOneShotPromptError.emptyOutput(harnessId: harnessId, stdout: "", stderr: "")
            }
            group.cancelAll()
            return result
        }
    }

    private func classifyFailure(
        harnessId: AgentHarnessID,
        result: ShellCommandResult
    ) -> AgentOneShotPromptError {
        let message = diagnosticMessage(stdout: result.stdout, stderr: result.stderr)
        let normalized = message.lowercased()
        if normalized.contains("model") && (normalized.contains("unavailable") || normalized.contains("not available")) {
            return .unavailableModel(harnessId: harnessId, message: message)
        }
        if normalized.contains("approval") ||
            (normalized.contains("permission") && (normalized.contains("denied") || normalized.contains("required"))) {
            return .approvalRequired(harnessId: harnessId, message: message)
        }
        if normalized.contains("askuserquestion") ||
            (normalized.contains("prompt") && (normalized.contains("required") || normalized.contains("requested"))) {
            return .promptRequired(harnessId: harnessId, message: message)
        }
        return .commandFailed(
            harnessId: harnessId,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    private func diagnosticMessage(stdout: String, stderr: String) -> String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

import Foundation

/// Tool policy for a sessionless one-shot provider prompt.
public enum AgentOneShotToolPolicy: String, Codable, Equatable, Sendable {
    /// Allow provider-native file inspection tools only.
    case readOnly
}

/// Request for a provider prompt that should not create a runtime conversation.
public struct AgentOneShotPromptRequest: Codable, Equatable, Sendable {
    /// Provider to invoke.
    public let providerId: AgentProviderID
    /// Working directory for the provider process.
    public let workingDirectory: URL
    /// Prompt text written to provider stdin.
    public let prompt: String
    /// Additional provider arguments. Safety flags from `toolPolicy` remain authoritative.
    public let arguments: [String]
    /// Environment overrides.
    public let environment: [String: String]
    /// Optional model name.
    public let model: String?
    /// Optional provider effort setting.
    public let effort: String?
    /// Maximum time to wait for the provider command.
    public let timeout: TimeInterval?
    /// Tool policy for the one-shot prompt.
    public let toolPolicy: AgentOneShotToolPolicy

    /// Creates a one-shot prompt request.
    public init(
        providerId: AgentProviderID,
        workingDirectory: URL,
        prompt: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        model: String? = nil,
        effort: String? = nil,
        timeout: TimeInterval? = nil,
        toolPolicy: AgentOneShotToolPolicy = .readOnly
    ) {
        self.providerId = providerId
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.arguments = arguments
        self.environment = environment
        self.model = model
        self.effort = effort
        self.timeout = timeout
        self.toolPolicy = toolPolicy
    }
}

/// Result from a completed one-shot provider prompt.
public struct AgentOneShotPromptResult: Codable, Equatable, Sendable {
    /// Provider that produced the result.
    public let providerId: AgentProviderID
    /// Final assistant text.
    public let text: String
    /// Raw provider stdout.
    public let stdout: String
    /// Raw provider stderr diagnostics.
    public let stderr: String

    /// Creates a one-shot prompt result.
    public init(providerId: AgentProviderID, text: String, stdout: String, stderr: String) {
        self.providerId = providerId
        self.text = text
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Errors thrown by sessionless one-shot prompt runners.
public enum AgentOneShotPromptError: Error, Equatable, Sendable, LocalizedError {
    /// The provider is not supported by the runner.
    case unsupportedProvider(AgentProviderID)
    /// The requested tool policy is unsupported.
    case unsupportedToolPolicy(AgentProviderID, AgentOneShotToolPolicy)
    /// The provider command could not be launched.
    case commandLaunchFailed(providerId: AgentProviderID, reason: String)
    /// The provider command exited unsuccessfully.
    case commandFailed(providerId: AgentProviderID, exitCode: Int32, stdout: String, stderr: String)
    /// The provider command exceeded its timeout.
    case timedOut(providerId: AgentProviderID, timeout: TimeInterval)
    /// The one-shot task was cancelled.
    case cancelled(providerId: AgentProviderID)
    /// The provider reported that a selected model is unavailable.
    case unavailableModel(providerId: AgentProviderID, message: String)
    /// The provider asked for an approval, which one-shot read-only runs cannot service.
    case approvalRequired(providerId: AgentProviderID, message: String)
    /// The provider asked a user prompt, which one-shot runs cannot service.
    case promptRequired(providerId: AgentProviderID, message: String)
    /// The provider exited successfully but did not produce final assistant text.
    case emptyOutput(providerId: AgentProviderID, stdout: String, stderr: String)
    /// The provider stdout was not valid for its declared structured output mode.
    case malformedOutput(providerId: AgentProviderID, message: String, stdout: String, stderr: String)
    /// The provider reported an error through structured output.
    case providerReportedError(providerId: AgentProviderID, message: String, stdout: String, stderr: String)

    /// Human-readable description suitable for diagnostics and host UI.
    public var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(providerId):
            "Provider '\(providerId.rawValue)' does not support one-shot prompts."
        case let .unsupportedToolPolicy(providerId, toolPolicy):
            "Provider '\(providerId.rawValue)' does not support one-shot tool policy '\(toolPolicy.rawValue)'."
        case let .commandLaunchFailed(providerId, reason):
            "Could not launch '\(providerId.rawValue)' one-shot prompt: \(reason)"
        case let .commandFailed(providerId, exitCode, _, stderr):
            "Provider '\(providerId.rawValue)' one-shot prompt failed with exit code \(exitCode). \(stderr)"
        case let .timedOut(providerId, timeout):
            "Provider '\(providerId.rawValue)' one-shot prompt timed out after \(timeout) seconds."
        case let .cancelled(providerId):
            "Provider '\(providerId.rawValue)' one-shot prompt was cancelled."
        case let .unavailableModel(providerId, message):
            "Provider '\(providerId.rawValue)' model is unavailable. \(message)"
        case let .approvalRequired(providerId, message):
            "Provider '\(providerId.rawValue)' requested approval during a read-only one-shot prompt. \(message)"
        case let .promptRequired(providerId, message):
            "Provider '\(providerId.rawValue)' requested user input during a one-shot prompt. \(message)"
        case let .emptyOutput(providerId, _, stderr):
            "Provider '\(providerId.rawValue)' one-shot prompt completed without final output. \(stderr)"
        case let .malformedOutput(providerId, message, _, stderr):
            "Provider '\(providerId.rawValue)' one-shot prompt returned malformed structured output. \(message) \(stderr)"
        case let .providerReportedError(providerId, message, _, stderr):
            "Provider '\(providerId.rawValue)' one-shot prompt reported an error. \(message) \(stderr)"
        }
    }
}

/// Service that runs a single provider prompt without creating a runtime conversation.
public protocol AgentOneShotPromptRunning: Sendable {
    /// Runs a one-shot provider prompt and returns the final assistant text.
    func generate(_ request: AgentOneShotPromptRequest) async throws -> AgentOneShotPromptResult
}

/// Default CLI-backed one-shot prompt runner.
public struct DefaultAgentOneShotPromptRunner: AgentOneShotPromptRunning {
    private let shellRunner: any ShellRunning
    private let adapters: [AgentProviderID: any AgentProviderAdapter]

    /// Creates a CLI-backed one-shot prompt runner.
    /// - Parameters:
    ///   - adapterSet: Provider adapters used to construct and parse one-shot provider commands.
    ///   - shellRunner: Runner used for the provider command.
    public init(
        adapterSet: AgentProviderAdapterSet = .default,
        shellRunner: any ShellRunning = ProcessShellRunner()
    ) {
        self.shellRunner = shellRunner
        self.adapters = Dictionary(adapterSet.adapters.map { ($0.definition.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Creates a CLI-backed one-shot prompt runner from explicit provider adapters.
    public init(
        adapters: [any AgentProviderAdapter],
        shellRunner: any ShellRunning = ProcessShellRunner()
    ) {
        self.init(adapterSet: AgentProviderAdapterSet(adapters: adapters), shellRunner: shellRunner)
    }

    /// Runs a one-shot provider prompt and returns the final assistant text.
    public func generate(_ request: AgentOneShotPromptRequest) async throws -> AgentOneShotPromptResult {
        guard request.toolPolicy == .readOnly else {
            throw AgentOneShotPromptError.unsupportedToolPolicy(request.providerId, request.toolPolicy)
        }
        guard let adapter = adapters[request.providerId] else {
            throw AgentOneShotPromptError.unsupportedProvider(request.providerId)
        }

        let command = try await adapter.makeOneShotPromptCommand(request: request)
        let result = try await run(command, request: request)
        if result.exitCode != 0 {
            throw classifyFailure(providerId: request.providerId, result: result)
        }

        let text = try await adapter.finalOneShotPromptText(stdout: result.stdout, stderr: result.stderr, request: request)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentOneShotPromptError.emptyOutput(
                providerId: request.providerId,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        return AgentOneShotPromptResult(providerId: request.providerId, text: trimmed, stdout: result.stdout, stderr: result.stderr)
    }

    private func run(_ command: ShellCommand, request: AgentOneShotPromptRequest) async throws -> ShellCommandResult {
        do {
            return try await runWithTimeout(command, timeout: request.timeout, providerId: request.providerId)
        } catch let error as AgentOneShotPromptError {
            throw error
        } catch is CancellationError {
            throw AgentOneShotPromptError.cancelled(providerId: request.providerId)
        } catch {
            throw AgentOneShotPromptError.commandLaunchFailed(
                providerId: request.providerId,
                reason: error.localizedDescription
            )
        }
    }

    private func runWithTimeout(
        _ command: ShellCommand,
        timeout: TimeInterval?,
        providerId: AgentProviderID
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
                    throw AgentOneShotPromptError.timedOut(providerId: providerId, timeout: timeout)
                }
            }
            guard let result = try await group.next() else {
                throw AgentOneShotPromptError.emptyOutput(providerId: providerId, stdout: "", stderr: "")
            }
            group.cancelAll()
            return result
        }
    }

    private func classifyFailure(
        providerId: AgentProviderID,
        result: ShellCommandResult
    ) -> AgentOneShotPromptError {
        let message = diagnosticMessage(stdout: result.stdout, stderr: result.stderr)
        let normalized = message.lowercased()
        if normalized.contains("model") && (normalized.contains("unavailable") || normalized.contains("not available")) {
            return .unavailableModel(providerId: providerId, message: message)
        }
        if normalized.contains("approval") ||
            (normalized.contains("permission") && (normalized.contains("denied") || normalized.contains("required"))) {
            return .approvalRequired(providerId: providerId, message: message)
        }
        if normalized.contains("askuserquestion") ||
            (normalized.contains("prompt") && (normalized.contains("required") || normalized.contains("requested"))) {
            return .promptRequired(providerId: providerId, message: message)
        }
        return .commandFailed(
            providerId: providerId,
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

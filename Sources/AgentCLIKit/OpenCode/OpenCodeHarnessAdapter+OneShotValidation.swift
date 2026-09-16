import Foundation

/// Validate selection in the already-isolated profile so native config loading cannot execute user extensions.
extension OpenCodeHarnessAdapter {
    func validateOneShotSelection(_ command: ShellCommand, model: String, effort: String?, timeout: TimeInterval?) async throws {
        let version = try await oneShotProbe(command, arguments: ["--version"], timeout: timeout)
        try OpenCodeVersionSupport.validate(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let provider = String(model.prefix { $0 != "/" })
        let catalog = try await oneShotProbe(command, arguments: ["models", provider, "--verbose"], timeout: timeout)
        guard let metadata = try Self.oneShotModelMetadata(catalog.stdout, model: model) else {
            throw AgentOneShotPromptError.unavailableModel(harnessId: .opencode, message: "The selected model is unavailable: \(model)")
        }
        try OpenCodeOneShotProviderConfiguration.validateSDK(metadata[oc: "api"]?[oc: "npm"]?.ocString)
        if let effort {
            guard let variant = metadata[oc: "variants"]?[oc: effort], variant[oc: "disabled"] != .bool(true) else {
                throw AgentCLIError.invalidInput("The selected OpenCode model does not support variant '\(effort)'.")
            }
        }
    }

    private func oneShotProbe(_ command: ShellCommand, arguments: [String], timeout: TimeInterval?) async throws -> ShellCommandResult {
        let probe = ShellCommand(
            executable: command.executable, arguments: arguments, environment: command.environment, inheritsEnvironment: false,
            workingDirectory: command.workingDirectory, standardInput: ""
        )
        let limit = min(max(timeout ?? 20, 0), 20)
        return try await withThrowingTaskGroup(of: ShellCommandResult.self) { group in
            group.addTask { try await configuration.oneShotShellRunner.run(probe) }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw AgentOneShotPromptError.timedOut(harnessId: .opencode, timeout: limit)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            guard result.exitCode == 0 else {
                throw AgentOneShotPromptError.commandFailed(
                    harnessId: .opencode, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr
                )
            }
            return result
        }
    }

    /// The native verbose catalog emits a model identity followed by pretty-printed JSON, with its closing brace at column zero.
    static func oneShotModelMetadata(_ output: String, model: String) throws -> JSONValue? {
        // Split only native record boundaries, preserving Unicode line separators inside model metadata strings.
        let lines = output.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let start = lines.firstIndex(of: model), start + 1 < lines.count, lines[start + 1] == "{" else { return nil }
        guard let end = lines[(start + 1)...].firstIndex(of: "}") else {
            throw AgentOneShotPromptError.malformedOutput(
                harnessId: .opencode, message: "Incomplete native model metadata.", stdout: output, stderr: ""
            )
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(lines[(start + 1)...end].joined(separator: "\n").utf8))
    }
}

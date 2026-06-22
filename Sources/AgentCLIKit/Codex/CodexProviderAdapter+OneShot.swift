import Foundation

extension CodexProviderAdapter {
    /// Builds a Codex CLI command for a sessionless one-shot prompt. This intentionally bypasses Codex App Server.
    public func makeOneShotPromptCommand(request: AgentOneShotPromptRequest) async throws -> ShellCommand {
        let resolvedConfiguration = await configuration.resolvingExecutableIfNeeded(for: definition)
        var arguments = resolvedConfiguration.executablePath == "/usr/bin/env" ? ["codex"] : []
        arguments.append(contentsOf: request.arguments)
        arguments.append(contentsOf: [
            "exec",
            "--ephemeral",
            "--json",
            "--sandbox",
            "read-only",
            "-c",
            "approval_policy=\"never\"",
            "-C",
            request.workingDirectory.path
        ])
        if let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty,
           model.lowercased() != "default" {
            arguments.append(contentsOf: ["-m", model])
        }
        if let effort = request.effort?.trimmingCharacters(in: .whitespacesAndNewlines),
           !effort.isEmpty {
            arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
        arguments.append("-")

        var environment = request.environment
        environment.merge(resolvedConfiguration.environment) { current, _ in current }
        if let codexHomeDirectory = resolvedConfiguration.codexHomeDirectory {
            environment["CODEX_HOME"] = codexHomeDirectory.path
        }
        return ShellCommand(
            executable: resolvedConfiguration.executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: request.workingDirectory,
            standardInput: request.prompt
        )
    }

    /// Extracts final assistant text from Codex JSONL produced by a sessionless one-shot prompt.
    public func finalOneShotPromptText(
        stdout: String,
        stderr: String,
        request: AgentOneShotPromptRequest
    ) async throws -> String {
        var finalText: String?
        for line in stdout.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let object = try Self.oneShotJSONObject(from: trimmed, stdout: stdout, stderr: stderr)
            if object["type"] as? String == "item.completed",
               let item = object["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = item["text"] as? String {
                finalText = text
            } else if object["type"] as? String == "agent_message",
                      let text = object["text"] as? String {
                finalText = text
            }
        }
        return finalText ?? ""
    }

    private static func oneShotJSONObject(
        from line: String,
        stdout: String,
        stderr: String
    ) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw AgentOneShotPromptError.malformedOutput(
                providerId: .codex,
                message: "Could not encode stdout line as UTF-8.",
                stdout: stdout,
                stderr: stderr
            )
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentOneShotPromptError.malformedOutput(
                    providerId: .codex,
                    message: "Expected a JSON object line.",
                    stdout: stdout,
                    stderr: stderr
                )
            }
            return object
        } catch let error as AgentOneShotPromptError {
            throw error
        } catch {
            throw AgentOneShotPromptError.malformedOutput(
                providerId: .codex,
                message: error.localizedDescription,
                stdout: stdout,
                stderr: stderr
            )
        }
    }
}

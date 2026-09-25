import Foundation

extension ClaudeHarnessAdapter {
    /// Builds a Claude command for a sessionless one-shot prompt.
    public func makeOneShotPromptCommand(request: AgentOneShotPromptRequest) async throws -> ShellCommand {
        let launchExecutable = await resolvedLaunchExecutable()
        var arguments = launchExecutable.arguments
        arguments.append(contentsOf: request.arguments)
        arguments.append(contentsOf: [
            "-p",
            "--safe-mode",
            "--no-session-persistence",
            "--output-format",
            "stream-json",
            "--input-format",
            "text",
            "--verbose",
            "--permission-mode",
            "default",
            "--tools",
            "Read,Grep,Glob,LS",
            "--model",
            ClaudeModelAliases.normalizedModel(request.model)
        ])
        if let effort = ClaudeModelAliases.normalizedEffort(request.effort, model: request.model) {
            arguments.append(contentsOf: ["--effort", effort])
        }
        return ShellCommand(
            executable: launchExecutable.executable,
            arguments: arguments,
            environment: request.environment,
            workingDirectory: request.workingDirectory,
            standardInput: request.prompt
        )
    }

    /// Extracts final assistant text from Claude stream JSON produced by a sessionless one-shot prompt.
    public func finalOneShotPromptText(
        stdout: String,
        stderr: String,
        request: AgentOneShotPromptRequest
    ) async throws -> String {
        var finalResult: String?
        var assistantText: [String] = []
        for line in stdout.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let object = try Self.oneShotJSONObject(from: trimmed, stdout: stdout, stderr: stderr)
            if object["type"] as? String == "result" {
                let message = (object["result"] as? String) ?? ""
                if object["is_error"] as? Bool == true {
                    throw Self.classifiedOneShotStructuredError(message: message, stdout: stdout, stderr: stderr)
                }
                if !message.isEmpty {
                    finalResult = message
                }
            }
            if object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                assistantText.append(contentsOf: content.compactMap { item in
                    guard item["type"] as? String == "text" else {
                        return nil
                    }
                    return item["text"] as? String
                })
            }
        }
        return finalResult ?? assistantText.joined(separator: "\n")
    }

    private static func oneShotJSONObject(
        from line: String,
        stdout: String,
        stderr: String
    ) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw AgentOneShotPromptError.malformedOutput(
                harnessId: .claude,
                message: "Could not encode stdout line as UTF-8.",
                stdout: stdout,
                stderr: stderr
            )
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentOneShotPromptError.malformedOutput(
                    harnessId: .claude,
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
                harnessId: .claude,
                message: error.localizedDescription,
                stdout: stdout,
                stderr: stderr
            )
        }
    }

    private static func classifiedOneShotStructuredError(
        message: String,
        stdout: String,
        stderr: String
    ) -> AgentOneShotPromptError {
        let result = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = [result, stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        // `harnessReportedError` describes itself with stderr appended, so its message carries only the result text.
        return AgentOneShotPromptError.classified(harnessId: .claude, message: fallback)
            ?? .harnessReportedError(harnessId: .claude, message: result, stdout: stdout, stderr: stderr)
    }
}

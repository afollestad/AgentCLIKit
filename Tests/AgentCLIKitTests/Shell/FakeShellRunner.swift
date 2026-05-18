import Foundation

@testable import AgentCLIKit

actor FakeShellRunner: ShellRunning {
    enum Response: Sendable {
        case success(ShellCommandResult)
        case failure(AgentCLIError)
    }

    private var results: [ShellCommand: Response]
    private var recordedCommands: [ShellCommand] = []

    init(results: [ShellCommand: Response] = [:]) {
        self.results = results
    }

    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        recordedCommands.append(command)
        guard let response = results[command] else {
            return ShellCommandResult(exitCode: 127, stdout: "", stderr: "command not found")
        }
        switch response {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        }
    }

    func commands() -> [ShellCommand] {
        recordedCommands
    }
}

import Foundation

@testable import AgentCLIKit

struct FakeProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: "fake", displayName: "Fake", executableNames: ["fake"])
    var command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line == "malformed" {
            throw AgentCLIError.invalidInput("Malformed fake stdout.")
        }
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        return [.rawOutput(AgentRawOutputEvent(text: line, isComplete: true))]
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        switch input {
        case let .userMessage(message):
            return Data((message.text + "\n").utf8)
        case .interrupt:
            return Data("interrupt\n".utf8)
        case let .interactionResolution(resolution):
            return Data(((resolution.responseText ?? resolution.outcome.rawValue) + "\n").utf8)
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }
        return String(dropFirst(prefix.count))
    }
}

import Foundation

@testable import AgentCLIKit

struct FakeProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
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
        if line == "interaction:prompt" {
            return [.interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?"))]
        }
        if line == "compact:started" {
            return [.contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .started, trigger: "auto"))]
        }
        if line == "compact:completed" {
            return [.contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .completed, summary: "Retained recent context."))]
        }
        if line == "subagent:started" {
            return [.subAgent(AgentSubAgentEvent(id: "agent-1", phase: .started, description: "Review docs"))]
        }
        if line == "subagent:progress" {
            return [.subAgent(AgentSubAgentEvent(id: "agent-1", phase: .progress, description: "Review docs", status: "running"))]
        }
        if line == "subagent:progress-metadata" {
            return [.subAgent(AgentSubAgentEvent(
                id: "agent-1",
                phase: .progress,
                description: "Review docs",
                status: "running",
                metadata: ["agents_states": .object(["agent-1": .object(["message": .string("Writing")])])]
            ))]
        }
        if line == "subagent:progress2" {
            return [.subAgent(AgentSubAgentEvent(id: "agent-1", phase: .progress, description: "Review docs", status: "writing"))]
        }
        if line == "subagent:terminal" {
            return [.subAgent(AgentSubAgentEvent(
                id: "agent-1",
                phase: .terminal,
                description: "Review docs",
                status: "completed",
                result: "Done"
            ))]
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

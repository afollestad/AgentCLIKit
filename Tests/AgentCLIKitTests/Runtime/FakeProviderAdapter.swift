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
        if let events = controlEvents(for: line) ?? subAgentEvents(for: line) {
            return events
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

private extension FakeProviderAdapter {
    func controlEvents(for line: String) -> [AgentEvent]? {
        switch line {
        case "interaction:prompt":
            [.interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?"))]
        case "compact:started":
            [.contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .started, trigger: "auto"))]
        case "compact:completed":
            [.contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .completed, summary: "Retained recent context."))]
        case "usage:end_turn":
            [.usage(AgentUsageEvent(model: nil, inputTokens: nil, outputTokens: nil, stopReason: "stop", isTerminal: true))]
        case "activity:codex-turn-completed":
            [.activity(AgentActivityEvent(
                state: .idle,
                turnId: "turn-1",
                metadata: ["codex_method": .string("turn/completed")]
            ))]
        default:
            nil
        }
    }

    func subAgentEvents(for line: String) -> [AgentEvent]? {
        switch line {
        case "subagent:started":
            [.subAgent(AgentSubAgentEvent(id: "agent-1", phase: .started, description: "Review docs"))]
        case "subagent:codex-spawn-started":
            [.subAgent(codexSpawnStartedEvent())]
        case "subagent:progress":
            [.subAgent(AgentSubAgentEvent(id: "agent-1", phase: .progress, description: "Review docs", status: "running"))]
        case "subagent:progress-metadata":
            [.subAgent(AgentSubAgentEvent(
                id: "agent-1",
                phase: .progress,
                description: "Review docs",
                status: "running",
                metadata: ["agents_states": .object(["agent-1": .object(["message": .string("Writing")])])]
            ))]
        case "subagent:progress2":
            [.subAgent(AgentSubAgentEvent(id: "agent-1", phase: .progress, description: "Review docs", status: "writing"))]
        case "subagent:terminal":
            [.subAgent(AgentSubAgentEvent(
                id: "agent-1",
                phase: .terminal,
                description: "Review docs",
                status: "completed",
                result: "Done"
            ))]
        default:
            nil
        }
    }

    func codexSpawnStartedEvent() -> AgentSubAgentEvent {
        AgentSubAgentEvent(
            id: "agent-1",
            phase: .started,
            description: "Review docs",
            prompt: "Review docs",
            agentType: "codex",
            input: .object([
                "description": .string("Review docs"),
                "prompt": .string("Review docs"),
                "subagent_type": .string("codex"),
                "codex_collab_tool": .string("spawn_agent")
            ]),
            lastToolName: "spawn_agent",
            metadata: ["codex_collab_tool": .string("spawn_agent")]
        )
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

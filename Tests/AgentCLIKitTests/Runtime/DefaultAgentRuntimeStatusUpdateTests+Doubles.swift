import Foundation

@testable import AgentCLIKit

// Provider doubles and status collectors shared by the status-update test files.

actor StatusAccumulator {
    private(set) var statuses: [AgentRuntimeStatus] = []

    func append(_ status: AgentRuntimeStatus) {
        statuses.append(status)
    }
}

actor ProviderActivitySource {
    private var continuation: AsyncStream<AgentProviderRuntimeEvent>.Continuation?
    var isReady: Bool {
        continuation != nil
    }

    func stream() -> AsyncStream<AgentProviderRuntimeEvent> {
        let stream = AsyncStream<AgentProviderRuntimeEvent>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }

    func emit(_ event: AgentProviderRuntimeEvent) {
        continuation?.yield(event)
    }
}

struct StatusReportingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(
        id: .claude,
        displayName: "Fake",
        executableNames: ["fake"],
        capabilities: AgentProviderCapabilities(supportsGoalMode: true, supportedGoalActions: [.pause])
    )
    let command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line.hasPrefix("permission:") {
            let mode = String(line.dropFirst("permission:".count))
            return [.permissionMode(AgentPermissionModeEvent(mode: mode))]
        }
        if line.hasPrefix("collaboration:") {
            let mode = String(line.dropFirst("collaboration:".count))
            return AgentCollaborationMode(rawValue: mode).map { [.collaborationMode(AgentCollaborationModeEvent(mode: $0))] } ?? []
        }
        if line == "interaction:prompt" {
            return [.interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?"))]
        }
        if line.hasPrefix("goal:") {
            let components = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count == 3, let status = AgentGoalStatus(rawValue: components[1]) else {
                return []
            }
            return [.goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: components[2],
                status: status,
                availableActions: status == .active ? [.delete] : []
            )))]
        }
        if line == "goal-cleared" {
            return [.goal(.cleared(objective: "Ship goal mode"))]
        }
        if let events = Self.backgroundTaskSentinelEvents(for: line) {
            return events
        }
        if line == "usage-terminal:nil" {
            return [.usage(AgentUsageEvent(
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                isTerminal: true
            ))]
        }
        if line.hasPrefix("usage:") {
            let stopReason = String(line.dropFirst("usage:".count))
            return [.usage(AgentUsageEvent(
                model: nil,
                inputTokens: nil,
                outputTokens: nil,
                stopReason: stopReason
            ))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        if case let .userMessage(message) = input {
            return Data((message.text + "\n").utf8)
        }
        return Data()
    }

    /// Background-task sentinels: `tasks:a,b!` announces tasks (`!` marks ambient), `task-done:a` / `task-enqueued:a`
    /// deliver a notification, and `usage:no-op` is the interim usage the Claude adapter produces for a no-op result.
    private static func backgroundTaskSentinelEvents(for line: String) -> [AgentEvent]? {
        if line.hasPrefix("tasks:") {
            let tasks = line.dropFirst("tasks:".count).split(separator: ",").map { entry -> AgentBackgroundTask in
                let isAmbient = entry.hasSuffix("!")
                return AgentBackgroundTask(id: String(isAmbient ? entry.dropLast() : entry), isAmbient: isAmbient)
            }
            return [.backgroundTasks(AgentBackgroundTasksEvent(tasks: tasks))]
        }
        if line.hasPrefix("task-done:") || line.hasPrefix("task-enqueued:") {
            let components = line.split(separator: ":", maxSplits: 1).map(String.init)
            let taskId = components[1]
            return [.subAgent(AgentSubAgentEvent(
                id: "toolu_\(taskId)",
                phase: .terminal,
                status: "completed",
                metadata: [
                    "task_id": .string(taskId),
                    "delivery": .string(components[0] == "task-done" ? "dequeued" : "enqueued")
                ]
            ))]
        }
        if line == "usage:no-op" {
            return [.usage(AgentUsageEvent(
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                stopReason: AgentUsageEvent.interimUsageStopReason,
                metadata: [AgentBackgroundTaskMetadata.noOpResult: .bool(true)]
            ))]
        }
        return nil
    }
}

struct GoalActionProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(
        id: .claude,
        displayName: "Fake",
        executableNames: ["fake"],
        capabilities: AgentProviderCapabilities(supportsGoalMode: true, supportedGoalActions: [.delete])
    )
    let command: AgentLaunchConfiguration
    var hideActionsWhileTurnActive = false

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line.hasPrefix("usage:") {
            let stopReason = String(line.dropFirst("usage:".count))
            return [.usage(AgentUsageEvent(
                model: nil,
                inputTokens: nil,
                outputTokens: nil,
                stopReason: stopReason
            ))]
        }
        if line.hasPrefix("goal:") {
            let components = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count == 3, let status = AgentGoalStatus(rawValue: components[1]) else {
                return []
            }
            return [.goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: components[2],
                status: status,
                availableActions: status == .active ? [.delete] : []
            )))]
        }
        if line == "goal-cleared" {
            return [.goal(.cleared(objective: "Ship goal mode"))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        if case let .userMessage(message) = input {
            return Data((message.text + "\n").utf8)
        }
        return Data()
    }

    func availableGoalActions(for goal: AgentGoalSnapshot, context: AgentProviderGoalActionContext) -> [AgentGoalAction] {
        guard !hideActionsWhileTurnActive || !context.isTurnActive else {
            return []
        }
        return goal.availableActions
    }

    func encodeGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws -> Data? {
        guard action == .delete else {
            throw AgentCLIError.unsupportedCapability(providerId: definition.id, capability: "goal \(action.rawValue)")
        }
        return Data("goal-clear\n".utf8)
    }
}

struct GoalStartProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(
        id: .claude,
        displayName: "Fake",
        executableNames: ["fake"],
        capabilities: AgentProviderCapabilities(
            supportsGoalMode: true,
            supportsExistingSessionGoalStart: true,
            supportedGoalActions: [.delete]
        )
    )
    let command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line.hasPrefix("goal:") {
            let components = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count == 3, let status = AgentGoalStatus(rawValue: components[1]) else {
                return []
            }
            return [.goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: components[2],
                status: status,
                availableActions: status == .active ? [.delete] : []
            )))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        if case let .userMessage(message) = input {
            return Data((message.text + "\n").utf8)
        }
        return Data()
    }

    func encodeGoalStart(_ objective: String, context: AgentProviderGoalStartContext) async throws -> AgentProviderEncodedGoalStart? {
        AgentProviderEncodedGoalStart(data: Data("goal-start:\(objective)\n".utf8), marksTurnActive: true)
    }
}

struct ActivityReportingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration
    let activitySource: ProviderActivitySource

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        await activitySource.stream()
    }
}

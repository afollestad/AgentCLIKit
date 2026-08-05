import Foundation

/// Goal, steering, and input encoding for the Claude adapter.
extension ClaudeProviderAdapter {
    public func encodeInput(_ input: AgentInput) async throws -> Data {
        try inputEncoder.encode(input)
    }

    /// Encodes host input as Claude stream JSON stdin with launch context.
    public func encodeInput(_ input: AgentInput, context: AgentProviderInputContext) async throws -> Data {
        if case let .userMessage(message) = input,
           message.metadata[AgentGoalMetadata.isInitialGoalTransport] == .bool(true),
           let objective = message.metadata.nonEmptyStringValue(AgentGoalMetadata.objective) {
            return try inputEncoder.encode(.userMessage(AgentMessageInput(text: Self.goalCommand(objective))))
        }
        return try inputEncoder.encode(input)
    }

    /// Encodes Claude's confirmed existing-session goal start surface.
    public func encodeGoalStart(_ objective: String, context: AgentProviderGoalStartContext) async throws -> AgentProviderEncodedGoalStart? {
        AgentProviderEncodedGoalStart(
            data: try inputEncoder.encode(.userMessage(AgentMessageInput(text: Self.goalCommand(objective)))),
            marksTurnActive: true
        )
    }

    /// Hides Claude goal actions when stream-json stdin cannot process them immediately.
    public func availableGoalActions(for goal: AgentGoalSnapshot, context: AgentProviderGoalActionContext) -> [AgentGoalAction] {
        guard !context.isTurnActive,
              case .available = context.inputAvailability else {
            return goal.availableActions.filter { $0 != .delete }
        }
        return goal.availableActions
    }

    /// Encodes Claude's confirmed goal clear surface. Pause/resume are intentionally unsupported.
    public func encodeGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws -> Data? {
        guard action == .delete else {
            throw AgentCLIError.unsupportedCapability(providerId: Self.providerId, capability: "goal \(action.rawValue)")
        }
        return try inputEncoder.encode(.userMessage(AgentMessageInput(text: "/goal clear")))
    }

    /// Emits a steering marker once Claude stdin accepts a marked mid-turn user input.
    public func acceptedSteeringInputEvent(for message: AgentMessageInput, context: AgentProviderInputContext) -> AgentEvent? {
        guard message.metadata[AgentSteeringMetadata.isSteering] == .bool(true),
              message.metadata.nonEmptyStringValue(AgentSteeringMetadata.inputId) != nil else {
            return nil
        }
        var metadata = message.metadata
        metadata[AgentSteeringMetadata.signal] = .string(AgentSteeringMetadata.signalRuntimeInputAccepted)
        return .message(AgentMessageEvent(role: .user, text: message.text, metadata: metadata))
    }

    /// Returns Claude hook runtime events for the active launch.
}

// Mirrors the accessor in `ClaudeProviderAdapter.swift`; several modules define same-named helpers
// fileprivate, so this one cannot be shared without colliding with them.
private extension [String: JSONValue] {
    func nonEmptyStringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

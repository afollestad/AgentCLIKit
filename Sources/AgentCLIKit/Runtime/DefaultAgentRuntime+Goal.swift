import Foundation

public extension DefaultAgentRuntime {
    /// Starts a provider-native goal in an already-running session.
    func startGoal(_ objective: String, conversationId: AgentConversationID) async throws {
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw AgentCLIError.invalidInput("Goal objective cannot be empty.")
        }
        guard let state = states[conversationId] else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        guard state.adapter.definition.capabilities.supportsExistingSessionGoalStart else {
            throw AgentCLIError.unsupportedCapability(
                providerId: state.providerId,
                capability: "existing-session goal start"
            )
        }
        if state.goal?.status.isTerminal == false {
            throw AgentCLIError.goalUnavailable(providerId: state.providerId, reason: "A goal is already active.")
        }
        if state.isTurnActive {
            throw AgentCLIError.goalUnavailable(
                providerId: state.providerId,
                reason: "Wait for the active turn to finish before starting a goal."
            )
        }
        if case let .blocked(reason) = state.inputAvailability {
            throw AgentCLIError.goalUnavailable(providerId: state.providerId, reason: "Input is blocked: \(reason)")
        }

        let adapter = state.adapter
        let processToken = state.processToken
        guard let stdinWriter = state.stdinWriter else {
            let context = try goalStartContext(conversationId: conversationId, processToken: processToken)
            if try await adapter.encodeGoalStart(objective, context: context) != nil {
                throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
            }
            try await adapter.startGoal(objective, context: context)
            return
        }
        try await stdinWriter.enqueue {
            let context = try await self.goalStartContext(conversationId: conversationId, processToken: processToken)
            if let encoded = try await adapter.encodeGoalStart(objective, context: context) {
                let markedTurnActive = try await self.markTurnActiveBeforeInputIfNeeded(
                    conversationId: conversationId,
                    processToken: processToken,
                    marksTurnActive: encoded.marksTurnActive
                )
                do {
                    try await self.writeInputData(
                        encoded.data,
                        conversationId: conversationId,
                        processToken: processToken,
                        marksTurnActive: false
                    )
                } catch {
                    if markedTurnActive {
                        await self.clearTurnActiveAfterFailedInput(conversationId: conversationId, processToken: processToken)
                    }
                    throw error
                }
                return
            }
            try await adapter.startGoal(objective, context: context)
        }
    }

    /// Performs a provider-native goal action.
    func performGoalAction(_ action: AgentGoalAction, conversationId: AgentConversationID) async throws {
        guard let state = states[conversationId] else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        guard let goal = state.goal else {
            throw AgentCLIError.goalUnavailable(providerId: state.providerId, reason: "No active goal is available.")
        }
        guard goal.availableActions.contains(action) else {
            throw AgentCLIError.goalUnavailable(
                providerId: state.providerId,
                reason: "Goal action '\(action.rawValue)' is unavailable."
            )
        }
        let context = AgentProviderGoalActionContext(
            conversationId: conversationId,
            processToken: state.processToken,
            providerSessionId: state.providerSessionId,
            spawnConfig: state.spawnConfig,
            goal: goal,
            isTurnActive: state.isTurnActive,
            inputAvailability: state.inputAvailability
        )
        guard state.adapter.availableGoalActions(for: goal, context: context).contains(action) else {
            throw AgentCLIError.goalUnavailable(
                providerId: state.providerId,
                reason: "Goal action '\(action.rawValue)' is unavailable."
            )
        }
        let adapter = state.adapter
        let processToken = state.processToken
        guard let stdinWriter = state.stdinWriter else {
            if try await adapter.encodeGoalAction(action, context: context) != nil {
                throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
            }
            try await adapter.performGoalAction(action, context: context)
            return
        }
        try await stdinWriter.enqueue {
            let context = try await self.goalActionContext(conversationId: conversationId, processToken: processToken)
            guard let goal = context.goal else {
                throw AgentCLIError.goalUnavailable(providerId: adapter.definition.id, reason: "No active goal is available.")
            }
            guard adapter.availableGoalActions(for: goal, context: context).contains(action) else {
                throw AgentCLIError.goalUnavailable(
                    providerId: adapter.definition.id,
                    reason: "Goal action '\(action.rawValue)' is unavailable."
                )
            }
            if let data = try await adapter.encodeGoalAction(action, context: context) {
                try await self.writeInputData(
                    data,
                    conversationId: conversationId,
                    processToken: processToken,
                    marksTurnActive: false
                )
                return
            }
            try await adapter.performGoalAction(action, context: context)
        }
    }
}

private extension DefaultAgentRuntime {
    func goalStartContext(
        conversationId: AgentConversationID,
        processToken: UUID
    ) throws -> AgentProviderGoalStartContext {
        guard let state = states[conversationId], state.processToken == processToken else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        guard state.adapter.definition.capabilities.supportsExistingSessionGoalStart else {
            throw AgentCLIError.unsupportedCapability(
                providerId: state.providerId,
                capability: "existing-session goal start"
            )
        }
        if state.goal?.status.isTerminal == false {
            throw AgentCLIError.goalUnavailable(providerId: state.providerId, reason: "A goal is already active.")
        }
        if state.isTurnActive {
            throw AgentCLIError.goalUnavailable(
                providerId: state.providerId,
                reason: "Wait for the active turn to finish before starting a goal."
            )
        }
        if case let .blocked(reason) = state.inputAvailability {
            throw AgentCLIError.goalUnavailable(providerId: state.providerId, reason: "Input is blocked: \(reason)")
        }
        return AgentProviderGoalStartContext(
            conversationId: conversationId,
            processToken: processToken,
            providerSessionId: state.providerSessionId,
            spawnConfig: state.spawnConfig,
            isTurnActive: state.isTurnActive,
            inputAvailability: state.inputAvailability
        )
    }

    func goalActionContext(
        conversationId: AgentConversationID,
        processToken: UUID
    ) throws -> AgentProviderGoalActionContext {
        guard let state = states[conversationId], state.processToken == processToken else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        return AgentProviderGoalActionContext(
            conversationId: conversationId,
            processToken: processToken,
            providerSessionId: state.providerSessionId,
            spawnConfig: state.spawnConfig,
            goal: state.goal,
            isTurnActive: state.isTurnActive,
            inputAvailability: state.inputAvailability
        )
    }
}

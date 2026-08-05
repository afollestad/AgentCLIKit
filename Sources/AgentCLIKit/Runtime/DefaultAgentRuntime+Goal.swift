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
        try validateGoalStartPreconditions(state: state)

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
            guard let encoded = try await adapter.encodeGoalStart(objective, context: context) else {
                try await adapter.startGoal(objective, context: context)
                return
            }
            try await self.writeGoalStartInput(
                encoded,
                conversationId: conversationId,
                processToken: processToken
            )
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
        try Self.validateGoalActionIsAvailable(action, in: goal.availableActions, providerId: state.providerId)
        let context = AgentProviderGoalActionContext(
            conversationId: conversationId,
            processToken: state.processToken,
            providerSessionId: state.providerSessionId,
            spawnConfig: state.spawnConfig,
            goal: goal,
            isTurnActive: state.isTurnActive,
            inputAvailability: state.inputAvailability
        )
        try Self.validateGoalActionIsAvailable(
            action,
            in: state.adapter.availableGoalActions(for: goal, context: context),
            providerId: state.providerId
        )
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
            // The context is re-read inside the writer queue because an earlier queued write may have
            // changed the goal, so availability is validated again against that fresh context.
            try await self.performQueuedGoalAction(
                action,
                adapter: adapter,
                conversationId: conversationId,
                processToken: processToken
            )
        }
    }
}

private extension DefaultAgentRuntime {
    /// Rejects a goal start the session cannot honor, before any provider I/O is attempted.
    func validateGoalStartPreconditions(state: ConversationState) throws {
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
    }

    func performQueuedGoalAction(
        _ action: AgentGoalAction,
        adapter: any AgentProviderAdapter,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws {
        let context = try goalActionContext(conversationId: conversationId, processToken: processToken)
        guard let goal = context.goal else {
            throw AgentCLIError.goalUnavailable(providerId: adapter.definition.id, reason: "No active goal is available.")
        }
        try Self.validateGoalActionIsAvailable(
            action,
            in: adapter.availableGoalActions(for: goal, context: context),
            providerId: adapter.definition.id
        )
        guard let data = try await adapter.encodeGoalAction(action, context: context) else {
            try await adapter.performGoalAction(action, context: context)
            return
        }
        try writeInputData(data, conversationId: conversationId, processToken: processToken, marksTurnActive: false)
    }

    static func validateGoalActionIsAvailable(
        _ action: AgentGoalAction,
        in availableActions: [AgentGoalAction],
        providerId: AgentProviderID
    ) throws {
        guard availableActions.contains(action) else {
            throw AgentCLIError.goalUnavailable(
                providerId: providerId,
                reason: "Goal action '\(action.rawValue)' is unavailable."
            )
        }
    }

    /// Marks the turn active around the write so a failed goal start cannot strand the session as busy.
    func writeGoalStartInput(
        _ encoded: AgentProviderEncodedGoalStart,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws {
        let markedTurnActive = try markTurnActiveBeforeInputIfNeeded(
            conversationId: conversationId,
            processToken: processToken,
            marksTurnActive: encoded.marksTurnActive
        )
        do {
            try writeInputData(
                encoded.data,
                conversationId: conversationId,
                processToken: processToken,
                marksTurnActive: false
            )
        } catch {
            if markedTurnActive {
                clearTurnActiveAfterFailedInput(conversationId: conversationId, processToken: processToken)
            }
            throw error
        }
    }

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

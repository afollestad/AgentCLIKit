import Foundation

extension DefaultAgentRuntime {
    func synthesizePlanModeExitIfNeeded(
        from envelope: AgentEventEnvelope,
        conversationId: AgentConversationID
    ) {
        guard case let .message(message) = envelope.event,
              message.role == .assistant,
              message.metadata.boolValue(AgentPlanProposalMetadata.isProposal) == true,
              let planMarkdown = message.proposedPlanMarkdown else {
            return
        }
        guard var state = states[conversationId],
              state.collaborationMode == .plan,
              state.waitingState == .idle else {
            return
        }
        let proposalId = message.metadata.stringValue(AgentPlanProposalMetadata.proposalId)
            ?? "\(envelope.providerId.rawValue)-\(envelope.generation)-\(envelope.index)"
        let proposalKey = Self.planRevisionKey(proposalId: proposalId, planMarkdown: planMarkdown)
        let hasPriorRevisionForProposal = state.synthesizedPlanExitProposalKeys.contains {
            $0.hasPrefix(Self.planRevisionKeyPrefix(proposalId: proposalId))
        }
        guard state.synthesizedPlanExitProposalKeys.insert(proposalKey).inserted else {
            states[conversationId] = state
            return
        }
        let interactionId = AgentInteractionID(
            rawValue: "runtime-plan-exit-\(hasPriorRevisionForProposal ? "\(proposalId)-\(envelope.generation)-\(envelope.index)" : proposalId)"
        )
        guard !state.resolvedInteractions.contains(interactionId) else {
            states[conversationId] = state
            return
        }

        state.runtimePlanExitInteractions[interactionId] = RuntimePlanExitInteraction(
            id: interactionId,
            proposalId: proposalId,
            planMarkdown: planMarkdown
        )
        states[conversationId] = state

        append(
            .interaction(AgentInteractionEvent(
                id: interactionId,
                kind: .planModeExit,
                prompt: "ExitPlanMode",
                metadata: planExitMetadata(
                    proposalId: proposalId,
                    planMarkdown: planMarkdown,
                    envelope: envelope
                )
            )),
            source: .runtime,
            conversationId: conversationId
        )
    }

    func resolveRuntimePlanExit(
        _ resolution: AgentInteractionResolution,
        conversationId: AgentConversationID
    ) async throws -> Bool {
        guard let pending = runtimePlanExitInteraction(id: resolution.id, conversationId: conversationId) else {
            return false
        }
        guard states[conversationId]?.resolvedInteractions.contains(resolution.id) != true else {
            return true
        }

        let previousWaitingState = states[conversationId]?.waitingState ?? .idle
        let previousInputAvailability = states[conversationId]?.inputAvailability ?? .available
        let previousResolvedInteractions = states[conversationId]?.resolvedInteractions ?? []
        let previousPendingInteraction = states[conversationId]?.runtimePlanExitInteractions[resolution.id]

        states[conversationId]?.resolvedInteractions.insert(resolution.id)
        states[conversationId]?.waitingState = .idle
        states[conversationId]?.inputAvailability = .available
        states[conversationId]?.runtimePlanExitInteractions[resolution.id] = nil
        publishStatus(conversationId: conversationId)

        do {
            switch resolution.outcome {
            case .approved, .answered:
                try stageApprovedPlanImplementation(
                    pending: pending,
                    resolution: resolution,
                    conversationId: conversationId
                )
                try await drainPendingPlanImplementationIfReady(conversationId: conversationId)
            case .denied, .deferred, .cancelled:
                break
            }
        } catch {
            states[conversationId]?.resolvedInteractions = previousResolvedInteractions
            states[conversationId]?.waitingState = previousWaitingState
            states[conversationId]?.inputAvailability = previousInputAvailability
            if let previousPendingInteraction {
                states[conversationId]?.runtimePlanExitInteractions[resolution.id] = previousPendingInteraction
            }
            publishStatus(conversationId: conversationId)
            throw error
        }
        return true
    }

    func providerPlanExitInteraction(
        id: AgentInteractionID,
        conversationId: AgentConversationID
    ) -> RuntimePlanExitInteraction? {
        guard let envelope = states[conversationId]?.events.last(where: { envelope in
            guard case let .interaction(interaction) = envelope.event else {
                return false
            }
            return interaction.id == id && interaction.kind == .planModeExit
        }),
              case let .interaction(interaction) = envelope.event else {
            return nil
        }
        return planExitInteraction(from: interaction)
    }

    private func planExitMetadata(
        proposalId: String,
        planMarkdown: String,
        envelope: AgentEventEnvelope
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            AgentPlanProposalMetadata.isProposal: .bool(true),
            AgentPlanProposalMetadata.proposalId: .string(proposalId),
            AgentPlanProposalMetadata.planMarkdown: .string(planMarkdown),
            "agent_plan_interaction_source": .string("runtime"),
            "provider_id": .string(envelope.providerId.rawValue),
            "tool_name": .string("ExitPlanMode"),
            "tool_input": .object(["plan": .string(planMarkdown)]),
            "plan": .string(planMarkdown)
        ]
        if let providerSessionId = envelope.providerSessionId?.rawValue {
            metadata["session_id"] = .string(providerSessionId)
        }
        return metadata
    }

    private func runtimePlanExitInteraction(
        id: AgentInteractionID,
        conversationId: AgentConversationID
    ) -> RuntimePlanExitInteraction? {
        if let pending = states[conversationId]?.runtimePlanExitInteractions[id] {
            return pending
        }
        guard let envelope = states[conversationId]?.events.last(where: { envelope in
            guard case let .interaction(interaction) = envelope.event else {
                return false
            }
            return interaction.id == id &&
                interaction.kind == .planModeExit &&
                interaction.metadata.stringValue("agent_plan_interaction_source") == "runtime"
        }),
              case let .interaction(interaction) = envelope.event,
              let pending = planExitInteraction(from: interaction) else {
            return nil
        }
        return pending
    }

    private func planExitInteraction(from interaction: AgentInteractionEvent) -> RuntimePlanExitInteraction? {
        guard let planMarkdown = planMarkdown(from: interaction) else {
            return nil
        }
        return RuntimePlanExitInteraction(
            id: interaction.id,
            proposalId: planExitProposalId(from: interaction),
            planMarkdown: planMarkdown
        )
    }

    private func planMarkdown(from interaction: AgentInteractionEvent) -> String? {
        interaction.metadata.stringValue(AgentPlanProposalMetadata.planMarkdown)
            ?? interaction.metadata.stringValue("plan")
            ?? interaction.metadata.objectValue("tool_input")?.stringValue("plan")
    }

    private func planExitProposalId(from interaction: AgentInteractionEvent) -> String {
        interaction.metadata.stringValue(AgentPlanProposalMetadata.proposalId)
            ?? interaction.metadata.stringValue("codex_tool_call_id")
            ?? interaction.metadata.stringValue("codex_item_id")
            ?? interaction.id.rawValue
    }

    func stageApprovedPlanImplementation(
        pending: RuntimePlanExitInteraction,
        resolution: AgentInteractionResolution,
        conversationId: AgentConversationID
    ) throws {
        guard let state = states[conversationId] else {
            throw AgentCLIError.invalidInput("No running process for conversation '\(conversationId.rawValue)'.")
        }
        let implementationKey = Self.planRevisionKey(proposalId: pending.proposalId, planMarkdown: pending.planMarkdown)
        guard state.completedPlanImplementationKeys.contains(implementationKey) == false,
              state.pendingPlanImplementationStart?.implementationKey != implementationKey else {
            return
        }
        let updatedConfig = state.spawnConfig.withCollaborationMode(.default)
        states[conversationId]?.pendingPlanImplementationStart = PendingPlanImplementationStart(
            interactionId: pending.id,
            implementationKey: implementationKey,
            proposalId: pending.proposalId,
            planMarkdown: pending.planMarkdown,
            prompt: implementationPrompt(resolution),
            targetConfig: updatedConfig
        )
    }

    func drainPendingPlanImplementationIfReady(conversationId: AgentConversationID) async throws {
        guard let state = states[conversationId],
              let pending = state.pendingPlanImplementationStart,
              state.completedPlanImplementationKeys.contains(pending.implementationKey) == false,
              !state.isTurnActive else {
            return
        }

        if state.spawnConfig != pending.targetConfig {
            let result = try await reconfigure(conversationId: conversationId, config: pending.targetConfig)
            if result == .nextTurnRequired {
                stageNextTurnPlanImplementationConfig(pending.targetConfig, conversationId: conversationId)
                return
            }
        }

        guard states[conversationId]?.pendingPlanImplementationStart?.implementationKey == pending.implementationKey else {
            return
        }
        states[conversationId]?.pendingPlanImplementationStart = nil
        states[conversationId]?.completedPlanImplementationKeys.insert(pending.implementationKey)
        do {
            let message = AgentMessageInput(
                text: pending.prompt,
                metadata: implementationMetadata(pending)
            )
            try await send(.userMessage(message), conversationId: conversationId)
            append(
                .message(AgentMessageEvent(role: .user, text: pending.prompt, metadata: implementationMetadata(pending))),
                source: .runtime,
                conversationId: conversationId
            )
        } catch {
            states[conversationId]?.pendingPlanImplementationStart = pending
            states[conversationId]?.completedPlanImplementationKeys.remove(pending.implementationKey)
            throw error
        }
    }

    func schedulePendingPlanImplementationDrainIfNeeded(conversationId: AgentConversationID) {
        guard states[conversationId]?.pendingPlanImplementationStart != nil else {
            return
        }
        Task {
            do {
                try await self.drainPendingPlanImplementationIfReady(conversationId: conversationId)
            } catch {
                self.appendPlanImplementationFailure(error, conversationId: conversationId)
            }
        }
    }

    private func stageNextTurnPlanImplementationConfig(
        _ config: AgentSpawnConfig,
        conversationId: AgentConversationID
    ) {
        guard states[conversationId] != nil else {
            return
        }
        states[conversationId]?.spawnConfig = config
        states[conversationId]?.permissionMode = config.permissionMode
        states[conversationId]?.collaborationMode = config.collaborationMode
        publishStatus(conversationId: conversationId)
    }

    private func implementationMetadata(_ pending: PendingPlanImplementationStart) -> [String: JSONValue] {
        [
            "agent_plan_exit_interaction_id": .string(pending.interactionId.rawValue),
            AgentPlanProposalMetadata.proposalId: .string(pending.proposalId),
            AgentPlanProposalMetadata.planMarkdown: .string(pending.planMarkdown)
        ]
    }

    func appendPlanImplementationFailure(_ error: Error, conversationId: AgentConversationID) {
        append(.diagnostic(AgentDiagnosticEvent(
            code: .planImplementationStartFailed,
            severity: .error,
            message: "Could not start approved plan implementation: \(error.localizedDescription)"
        )), source: .runtime, conversationId: conversationId)
    }

    private func implementationPrompt(_ resolution: AgentInteractionResolution) -> String {
        if let responseText = resolution.responseText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !responseText.isEmpty {
            return "Implement plan with this additional instruction:\n\n\(responseText)"
        }
        return "Implement plan"
    }

    private static func planRevisionKey(proposalId: String, planMarkdown: String) -> String {
        planRevisionKeyPrefix(proposalId: proposalId) + planMarkdown
    }

    private static func planRevisionKeyPrefix(proposalId: String) -> String {
        "\(proposalId)\u{1F}"
    }
}

private extension AgentMessageEvent {
    var proposedPlanMarkdown: String? {
        let text = metadata.stringValue(AgentPlanProposalMetadata.planMarkdown) ?? self.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension AgentSpawnConfig {
    func withCollaborationMode(_ collaborationMode: AgentCollaborationMode?) -> AgentSpawnConfig {
        AgentSpawnConfig(
            providerId: providerId,
            workingDirectory: workingDirectory,
            arguments: arguments,
            environment: environment,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            collaborationMode: collaborationMode,
            speedMode: speedMode,
            sessionFork: sessionFork,
            forkSession: forkSession,
            initialPrompt: initialPrompt
        )
    }
}

private extension [String: JSONValue] {
    func stringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    func boolValue(_ key: String) -> Bool? {
        guard case let .bool(value)? = self[key] else {
            return nil
        }
        return value
    }

    func objectValue(_ key: String) -> [String: JSONValue]? {
        guard case let .object(value)? = self[key] else {
            return nil
        }
        return value
    }
}

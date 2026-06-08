import Foundation

private struct ProviderSessionSaveFailure {
    let record: AgentSessionRecord
    let processToken: UUID
    let error: Error
}

private struct ProviderSessionStateUpdate {
    var state: ConversationState
    let providerSessionId: AgentSessionID
    let createdAt: Date
}

extension DefaultAgentRuntime {
    func recordProviderSessionIfNeeded(
        from event: AgentEvent,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        guard
            let update = providerSessionStateUpdate(from: event, conversationId: conversationId, processToken: processToken)
        else {
            return
        }

        states[conversationId] = update.state
        publishStatus(conversationId: conversationId)

        let record = providerSessionRecord(
            conversationId: conversationId,
            state: update.state,
            providerSessionId: update.providerSessionId,
            createdAt: update.createdAt
        )
        if let failure = await persistProviderSessionRecord(record, processToken: processToken) {
            emitProviderSessionSaveFailureIfCurrent(failure, conversationId: conversationId)
        }
    }

    func applySessionMetadataStatusSideEffects(for metadata: AgentSessionMetadataEvent, state: inout ConversationState) {
        let previousProviderSessionId = state.providerSessionId
        if let providerSessionId = metadata.providerSessionId {
            state.providerSessionId = providerSessionId
        }
        let providerSessionName = normalizedProviderSessionName(metadata.name)
        if metadata.providerSessionId != nil, state.providerSessionId != previousProviderSessionId {
            state.providerSessionName = providerSessionName
        } else if let providerSessionName {
            state.providerSessionName = providerSessionName
        }
    }

    private func providerSessionStateUpdate(
        from event: AgentEvent,
        conversationId: AgentConversationID,
        processToken: UUID
    ) -> ProviderSessionStateUpdate? {
        guard var state = states[conversationId], state.processToken == processToken else {
            return nil
        }
        let metadataEvent = event.sessionMetadataEvent
        let providerSessionId = metadataEvent?.providerSessionId ?? state.adapter.sessionID(from: event) ?? state.providerSessionId
        guard let providerSessionId else {
            return nil
        }
        let providerSessionName = normalizedProviderSessionName(metadataEvent?.name)
        let isSessionChange = state.providerSessionId != providerSessionId
        let shouldPersistSeededSession = state.providerSessionId == providerSessionId && state.providerSessionCreatedAt == nil
        let shouldPersistNameChange = providerSessionName != nil && state.providerSessionName != providerSessionName
        guard isSessionChange || shouldPersistSeededSession || shouldPersistNameChange else {
            return nil
        }

        updateProviderSessionState(
            &state,
            providerSessionId: providerSessionId,
            providerSessionName: providerSessionName,
            isSessionChange: isSessionChange
        )
        let createdAt = (isSessionChange ? nil : state.providerSessionCreatedAt) ?? now()
        state.providerSessionCreatedAt = createdAt
        return ProviderSessionStateUpdate(state: state, providerSessionId: providerSessionId, createdAt: createdAt)
    }

    private func updateProviderSessionState(
        _ state: inout ConversationState,
        providerSessionId: AgentSessionID,
        providerSessionName: String?,
        isSessionChange: Bool
    ) {
        // Session IDs can be seeded during launch; provider output still drives durable record creation and name updates.
        state.providerSessionId = providerSessionId
        if isSessionChange {
            state.providerSessionName = providerSessionName
        } else if let providerSessionName {
            state.providerSessionName = providerSessionName
        }
    }

    private func persistProviderSessionRecord(
        _ record: AgentSessionRecord,
        processToken: UUID
    ) async -> ProviderSessionSaveFailure? {
        var pendingRecord = record
        var pendingProcessToken = processToken

        while true {
            do {
                try await sessionStore.save(pendingRecord)
            } catch {
                return ProviderSessionSaveFailure(record: pendingRecord, processToken: pendingProcessToken, error: error)
            }
            guard let currentRecord = currentProviderSessionRecord(afterSaving: pendingRecord, processToken: pendingProcessToken) else {
                return nil
            }

            // Saves can complete out of order; persist the current session metadata again so continuity stays current.
            pendingRecord = currentRecord.record
            pendingProcessToken = currentRecord.processToken
        }
    }

    private func currentProviderSessionRecord(
        afterSaving savedRecord: AgentSessionRecord,
        processToken: UUID
    ) -> (record: AgentSessionRecord, processToken: UUID)? {
        guard
            let current = states[savedRecord.conversationId],
            let record = currentProviderSessionRecord(conversationId: savedRecord.conversationId, state: current),
            record.providerSessionId != savedRecord.providerSessionId ||
                record.providerSessionName != savedRecord.providerSessionName ||
                current.processToken != processToken
        else {
            return nil
        }
        return (record, current.processToken)
    }

    private func currentProviderSessionRecord(conversationId: AgentConversationID, state: ConversationState) -> AgentSessionRecord? {
        guard let currentProviderSessionId = state.providerSessionId else {
            return nil
        }
        return providerSessionRecord(
            conversationId: conversationId,
            state: state,
            providerSessionId: currentProviderSessionId,
            createdAt: state.providerSessionCreatedAt ?? now()
        )
    }

    private func providerSessionRecord(
        conversationId: AgentConversationID,
        state: ConversationState,
        providerSessionId: AgentSessionID,
        createdAt: Date
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: conversationId,
            providerId: state.providerId,
            providerSessionId: providerSessionId,
            providerSessionName: state.providerSessionName,
            workingDirectory: state.spawnConfig.workingDirectory,
            generation: state.generation,
            createdAt: createdAt,
            updatedAt: now(),
            metadata: state.providerSessionRecordMetadata
        )
    }

    private func emitProviderSessionSaveFailureIfCurrent(
        _ failure: ProviderSessionSaveFailure,
        conversationId: AgentConversationID
    ) {
        guard let current = states[conversationId], isCurrentProviderSessionSaveFailure(failure, current: current) else {
            return
        }
        emitDiagnostic(
            code: .sessionStoreSaveFailed,
            severity: .warning,
            message: "Could not persist provider session: \(failure.error.localizedDescription)",
            metadata: [
                "provider_session_id": .string(failure.record.providerSessionId.rawValue),
                "store_error": .string(failure.error.localizedDescription)
            ],
            source: .runtime,
            conversationId: conversationId
        )
    }

    private func isCurrentProviderSessionSaveFailure(
        _ failure: ProviderSessionSaveFailure,
        current: ConversationState
    ) -> Bool {
        current.processToken == failure.processToken ||
            (
                current.providerSessionId == failure.record.providerSessionId &&
                    current.providerSessionName == failure.record.providerSessionName
            )
    }
}

private extension AgentEvent {
    var sessionMetadataEvent: AgentSessionMetadataEvent? {
        guard case let .sessionMetadata(metadata) = self else {
            return nil
        }
        return metadata
    }
}

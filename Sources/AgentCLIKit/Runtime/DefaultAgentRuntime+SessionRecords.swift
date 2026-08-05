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
        } else {
            await retireSupersededProviderSessions(record, conversationId: conversationId, processToken: processToken)
        }
        emitProviderSessionSnapshotIfNeeded(from: event, update: update, conversationId: conversationId, processToken: processToken)
    }

    /// Archives provider sessions this conversation has replaced, once the replacement record is durably saved.
    ///
    /// Without this a conversation that keeps forking — Codex does so on every resumed launch that needs a fresh
    /// host-tool route — leaves a growing trail of live threads that only a later archive or delete would clean up.
    /// Best effort by design: the lineage entry stays on the record, so a failure is retried by that later cleanup.
    private func retireSupersededProviderSessions(
        _ record: AgentSessionRecord,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        guard let state = states[conversationId], state.processToken == processToken else {
            return
        }
        guard state.adapter.definition.capabilities.supportsSessionArchiving else {
            return
        }
        let pending = record.supersededProviderSessionIds.filter { !state.retiredSupersededSessionIds.contains($0) }
        guard !pending.isEmpty else {
            return
        }
        for supersededSessionId in pending {
            do {
                try await state.adapter.archiveSession(record.retargeted(to: supersededSessionId))
                states[conversationId]?.retiredSupersededSessionIds.insert(supersededSessionId)
            } catch {
                emitDiagnostic(
                    code: .sessionStoreSaveFailed,
                    severity: .warning,
                    message: "Could not archive superseded provider session: \(error.localizedDescription)",
                    metadata: [
                        "provider_session_id": .string(supersededSessionId.rawValue),
                        "provider_error": .string(error.localizedDescription)
                    ],
                    source: .runtime,
                    conversationId: conversationId
                )
            }
        }
    }

    func applySessionMetadataStatusSideEffects(for metadata: AgentSessionMetadataEvent, state: inout ConversationState) {
        let previousProviderSessionId = state.providerSessionId
        if let providerSessionId = metadata.providerSessionId {
            state.providerSessionId = providerSessionId
        }
        let providerSessionName = normalizedProviderSessionName(metadata.name)
        let providerSessionPreview = normalizedProviderSessionPreview(metadata.preview)
        let isNewConcreteSession = previousProviderSessionId != nil && state.providerSessionId != previousProviderSessionId
        if metadata.providerSessionId != nil, isNewConcreteSession {
            state.providerSessionName = providerSessionName
            state.providerSessionPreview = providerSessionPreview
        } else if let providerSessionName {
            state.providerSessionName = providerSessionName
        }
        if !isNewConcreteSession, let providerSessionPreview {
            state.providerSessionPreview = providerSessionPreview
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
        let providerSessionPreview = normalizedProviderSessionPreview(metadataEvent?.preview)
        let isSessionChange = state.providerSessionId != providerSessionId
        let shouldPersistSeededSession = state.providerSessionId == providerSessionId && state.providerSessionCreatedAt == nil
        let shouldPersistNameChange = providerSessionName != nil && state.providerSessionName != providerSessionName
        let shouldPersistPreviewChange = providerSessionPreview != nil && state.providerSessionPreview != providerSessionPreview
        guard isSessionChange || shouldPersistSeededSession || shouldPersistNameChange || shouldPersistPreviewChange else {
            return nil
        }

        // A session discovered mid-stream replaces the one the state already held; keep the old one in the lineage
        // so archive and delete can still retire it. Launch-time replacements are seeded in `providerSessionSeed`.
        if isSessionChange, let supersededSessionId = state.providerSessionId {
            state.providerSessionRecordMetadata = AgentSessionRecord.appendingSupersededProviderSessionId(
                supersededSessionId,
                to: state.providerSessionRecordMetadata
            )
        }
        updateProviderSessionState(
            &state,
            providerSessionId: providerSessionId,
            providerSessionName: providerSessionName,
            providerSessionPreview: providerSessionPreview,
            resetsMetadata: state.providerSessionId != nil && isSessionChange
        )
        let createdAt = (isSessionChange ? nil : state.providerSessionCreatedAt) ?? now()
        state.providerSessionCreatedAt = createdAt
        return ProviderSessionStateUpdate(state: state, providerSessionId: providerSessionId, createdAt: createdAt)
    }

    private func updateProviderSessionState(
        _ state: inout ConversationState,
        providerSessionId: AgentSessionID,
        providerSessionName: String?,
        providerSessionPreview: String?,
        resetsMetadata: Bool
    ) {
        // Session IDs can be seeded during launch; provider output still drives durable record creation and name updates.
        state.providerSessionId = providerSessionId
        if resetsMetadata {
            state.providerSessionName = providerSessionName
            state.providerSessionPreview = providerSessionPreview
        } else if let providerSessionName {
            state.providerSessionName = providerSessionName
        }
        if !resetsMetadata, let providerSessionPreview {
            state.providerSessionPreview = providerSessionPreview
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
                record.providerSessionPreview != savedRecord.providerSessionPreview ||
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
            providerSessionPreview: state.providerSessionPreview,
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

    private func emitProviderSessionSnapshotIfNeeded(
        from event: AgentEvent,
        update: ProviderSessionStateUpdate,
        conversationId: AgentConversationID,
        processToken: UUID
    ) {
        guard event.sessionMetadataEvent == nil,
              states[conversationId]?.processToken == processToken,
              update.state.providerSessionName != nil || update.state.providerSessionPreview != nil else {
            return
        }
        append(
            .sessionMetadata(
                providerSessionId: update.providerSessionId,
                name: update.state.providerSessionName,
                preview: update.state.providerSessionPreview,
                metadata: ["source": .string("runtime")]
            ),
            source: .runtime,
            conversationId: conversationId
        )
    }

    private func isCurrentProviderSessionSaveFailure(
        _ failure: ProviderSessionSaveFailure,
        current: ConversationState
    ) -> Bool {
        guard !current.staleProviderSessionSaveProcessTokens.contains(failure.processToken) else {
            return false
        }
        return current.processToken == failure.processToken ||
            (
                current.providerSessionId == failure.record.providerSessionId &&
                    current.providerSessionName == failure.record.providerSessionName &&
                    current.providerSessionPreview == failure.record.providerSessionPreview
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

import Foundation

private struct HarnessSessionSaveFailure {
    let record: AgentSessionRecord
    let processToken: UUID
    let error: Error
}

private struct HarnessSessionStateUpdate {
    var state: ConversationState
    let harnessSessionId: AgentSessionID
    let createdAt: Date
}

extension DefaultAgentRuntime {
    func recordHarnessSessionIfNeeded(
        from event: AgentEvent,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        guard
            let update = harnessSessionStateUpdate(from: event, conversationId: conversationId, processToken: processToken)
        else {
            return
        }

        states[conversationId] = update.state
        publishStatus(conversationId: conversationId)

        let record = harnessSessionRecord(
            conversationId: conversationId,
            state: update.state,
            harnessSessionId: update.harnessSessionId,
            createdAt: update.createdAt
        )
        if let failure = await persistHarnessSessionRecord(record, processToken: processToken) {
            emitHarnessSessionSaveFailureIfCurrent(failure, conversationId: conversationId)
        } else {
            await retireSupersededHarnessSessions(record, conversationId: conversationId, processToken: processToken)
        }
        emitHarnessSessionSnapshotIfNeeded(from: event, update: update, conversationId: conversationId, processToken: processToken)
    }

    /// Archives harness sessions this conversation has replaced, once the replacement record is durably saved.
    ///
    /// Without this a conversation that keeps forking — Codex does so on every resumed launch that needs a fresh
    /// host-tool route — leaves a growing trail of live threads that only a later archive or delete would clean up.
    /// Best effort by design: the lineage entry stays on the record, so a failure is retried by that later cleanup.
    private func retireSupersededHarnessSessions(
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
        let pending = record.supersededHarnessSessionIds.filter { !state.retiredSupersededSessionIds.contains($0) }
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
                    message: "Could not archive superseded harness session: \(error.localizedDescription)",
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
        let previousHarnessSessionId = state.harnessSessionId
        if let harnessSessionId = metadata.harnessSessionId {
            state.harnessSessionId = harnessSessionId
        }
        let harnessSessionName = normalizedHarnessSessionName(metadata.name)
        let harnessSessionPreview = normalizedHarnessSessionPreview(metadata.preview)
        let isNewConcreteSession = previousHarnessSessionId != nil && state.harnessSessionId != previousHarnessSessionId
        if metadata.harnessSessionId != nil, isNewConcreteSession {
            state.harnessSessionName = harnessSessionName
            state.harnessSessionPreview = harnessSessionPreview
        } else if let harnessSessionName {
            state.harnessSessionName = harnessSessionName
        }
        if !isNewConcreteSession, let harnessSessionPreview {
            state.harnessSessionPreview = harnessSessionPreview
        }
    }

    private func harnessSessionStateUpdate(
        from event: AgentEvent,
        conversationId: AgentConversationID,
        processToken: UUID
    ) -> HarnessSessionStateUpdate? {
        guard var state = states[conversationId], state.processToken == processToken else {
            return nil
        }
        let metadataEvent = event.sessionMetadataEvent
        let harnessSessionId = metadataEvent?.harnessSessionId ?? state.adapter.sessionID(from: event) ?? state.harnessSessionId
        guard let harnessSessionId else {
            return nil
        }
        let harnessSessionName = normalizedHarnessSessionName(metadataEvent?.name)
        let harnessSessionPreview = normalizedHarnessSessionPreview(metadataEvent?.preview)
        let isSessionChange = state.harnessSessionId != harnessSessionId
        let shouldPersistSeededSession = state.harnessSessionId == harnessSessionId && state.harnessSessionCreatedAt == nil
        let shouldPersistNameChange = harnessSessionName != nil && state.harnessSessionName != harnessSessionName
        let shouldPersistPreviewChange = harnessSessionPreview != nil && state.harnessSessionPreview != harnessSessionPreview
        guard isSessionChange || shouldPersistSeededSession || shouldPersistNameChange || shouldPersistPreviewChange else {
            return nil
        }

        // A session discovered mid-stream replaces the one the state already held; keep the old one in the lineage
        // so archive and delete can still retire it. Launch-time replacements are seeded in `harnessSessionSeed`.
        if isSessionChange, let supersededSessionId = state.harnessSessionId {
            state.harnessSessionRecordMetadata = AgentSessionRecord.appendingSupersededHarnessSessionId(
                supersededSessionId,
                to: state.harnessSessionRecordMetadata
            )
        }
        updateHarnessSessionState(
            &state,
            harnessSessionId: harnessSessionId,
            harnessSessionName: harnessSessionName,
            harnessSessionPreview: harnessSessionPreview,
            resetsMetadata: state.harnessSessionId != nil && isSessionChange
        )
        let createdAt = (isSessionChange ? nil : state.harnessSessionCreatedAt) ?? now()
        state.harnessSessionCreatedAt = createdAt
        return HarnessSessionStateUpdate(state: state, harnessSessionId: harnessSessionId, createdAt: createdAt)
    }

    private func updateHarnessSessionState(
        _ state: inout ConversationState,
        harnessSessionId: AgentSessionID,
        harnessSessionName: String?,
        harnessSessionPreview: String?,
        resetsMetadata: Bool
    ) {
        // Session IDs can be seeded during launch; harness output still drives durable record creation and name updates.
        state.harnessSessionId = harnessSessionId
        if resetsMetadata {
            state.harnessSessionName = harnessSessionName
            state.harnessSessionPreview = harnessSessionPreview
        } else if let harnessSessionName {
            state.harnessSessionName = harnessSessionName
        }
        if !resetsMetadata, let harnessSessionPreview {
            state.harnessSessionPreview = harnessSessionPreview
        }
    }

    private func persistHarnessSessionRecord(
        _ record: AgentSessionRecord,
        processToken: UUID
    ) async -> HarnessSessionSaveFailure? {
        var pendingRecord = record
        var pendingProcessToken = processToken

        while true {
            do {
                try await sessionStore.save(pendingRecord)
            } catch {
                return HarnessSessionSaveFailure(record: pendingRecord, processToken: pendingProcessToken, error: error)
            }
            guard let currentRecord = currentHarnessSessionRecord(afterSaving: pendingRecord, processToken: pendingProcessToken) else {
                return nil
            }

            // Saves can complete out of order; persist the current session metadata again so continuity stays current.
            pendingRecord = currentRecord.record
            pendingProcessToken = currentRecord.processToken
        }
    }

    private func currentHarnessSessionRecord(
        afterSaving savedRecord: AgentSessionRecord,
        processToken: UUID
    ) -> (record: AgentSessionRecord, processToken: UUID)? {
        guard
            let current = states[savedRecord.conversationId],
            let record = currentHarnessSessionRecord(conversationId: savedRecord.conversationId, state: current),
            record.harnessSessionId != savedRecord.harnessSessionId ||
                record.harnessSessionName != savedRecord.harnessSessionName ||
                record.harnessSessionPreview != savedRecord.harnessSessionPreview ||
                current.processToken != processToken
        else {
            return nil
        }
        return (record, current.processToken)
    }

    private func currentHarnessSessionRecord(conversationId: AgentConversationID, state: ConversationState) -> AgentSessionRecord? {
        guard let currentHarnessSessionId = state.harnessSessionId else {
            return nil
        }
        return harnessSessionRecord(
            conversationId: conversationId,
            state: state,
            harnessSessionId: currentHarnessSessionId,
            createdAt: state.harnessSessionCreatedAt ?? now()
        )
    }

    private func harnessSessionRecord(
        conversationId: AgentConversationID,
        state: ConversationState,
        harnessSessionId: AgentSessionID,
        createdAt: Date
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: conversationId,
            harnessId: state.harnessId,
            harnessSessionId: harnessSessionId,
            harnessSessionName: state.harnessSessionName,
            harnessSessionPreview: state.harnessSessionPreview,
            workingDirectory: state.spawnConfig.workingDirectory,
            generation: state.generation,
            createdAt: createdAt,
            updatedAt: now(),
            metadata: state.harnessSessionRecordMetadata
        )
    }

    private func emitHarnessSessionSaveFailureIfCurrent(
        _ failure: HarnessSessionSaveFailure,
        conversationId: AgentConversationID
    ) {
        guard let current = states[conversationId], isCurrentHarnessSessionSaveFailure(failure, current: current) else {
            return
        }
        emitDiagnostic(
            code: .sessionStoreSaveFailed,
            severity: .warning,
            message: "Could not persist harness session: \(failure.error.localizedDescription)",
            metadata: [
                "provider_session_id": .string(failure.record.harnessSessionId.rawValue),
                "store_error": .string(failure.error.localizedDescription)
            ],
            source: .runtime,
            conversationId: conversationId
        )
    }

    private func emitHarnessSessionSnapshotIfNeeded(
        from event: AgentEvent,
        update: HarnessSessionStateUpdate,
        conversationId: AgentConversationID,
        processToken: UUID
    ) {
        guard event.sessionMetadataEvent == nil,
              states[conversationId]?.processToken == processToken,
              update.state.harnessSessionName != nil || update.state.harnessSessionPreview != nil else {
            return
        }
        append(
            .sessionMetadata(
                harnessSessionId: update.harnessSessionId,
                name: update.state.harnessSessionName,
                preview: update.state.harnessSessionPreview,
                metadata: ["source": .string("runtime")]
            ),
            source: .runtime,
            conversationId: conversationId
        )
    }

    private func isCurrentHarnessSessionSaveFailure(
        _ failure: HarnessSessionSaveFailure,
        current: ConversationState
    ) -> Bool {
        guard !current.staleHarnessSessionSaveProcessTokens.contains(failure.processToken) else {
            return false
        }
        return current.processToken == failure.processToken ||
            (
                current.harnessSessionId == failure.record.harnessSessionId &&
                    current.harnessSessionName == failure.record.harnessSessionName &&
                    current.harnessSessionPreview == failure.record.harnessSessionPreview
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

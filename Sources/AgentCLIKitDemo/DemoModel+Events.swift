import AgentCLIKit
import Foundation

extension DemoModel {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func handle(_ envelope: AgentEventEnvelope, sessionID: AgentConversationID) {
        guard hasSession(sessionID) else {
            return
        }
        log("event conversation=\(sessionID.rawValue) index=\(envelope.index) \(Self.eventSummary(envelope.event))")
        refreshSessionRecord(from: envelope)
        switch envelope.event {
        case .message(let message):
            guard !shouldSkipDuplicateResultMessage(message, sessionID: sessionID) else {
                return
            }
            finishActiveTurnIfNeeded(sessionID: sessionID)
            append(
                DemoChatRow(
                    id: "message-\(envelope.generation)-\(envelope.index)",
                    kind: .message(role: message.role, text: message.text)
                ),
                to: sessionID
            )
        case .messageDelta(let delta):
            updateTurnState(for: sessionID) { state in
                state.isActive = true
                state.statusMessage = "Streaming"
                state.streamingText = (state.streamingText ?? "") + delta.text
            }
        case .reasoning(let reasoning):
            appendAgentEvent(.reasoning(reasoning.text), envelope: envelope, sessionID: sessionID)
        case .toolCall(let toolCall):
            appendAgentEvent(
                .toolCall(name: toolCall.name, input: Self.prettyJSONString(toolCall.input)),
                envelope: envelope,
                sessionID: sessionID
            )
        case .toolResult(let toolResult):
            appendAgentEvent(.toolResult(isError: toolResult.isError, content: toolResult.content), envelope: envelope, sessionID: sessionID)
        case .diagnostic(let diagnostic):
            guard !isTransientDiagnostic(diagnostic) else {
                updateTurnState(for: sessionID) { state in
                    if state.isActive {
                        state.statusMessage = diagnostic.message.replacingOccurrences(of: "_", with: " ").capitalized
                    }
                }
                return
            }
            appendAgentEvent(
                .diagnostic(severity: diagnostic.severity, message: diagnostic.message),
                envelope: envelope,
                sessionID: sessionID
            )
        case .rawOutput(let rawOutput):
            appendAgentEvent(.rawOutput(rawOutput.text), envelope: envelope, sessionID: sessionID)
        case .interaction(let interaction):
            guard !hasPrompt(interaction.id, sessionID: sessionID) else {
                return
            }
            appendAgentEvent(.interaction(kind: interaction.kind, prompt: interaction.prompt), envelope: envelope, sessionID: sessionID)
        case .usage(let usage):
            handleUsage(usage, envelope: envelope, sessionID: sessionID)
        case .rateLimit(let rateLimit):
            handleRateLimit(rateLimit, envelope: envelope, sessionID: sessionID)
        case .permissionMode(let permissionMode):
            appendAgentEvent(.status("Permission: \(permissionMode.mode)"), envelope: envelope, sessionID: sessionID)
        case .task(let task):
            appendAgentEvent(.status(Self.taskSummary(task)), envelope: envelope, sessionID: sessionID)
        case .sessionContinuity(let continuity):
            appendAgentEvent(
                .status(continuity.message ?? continuity.continuity.rawValue.capitalized),
                envelope: envelope,
                sessionID: sessionID
            )
        case .lifecycle(let lifecycle):
            handleLifecycle(lifecycle, envelope: envelope, sessionID: sessionID)
        }
    }

    private func handleUsage(_ usage: AgentUsageEvent, envelope: AgentEventEnvelope, sessionID: AgentConversationID) {
        let row = DemoChatRow(
            id: "usage-\(envelope.generation)-\(envelope.index)",
            kind: .usage(Self.usageSummary(usage))
        )
        if Self.isTerminalUsage(usage) {
            removeUsageRowsForCurrentTurn(sessionID: sessionID)
            appendAgentEvent(row.kind, envelope: envelope, sessionID: sessionID)
        } else {
            upsertLiveUsageRow(row, sessionID: sessionID)
        }
    }

    private func appendAgentEvent(_ kind: DemoChatRowKind, envelope: AgentEventEnvelope, sessionID: AgentConversationID) {
        if case .diagnostic(severity: .info, message: "system") = kind {
            return
        }
        finishActiveTurnIfNeeded(sessionID: sessionID)
        append(
            DemoChatRow(
                id: "event-\(envelope.generation)-\(envelope.index)",
                kind: kind
            ),
            to: sessionID
        )
    }

    private func isTransientDiagnostic(_ diagnostic: AgentDiagnosticEvent) -> Bool {
        guard diagnostic.severity == .info else {
            return false
        }
        switch diagnostic.message {
        case "system", "init", "status", "hook", "hook_started", "hook_finished", "hook_completed":
            return true
        default:
            return diagnostic.message.hasPrefix("hook_")
        }
    }

    private func handleLifecycle(_ lifecycle: AgentLifecycleEvent, envelope: AgentEventEnvelope, sessionID: AgentConversationID) {
        switch lifecycle.state {
        case .starting, .running:
            updateTurnState(for: sessionID) { state in
                state.statusMessage = lifecycle.state.rawValue.capitalized
            }
        case .exited:
            spawnedSessionIDs.remove(sessionID)
            updateTurnState(for: sessionID) { state in
                state.isActive = false
                state.streamingText = nil
                state.statusMessage = "Exited"
            }
        case .cancelled, .failed:
            spawnedSessionIDs.remove(sessionID)
            updateTurnState(for: sessionID) { state in
                state.isActive = false
                state.streamingText = nil
                state.statusMessage = lifecycle.state.rawValue.capitalized
            }
            append(
                DemoChatRow(
                    id: "lifecycle-\(envelope.generation)-\(envelope.index)",
                    kind: .lifecycle(lifecycle.state, lifecycle.message)
                ),
                to: sessionID
            )
        }
    }

    private func handleRateLimit(_ rateLimit: AgentRateLimitEvent, envelope: AgentEventEnvelope, sessionID: AgentConversationID) {
        let summary = Self.rateLimitSummary(rateLimit)
        switch rateLimit.status.rawValue {
        case AgentRateLimitStatus.allowed.rawValue:
            updateTurnState(for: sessionID) { state in
                if state.isActive {
                    state.statusMessage = "Rate limit: \(summary)"
                }
            }
        default:
            appendAgentEvent(.rateLimit(summary), envelope: envelope, sessionID: sessionID)
        }
    }

    private func upsertLiveUsageRow(_ row: DemoChatRow, sessionID: AgentConversationID) {
        var rows = rowsBySession[sessionID] ?? []
        let turnStartIndex = Self.currentTurnStartIndex(in: rows)
        // Claude can emit repeated usage snapshots before the terminal result; keep one live row per turn.
        if let usageIndex = rows.indices.reversed().first(where: { $0 >= turnStartIndex && Self.isUsageRow(rows[$0]) }) {
            rows[usageIndex] = row
        } else {
            rows.append(row)
        }
        rowsBySession[sessionID] = rows
    }

    private func removeUsageRowsForCurrentTurn(sessionID: AgentConversationID) {
        guard let rows = rowsBySession[sessionID], !rows.isEmpty else {
            return
        }
        let turnStartIndex = Self.currentTurnStartIndex(in: rows)
        let preservedRows = rows.prefix(turnStartIndex)
        let currentTurnRows = rows.dropFirst(turnStartIndex).filter { !Self.isUsageRow($0) }
        rowsBySession[sessionID] = Array(preservedRows) + currentTurnRows
    }

    private func shouldSkipDuplicateResultMessage(_ message: AgentMessageEvent, sessionID: AgentConversationID) -> Bool {
        guard message.role == .assistant,
              Self.metadataString(message.metadata["claude_event_type"]) == "result" else {
            return false
        }
        // Claude stream-json can emit both an assistant message and a final result with identical text for one turn.
        for row in (rowsBySession[sessionID] ?? []).reversed() {
            switch row.kind {
            case .message(role: .user, text: _):
                return false
            case .message(role: .assistant, text: let existingText):
                if existingText == message.text {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    private func finishActiveTurnIfNeeded(sessionID: AgentConversationID) {
        updateTurnState(for: sessionID) { state in
            state.isActive = false
            state.streamingText = nil
            state.statusMessage = nil
        }
    }

    private func refreshSessionRecord(from envelope: AgentEventEnvelope) {
        guard let providerSessionId = envelope.providerSessionId,
              let index = sessions.firstIndex(where: { $0.id == envelope.conversationId }) else {
            return
        }
        let current = sessions[index]
        sessions[index] = DemoSession(
            id: current.id,
            record: AgentSessionRecord(
                conversationId: envelope.conversationId,
                providerId: envelope.providerId,
                providerSessionId: providerSessionId,
                generation: envelope.generation,
                createdAt: current.record?.createdAt ?? current.createdAt,
                updatedAt: envelope.createdAt,
                metadata: current.record?.metadata ?? ["source": .string("demo")]
            ),
            createdAt: current.createdAt
        )
    }
}

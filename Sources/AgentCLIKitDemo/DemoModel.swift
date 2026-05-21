import AgentCLIKit
import Foundation

@MainActor
final class DemoModel: ObservableObject {
    @Published var sessions: [DemoSession] = []
    @Published var selectedSessionID: AgentConversationID?
    @Published var rowsBySession: [AgentConversationID: [DemoChatRow]] = [:]
    @Published var turnStates: [AgentConversationID: DemoTurnState] = [:]

    private let sessionStore: JSONFileAgentSessionStore
    private let runtime: DefaultAgentRuntime
    let hookDecisionProvider: DemoHookDecisionProvider
    private let workingDirectory: URL
    var spawnedSessionIDs: Set<AgentConversationID> = []
    private var subscribedSessionIDs: Set<AgentConversationID> = []
    private var subscriptionTasks: [AgentConversationID: Task<Void, Never>] = [:]

    init() {
        let store = JSONFileAgentSessionStore(fileURL: Self.sessionStoreURL())
        let hookDecisionProvider = DemoHookDecisionProvider()
        self.sessionStore = store
        self.hookDecisionProvider = hookDecisionProvider
        self.runtime = DefaultAgentRuntime(
            adapters: [
                ClaudeProviderAdapter(
                    hookDecisionProvider: hookDecisionProvider,
                    hookDecisionTimeout: 595
                )
            ],
            sessionStore: store
        )
        self.workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        hookDecisionProvider.bind(model: self)
        Task { await loadSessions() }
    }

    var currentSession: DemoSession? {
        guard let selectedSessionID else {
            return nil
        }
        return sessions.first { $0.id == selectedSessionID }
    }

    var currentRows: [DemoChatRow] {
        guard let selectedSessionID else {
            return []
        }
        return rowsBySession[selectedSessionID] ?? []
    }

    var currentTurnState: DemoTurnState {
        guard let selectedSessionID else {
            return DemoTurnState()
        }
        return turnStates[selectedSessionID] ?? DemoTurnState()
    }

    func loadSessions() async {
        do {
            let records = try await sessionStore.allRecords()
            sessions = records.map { record in
                DemoSession(id: record.conversationId, record: record, createdAt: record.createdAt)
            }
            if sessions.isEmpty {
                addSession()
            } else {
                selectedSessionID = sessions.first?.id
            }
        } catch {
            addSession()
            appendStatus("Could not load sessions: \(error.localizedDescription)", to: selectedSessionID)
        }
    }

    func select(_ sessionID: AgentConversationID) {
        selectedSessionID = sessionID
    }

    func addSession() {
        let id = AgentConversationID(rawValue: "demo-\(UUID().uuidString)")
        let session = DemoSession(id: id, record: nil, createdAt: Date())
        sessions.append(session)
        rowsBySession[id] = []
        turnStates[id] = DemoTurnState()
        selectedSessionID = id
    }

    func sendCurrentMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let sessionID = selectedSessionID else {
            addSession()
            guard let createdSessionID = selectedSessionID else {
                return
            }
            send(text, sessionID: createdSessionID)
            return
        }
        send(text, sessionID: sessionID)
    }

    func cancelPendingWork() {
        for task in subscriptionTasks.values {
            task.cancel()
        }
        subscriptionTasks.removeAll()
        Task {
            await runtime.shutdown()
        }
    }

    private func send(_ text: String, sessionID: AgentConversationID) {
        guard !hasPendingPrompt(sessionID) else {
            appendStatus("Answer the pending prompt before sending another message.", to: sessionID)
            return
        }
        log("send conversation=\(sessionID.rawValue) length=\(text.count)")
        append(
            DemoChatRow(
                id: "user-\(UUID().uuidString)",
                kind: .message(role: .user, text: text)
            ),
            to: sessionID
        )
        updateTurnState(for: sessionID) { state in
            state.isActive = true
            state.streamingText = nil
            state.statusMessage = "Working"
        }
        Task {
            do {
                guard hasSession(sessionID) else {
                    return
                }
                try await ensureRuntime(for: sessionID)
                guard hasSession(sessionID) else {
                    // Deletion can happen while spawn awaits the runtime actor; tear down any process before it receives input.
                    await runtime.destroy(conversationId: sessionID)
                    return
                }
                try await runtime.send(.userMessage(AgentMessageInput(text: text)), conversationId: sessionID)
            } catch {
                guard hasSession(sessionID) else {
                    return
                }
                log("send_failed conversation=\(sessionID.rawValue) error=\(error.localizedDescription)")
                updateTurnState(for: sessionID) { state in
                    state.isActive = false
                    state.streamingText = nil
                    state.statusMessage = "Send failed"
                }
                appendStatus("Send failed: \(error.localizedDescription)", to: sessionID)
            }
        }
    }

    private func ensureRuntime(for sessionID: AgentConversationID) async throws {
        if !subscribedSessionIDs.contains(sessionID) {
            subscribe(to: sessionID)
        }
        guard !spawnedSessionIDs.contains(sessionID) else {
            return
        }
        try await runtime.spawn(
            conversationId: sessionID,
            config: AgentSpawnConfig(
                providerId: ClaudeProviderAdapter.providerId,
                workingDirectory: workingDirectory
            )
        )
        spawnedSessionIDs.insert(sessionID)
    }

    private func subscribe(to sessionID: AgentConversationID) {
        subscribedSessionIDs.insert(sessionID)
        let runtime = runtime
        subscriptionTasks[sessionID] = Task { [weak self] in
            let subscription = await runtime.subscribe(conversationId: sessionID, afterIndex: nil)
            for await envelope in subscription.events {
                await MainActor.run {
                    self?.handle(envelope, sessionID: sessionID)
                }
                await runtime.markPersisted(
                    conversationId: sessionID,
                    generation: envelope.generation,
                    upTo: envelope.index
                )
            }
        }
    }

    func appendStatus(_ message: String, to sessionID: AgentConversationID?) {
        guard let sessionID else {
            return
        }
        append(
            DemoChatRow(
                id: "status-\(UUID().uuidString)",
                kind: .diagnostic(severity: .error, message: message)
            ),
            to: sessionID
        )
    }

    func append(_ row: DemoChatRow, to sessionID: AgentConversationID) {
        rowsBySession[sessionID, default: []].append(row)
    }

    func updateTurnState(for sessionID: AgentConversationID, update: (inout DemoTurnState) -> Void) {
        var state = turnStates[sessionID] ?? DemoTurnState()
        update(&state)
        turnStates[sessionID] = state
    }

    func log(_ message: String) {
        let line = "[AgentCLIKitDemo] \(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

extension DemoModel {
    func deleteSelectedSession() {
        guard let selectedSessionID else {
            return
        }
        deleteSession(selectedSessionID)
    }

    func deleteSession(_ sessionID: AgentConversationID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        let session = sessions[index]
        let providerId = session.record?.providerId ?? ClaudeProviderAdapter.providerId
        subscriptionTasks.removeValue(forKey: sessionID)?.cancel()
        subscribedSessionIDs.remove(sessionID)
        spawnedSessionIDs.remove(sessionID)
        rowsBySession[sessionID] = nil
        turnStates[sessionID] = nil
        sessions.remove(at: index)
        selectReplacementSession(afterDeletingAt: index, deletedSessionID: sessionID)
        Task {
            do {
                await runtime.destroy(conversationId: sessionID)
                try await sessionStore.remove(conversationId: sessionID, providerId: providerId)
            } catch {
                appendStatus("Could not delete session: \(error.localizedDescription)", to: selectedSessionID)
            }
        }
    }

    private func selectReplacementSession(afterDeletingAt deletedIndex: Int, deletedSessionID: AgentConversationID) {
        if sessions.isEmpty {
            addSession()
            return
        }
        guard selectedSessionID == deletedSessionID else {
            return
        }
        let replacementIndex = min(deletedIndex, sessions.index(before: sessions.endIndex))
        selectedSessionID = sessions[replacementIndex].id
    }

    func hasSession(_ sessionID: AgentConversationID) -> Bool {
        sessions.contains { $0.id == sessionID }
    }
}

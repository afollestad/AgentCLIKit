import AgentCLIKit
import Foundation

@MainActor
final class DemoModel: ObservableObject {
    @Published var sessions: [DemoSession] = []
    @Published var selectedSessionID: AgentConversationID?
    @Published var rowsBySession: [AgentConversationID: [DemoChatRow]] = [:]
    @Published var turnStates: [AgentConversationID: DemoTurnState] = [:]
    @Published var providerStatuses: [AgentProviderID: AgentProviderStatus] = [:]
    @Published var providerOrdering: [AgentProviderID] = AgentProviderID.allCases
    @Published var providerSelectionBySession: [AgentConversationID: AgentProviderID] = [:]
    @Published var modelSelectionBySession: [AgentConversationID: String] = [:]
    @Published var effortSelectionBySession: [AgentConversationID: String] = [:]

    private let sessionStore: JSONFileAgentSessionStore
    private let runtime: DefaultAgentRuntime
    private let providerDiscovery: DefaultAgentProviderDiscoveryService
    private let projectTrustService: DefaultAgentProjectTrustService
    let hookDecisionProvider: DemoHookDecisionProvider
    private let workingDirectory: URL
    var spawnedSessionIDs: Set<AgentConversationID> = []
    private var subscribedSessionIDs: Set<AgentConversationID> = []
    private var subscriptionTasks: [AgentConversationID: Task<Void, Never>] = [:]
    private var statusTasks: [AgentConversationID: Task<Void, Never>] = [:]

    init() {
        let store = JSONFileAgentSessionStore(fileURL: Self.sessionStoreURL())
        let hookDecisionProvider = DemoHookDecisionProvider()
        let providerSetups: [any AgentProviderSetup] = [
            ClaudeProviderSetup(configStore: ClaudeConfigStore()),
            CodexProviderSetup()
        ]
        let projectTrustService = DefaultAgentProjectTrustService(setups: providerSetups)
        self.sessionStore = store
        self.hookDecisionProvider = hookDecisionProvider
        self.projectTrustService = projectTrustService
        self.providerDiscovery = DefaultAgentProviderDiscoveryService(
            projectTrustService: projectTrustService,
            providerSetups: providerSetups,
            modelOptionSource: DefaultAgentModelOptionSource(codexSource: CodexAppServerModelOptionSource())
        )
        let adapterSet = AgentProviderAdapterSet.default(
            claude: ClaudeProviderAdapter.Configuration(
                hookDecisionProvider: hookDecisionProvider,
                hookDecisionTimeout: 595
            )
        )
        self.runtime = DefaultAgentRuntime(
            adapterSet: adapterSet,
            sessionStore: store
        )
        self.workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        hookDecisionProvider.bind(model: self)
        Task {
            await loadSessions()
            await refreshProviderStatuses()
        }
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
            for record in records {
                providerSelectionBySession[record.conversationId] = record.providerId
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
        let providerId = defaultProviderId()
        let modelOptionID = defaultModelOptionID(providerId: providerId)
        providerSelectionBySession[id] = providerId
        modelSelectionBySession[id] = modelOptionID
        effortSelectionBySession[id] = defaultEffortOptionValue(providerId: providerId, modelOptionID: modelOptionID)
        selectedSessionID = id
    }

    func refreshProviderStatuses() async {
        let statuses = await providerDiscovery.providerStatuses(projectURL: workingDirectory)
        providerStatuses = statuses
        providerOrdering = await providerDiscovery.stableProviderOrdering()
        let fallbackProviderId = defaultProviderId()
        for session in sessions where session.record == nil && !spawnedSessionIDs.contains(session.id) {
            let hasRows = rowsBySession[session.id]?.isEmpty == false
            guard !hasRows else {
                continue
            }
            let selectedProviderId = providerSelectionBySession[session.id]
            if selectedProviderId == nil || providerStatuses[selectedProviderId ?? fallbackProviderId]?.isReadyInProject != true {
                providerSelectionBySession[session.id] = fallbackProviderId
                let modelOptionID = defaultModelOptionID(providerId: fallbackProviderId)
                modelSelectionBySession[session.id] = modelOptionID
                effortSelectionBySession[session.id] = defaultEffortOptionValue(providerId: fallbackProviderId, modelOptionID: modelOptionID)
            } else {
                normalizeModelAndEffortSelection(for: session.id, providerId: selectedProviderId ?? fallbackProviderId)
            }
        }
    }

    func providerId(for sessionID: AgentConversationID) -> AgentProviderID {
        if let record = sessions.first(where: { $0.id == sessionID })?.record {
            return record.providerId
        }
        return providerSelectionBySession[sessionID] ?? defaultProviderId()
    }

    func selectedModelOptionID(for sessionID: AgentConversationID) -> String {
        let providerId = providerId(for: sessionID)
        let options = modelOptions(for: providerId)
        if let selected = modelSelectionBySession[sessionID],
           options.contains(where: { $0.id == selected }) {
            return selected
        }
        return defaultModelOptionID(providerId: providerId)
    }

    func effortOptions(for sessionID: AgentConversationID) -> [AgentProviderOption] {
        let providerId = providerId(for: sessionID)
        return selectedModelOption(for: sessionID, providerId: providerId)?.supportedEffortOptions ?? []
    }

    func selectedEffortOptionValue(for sessionID: AgentConversationID) -> String {
        let providerId = providerId(for: sessionID)
        let current = effortSelectionBySession[sessionID]
        return normalizedEffortOptionValue(
            providerId: providerId,
            modelOptionID: selectedModelOptionID(for: sessionID),
            current: current
        ) ?? ""
    }

    func setProvider(_ providerId: AgentProviderID, for sessionID: AgentConversationID) {
        guard canEditProviderSelection(for: sessionID) else {
            return
        }
        let modelOptionID = defaultModelOptionID(providerId: providerId)
        providerSelectionBySession[sessionID] = providerId
        modelSelectionBySession[sessionID] = modelOptionID
        effortSelectionBySession[sessionID] = defaultEffortOptionValue(providerId: providerId, modelOptionID: modelOptionID)
    }

    func setModelOptionID(_ modelOptionID: String, for sessionID: AgentConversationID) {
        guard canEditProviderSelection(for: sessionID) else {
            return
        }
        let providerId = providerId(for: sessionID)
        modelSelectionBySession[sessionID] = modelOptionID
        effortSelectionBySession[sessionID] = normalizedEffortOptionValue(
            providerId: providerId,
            modelOptionID: modelOptionID,
            current: effortSelectionBySession[sessionID]
        )
    }

    func setEffortOptionValue(_ effortOptionValue: String, for sessionID: AgentConversationID) {
        guard canEditProviderSelection(for: sessionID),
              effortOptions(for: sessionID).contains(where: { $0.value == effortOptionValue }) else {
            return
        }
        effortSelectionBySession[sessionID] = effortOptionValue
    }

    func trustProject(for sessionID: AgentConversationID) {
        guard hasSession(sessionID) else {
            return
        }
        let providerId = providerId(for: sessionID)
        let providerName = providerStatuses[providerId]?.definition?.displayName ?? providerId.rawValue.capitalized
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await projectTrustService.trustProject(providerId: providerId, projectURL: workingDirectory)
                await refreshProviderStatuses()
                appendDiagnostic("Trusted \(workingDirectory.path) for \(providerName).", severity: .info, to: sessionID)
            } catch {
                appendStatus("Could not trust project for \(providerName): \(error.localizedDescription)", to: sessionID)
            }
        }
    }

    func canEditProviderSelection(for sessionID: AgentConversationID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return false
        }
        return session.record == nil && !spawnedSessionIDs.contains(sessionID) && (turnStates[sessionID]?.isActive ?? false) == false
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
        for task in statusTasks.values {
            task.cancel()
        }
        subscriptionTasks.removeAll()
        statusTasks.removeAll()
        Task {
            await runtime.shutdown()
        }
    }

    func cancelCurrentSession() {
        guard let selectedSessionID else {
            return
        }
        Task {
            await runtime.cancel(conversationId: selectedSessionID)
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
                await refreshProviderStatuses()
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
        let providerId = providerId(for: sessionID)
        try validateProviderReadiness(providerId, sessionID: sessionID)
        try await runtime.spawn(
            conversationId: sessionID,
            config: AgentSpawnConfig(
                providerId: providerId,
                workingDirectory: workingDirectory,
                model: selectedModelOption(for: sessionID, providerId: providerId)?.model,
                effort: selectedEffortOptionValueForSpawn(for: sessionID)
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
        subscribeToStatus(sessionID)
    }

    private func subscribeToStatus(_ sessionID: AgentConversationID) {
        guard statusTasks[sessionID] == nil else {
            return
        }
        let runtime = runtime
        statusTasks[sessionID] = Task { [weak self] in
            let statuses = await runtime.statusUpdates(conversationId: sessionID)
            for await status in statuses {
                await MainActor.run {
                    self?.handle(status, sessionID: sessionID)
                }
            }
        }
    }

    private func handle(_ status: AgentRuntimeStatus, sessionID: AgentConversationID) {
        guard hasSession(sessionID) else {
            return
        }
        updateTurnState(for: sessionID) { state in
            state.statusMessage = Self.statusSummary(status, current: state)
            state.canCancel = status.canCancel
        }
    }

    func appendStatus(_ message: String, to sessionID: AgentConversationID?) {
        appendDiagnostic(message, severity: .error, to: sessionID)
    }

    func appendDiagnostic(_ message: String, severity: AgentDiagnosticSeverity, to sessionID: AgentConversationID?) {
        guard let sessionID else {
            return
        }
        append(
            DemoChatRow(
                id: "status-\(UUID().uuidString)",
                kind: .diagnostic(severity: severity, message: message)
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
        let providerId = session.record?.providerId ?? providerSelectionBySession[sessionID] ?? ClaudeProviderAdapter.providerId
        subscriptionTasks.removeValue(forKey: sessionID)?.cancel()
        statusTasks.removeValue(forKey: sessionID)?.cancel()
        subscribedSessionIDs.remove(sessionID)
        spawnedSessionIDs.remove(sessionID)
        providerSelectionBySession[sessionID] = nil
        modelSelectionBySession[sessionID] = nil
        effortSelectionBySession[sessionID] = nil
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

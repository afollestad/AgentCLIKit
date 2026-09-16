import AgentCLIKit
import Foundation

@MainActor
final class DemoModel: ObservableObject {
    @Published var sessions: [DemoSession] = []
    @Published var selectedSessionID: AgentConversationID?
    @Published var rowsBySession: [AgentConversationID: [DemoChatRow]] = [:]
    @Published var turnStates: [AgentConversationID: DemoTurnState] = [:]
    @Published var harnessStatuses: [AgentHarnessID: AgentHarnessStatus] = [:]
    @Published var harnessOrdering: [AgentHarnessID] = AgentHarnessID.allCases
    @Published var harnessSelectionBySession: [AgentConversationID: AgentHarnessID] = [:]
    @Published var modelSelectionBySession: [AgentConversationID: String] = [:]
    @Published var effortSelectionBySession: [AgentConversationID: String] = [:]
    @Published var speedSelectionBySession: [AgentConversationID: AgentSpeedMode] = [:]

    private let sessionStore: JSONFileAgentSessionStore
    private let runtime: DefaultAgentRuntime
    private let harnessDiscovery: DefaultAgentHarnessDiscoveryService
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
        let openCodeProbe = OpenCodeDiscoveryProbe()
        let harnessSetups: [any AgentHarnessSetup] = [
            ClaudeHarnessSetup(configStore: ClaudeConfigStore()),
            CodexHarnessSetup(),
            OpenCodeHarnessSetup(probe: openCodeProbe)
        ]
        let codexFeatureSupportChecker = DefaultCodexFeatureSupportChecker()
        let codexConfiguration = CodexHarnessAdapter.Configuration(featureSupportChecker: codexFeatureSupportChecker)
        let projectTrustService = DefaultAgentProjectTrustService(setups: harnessSetups)
        self.sessionStore = store
        self.hookDecisionProvider = hookDecisionProvider
        self.projectTrustService = projectTrustService
        self.harnessDiscovery = DefaultAgentHarnessDiscoveryService(
            projectTrustService: projectTrustService,
            harnessSetups: harnessSetups,
            modelOptionSource: DefaultAgentModelOptionSource(
                codexSource: CodexAppServerModelOptionSource(configuration: codexConfiguration),
                openCodeSource: OpenCodeModelOptionSource(probe: openCodeProbe)
            ),
            capabilitySource: DefaultAgentHarnessCapabilitySource(
                codexSource: CodexHarnessCapabilitySource(configuration: codexConfiguration)
            )
        )
        let adapterSet = AgentHarnessAdapterSet.default(
            claude: ClaudeHarnessAdapter.Configuration(
                hookDecisionProvider: hookDecisionProvider,
                hookDecisionTimeout: 595
            ),
            codex: codexConfiguration
        )
        self.runtime = DefaultAgentRuntime(
            adapterSet: adapterSet,
            sessionStore: store
        )
        self.workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        hookDecisionProvider.bind(model: self)
        Task {
            await loadSessions()
            await refreshHarnessStatuses()
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
                harnessSelectionBySession[record.conversationId] = record.harnessId
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
        let harnessId = defaultHarnessId()
        let modelOptionID = defaultModelOptionID(harnessId: harnessId)
        harnessSelectionBySession[id] = harnessId
        modelSelectionBySession[id] = modelOptionID
        effortSelectionBySession[id] = defaultEffortOptionValue(harnessId: harnessId, modelOptionID: modelOptionID)
        speedSelectionBySession[id] = .standard
        selectedSessionID = id
    }

    func refreshHarnessStatuses() async {
        let statuses = await harnessDiscovery.harnessStatuses(projectURL: workingDirectory)
        harnessStatuses = statuses
        harnessOrdering = await harnessDiscovery.stableHarnessOrdering()
        let fallbackHarnessId = defaultHarnessId()
        for session in sessions where session.record == nil && !spawnedSessionIDs.contains(session.id) {
            let hasRows = rowsBySession[session.id]?.isEmpty == false
            guard !hasRows else {
                continue
            }
            let selectedHarnessId = harnessSelectionBySession[session.id]
            if selectedHarnessId == nil || harnessStatuses[selectedHarnessId ?? fallbackHarnessId]?.isReadyInProject != true {
                harnessSelectionBySession[session.id] = fallbackHarnessId
                let modelOptionID = defaultModelOptionID(harnessId: fallbackHarnessId)
                modelSelectionBySession[session.id] = modelOptionID
                effortSelectionBySession[session.id] = defaultEffortOptionValue(harnessId: fallbackHarnessId, modelOptionID: modelOptionID)
                speedSelectionBySession[session.id] = .standard
            } else {
                normalizeModelAndEffortSelection(for: session.id, harnessId: selectedHarnessId ?? fallbackHarnessId)
            }
        }
    }

    func harnessId(for sessionID: AgentConversationID) -> AgentHarnessID {
        if let record = sessions.first(where: { $0.id == sessionID })?.record {
            return record.harnessId
        }
        return harnessSelectionBySession[sessionID] ?? defaultHarnessId()
    }

    func selectedModelOptionID(for sessionID: AgentConversationID) -> String {
        let harnessId = harnessId(for: sessionID)
        let options = modelOptions(for: harnessId)
        if let selected = modelSelectionBySession[sessionID],
           options.contains(where: { $0.id == selected }) {
            return selected
        }
        return defaultModelOptionID(harnessId: harnessId)
    }

    func effortOptions(for sessionID: AgentConversationID) -> [AgentHarnessOption] {
        let harnessId = harnessId(for: sessionID)
        return selectedModelOption(for: sessionID, harnessId: harnessId)?.supportedEffortOptions ?? []
    }

    func selectedEffortOptionValue(for sessionID: AgentConversationID) -> String {
        let harnessId = harnessId(for: sessionID)
        let current = effortSelectionBySession[sessionID]
        return normalizedEffortOptionValue(
            harnessId: harnessId,
            modelOptionID: selectedModelOptionID(for: sessionID),
            current: current
        ) ?? ""
    }

    func setHarness(_ harnessId: AgentHarnessID, for sessionID: AgentConversationID) {
        guard canEditHarnessSelection(for: sessionID) else {
            return
        }
        let modelOptionID = defaultModelOptionID(harnessId: harnessId)
        harnessSelectionBySession[sessionID] = harnessId
        modelSelectionBySession[sessionID] = modelOptionID
        effortSelectionBySession[sessionID] = defaultEffortOptionValue(harnessId: harnessId, modelOptionID: modelOptionID)
        speedSelectionBySession[sessionID] = .standard
    }

    func setModelOptionID(_ modelOptionID: String, for sessionID: AgentConversationID) {
        guard canEditHarnessSelection(for: sessionID) else {
            return
        }
        let harnessId = harnessId(for: sessionID)
        modelSelectionBySession[sessionID] = modelOptionID
        effortSelectionBySession[sessionID] = normalizedEffortOptionValue(
            harnessId: harnessId,
            modelOptionID: modelOptionID,
            current: effortSelectionBySession[sessionID]
        )
    }

    func setEffortOptionValue(_ effortOptionValue: String, for sessionID: AgentConversationID) {
        guard canEditHarnessSelection(for: sessionID),
              effortOptions(for: sessionID).contains(where: { $0.value == effortOptionValue }) else {
            return
        }
        effortSelectionBySession[sessionID] = effortOptionValue
    }

    func trustProject(for sessionID: AgentConversationID) {
        guard hasSession(sessionID) else {
            return
        }
        let harnessId = harnessId(for: sessionID)
        let harnessName = harnessStatuses[harnessId]?.definition?.displayName ?? harnessId.rawValue.capitalized
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await projectTrustService.trustProject(harnessId: harnessId, projectURL: workingDirectory)
                await refreshHarnessStatuses()
                appendDiagnostic("Trusted \(workingDirectory.path) for \(harnessName).", severity: .info, to: sessionID)
            } catch {
                appendStatus("Could not trust project for \(harnessName): \(error.localizedDescription)", to: sessionID)
            }
        }
    }

    func canEditHarnessSelection(for sessionID: AgentConversationID) -> Bool {
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
                await refreshHarnessStatuses()
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
        let harnessId = harnessId(for: sessionID)
        try validateHarnessReadiness(harnessId, sessionID: sessionID)
        try await runtime.spawn(
            conversationId: sessionID,
            config: AgentSpawnConfig(
                harnessId: harnessId,
                workingDirectory: workingDirectory,
                model: selectedModelOption(for: sessionID, harnessId: harnessId)?.model,
                effort: selectedEffortOptionValueForSpawn(for: sessionID),
                speedMode: selectedSpeedMode(for: sessionID)
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
        let harnessId = session.record?.harnessId ?? harnessSelectionBySession[sessionID] ?? ClaudeHarnessAdapter.harnessId
        subscriptionTasks.removeValue(forKey: sessionID)?.cancel()
        statusTasks.removeValue(forKey: sessionID)?.cancel()
        subscribedSessionIDs.remove(sessionID)
        spawnedSessionIDs.remove(sessionID)
        harnessSelectionBySession[sessionID] = nil
        modelSelectionBySession[sessionID] = nil
        effortSelectionBySession[sessionID] = nil
        speedSelectionBySession[sessionID] = nil
        rowsBySession[sessionID] = nil
        turnStates[sessionID] = nil
        sessions.remove(at: index)
        selectReplacementSession(afterDeletingAt: index, deletedSessionID: sessionID)
        Task {
            do {
                await runtime.destroy(conversationId: sessionID)
                try await sessionStore.remove(conversationId: sessionID, harnessId: harnessId)
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

import AgentCLIKit
import SwiftUI

struct DemoShellView: View {
    @ObservedObject var model: DemoModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var draft = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 176, ideal: 220, max: 280)
        } detail: {
            detailView
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Sessions") {
                    ForEach(model.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .lineLimit(1)
                            Text(session.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(session.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                delete(session.id)
                            } label: {
                                Label("Delete Session", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                deleteSelectedSession()
            }

            Divider()
            Button {
                model.addSession()
                draft = ""
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var selection: Binding<AgentConversationID?> {
        Binding(
            get: { model.selectedSessionID },
            set: { sessionID in
                guard let sessionID else {
                    return
                }
                model.select(sessionID)
                draft = ""
            }
        )
    }

    private func delete(_ sessionID: AgentConversationID) {
        model.deleteSession(sessionID)
        draft = ""
    }

    private func deleteSelectedSession() {
        model.deleteSelectedSession()
        draft = ""
    }

    @ViewBuilder
    private var detailView: some View {
        if let session = model.currentSession {
            ChatDetailView(
                session: session,
                rows: model.currentRows,
                turnState: model.currentTurnState,
                providerId: model.providerId(for: session.id),
                selectedModelOptionID: model.selectedModelOptionID(for: session.id),
                providerStatuses: model.providerStatuses,
                providerOrdering: model.providerOrdering,
                canEditProviderSelection: model.canEditProviderSelection(for: session.id),
                draft: $draft,
                onSend: { model.sendCurrentMessage($0) },
                onCancel: { model.cancelCurrentSession() },
                onSubmitPrompt: { model.submitPromptAnswers(promptID: $0, answers: $1) },
                onProviderChange: { model.setProvider($0, for: session.id) },
                onModelChange: { model.setModelOptionID($0, for: session.id) },
                onTrustProject: { model.trustProject(for: session.id) },
                onRefreshProviders: {
                    Task {
                        await model.refreshProviderStatuses()
                    }
                }
            )
            .id(session.id)
        } else {
            ContentUnavailableView("No Session", systemImage: "message")
        }
    }
}

private struct ChatDetailView: View {
    let session: DemoSession
    let rows: [DemoChatRow]
    let turnState: DemoTurnState
    let providerId: AgentProviderID
    let selectedModelOptionID: String
    let providerStatuses: [AgentProviderID: AgentProviderStatus]
    let providerOrdering: [AgentProviderID]
    let canEditProviderSelection: Bool
    @Binding var draft: String
    var onSend: (String) -> Void
    var onCancel: () -> Void
    var onSubmitPrompt: (AgentInteractionID, [DemoPromptAnswer]) -> Void
    var onProviderChange: (AgentProviderID) -> Void
    var onModelChange: (String) -> Void
    var onTrustProject: () -> Void
    var onRefreshProviders: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                            ChatRowView(row: row, onSubmitPrompt: onSubmitPrompt)
                                .padding(.top, topSpacing(for: index, row: row))
                                .id(row.id)
                        }
                        if shouldShowWorkingIndicator {
                            WorkingIndicatorView()
                                .padding(.top, workingIndicatorTopSpacing)
                                .id("working-indicator")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: scrollAnchor) { _, anchor in
                    guard let anchor else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(anchor, anchor: .bottom)
                    }
                }
            }
            Divider()
            ProviderComposerControls(
                providerId: providerId,
                selectedModelOptionID: selectedModelOptionID,
                providerStatuses: providerStatuses,
                providerOrdering: providerOrdering,
                canEditProviderSelection: canEditProviderSelection,
                onProviderChange: onProviderChange,
                onModelChange: onModelChange,
                onTrustProject: onTrustProject,
                onRefreshProviders: onRefreshProviders
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ComposerView(text: $draft) {
                let outbound = draft
                draft = ""
                onSend(outbound)
            }
            .disabled(hasPendingPrompt)
            .frame(height: ComposerMetrics.height)
            .padding(12)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                if let status = turnState.statusMessage {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            if turnState.canCancel {
                Button {
                    onCancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Cancel provider process")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    private var visibleRows: [DemoChatRow] {
        guard let streamingText = turnState.streamingText, !streamingText.isEmpty else {
            return rows
        }
        return rows + [
            DemoChatRow(
                id: "streaming-assistant",
                kind: .message(role: .assistant, text: streamingText)
            )
        ]
    }

    private var shouldShowWorkingIndicator: Bool {
        turnState.isActive && (turnState.streamingText?.isEmpty ?? true) && !hasPendingPrompt
    }

    private var hasPendingPrompt: Bool {
        rows.contains { row in
            guard case let .prompt(prompt) = row.kind else {
                return false
            }
            return prompt.submittedAnswers == nil
        }
    }

    private var workingIndicatorTopSpacing: CGFloat {
        guard let last = visibleRows.last else {
            return 0
        }
        return last.side == .agent ? 6 : 12
    }

    private var scrollAnchor: String? {
        if shouldShowWorkingIndicator {
            return "working-indicator"
        }
        return visibleRows.last?.id
    }

    private func topSpacing(for index: Int, row: DemoChatRow) -> CGFloat {
        guard index > 0 else {
            return 0
        }
        let previous = visibleRows[index - 1]
        return previous.side == row.side ? 6 : 12
    }
}

private struct ProviderComposerControls: View {
    let providerId: AgentProviderID
    let selectedModelOptionID: String
    let providerStatuses: [AgentProviderID: AgentProviderStatus]
    let providerOrdering: [AgentProviderID]
    let canEditProviderSelection: Bool
    var onProviderChange: (AgentProviderID) -> Void
    var onModelChange: (String) -> Void
    var onTrustProject: () -> Void
    var onRefreshProviders: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Provider", selection: providerBinding) {
                ForEach(orderedProviderIds, id: \.self) { providerID in
                    Text(providerStatuses[providerID]?.definition?.displayName ?? providerID.rawValue.capitalized)
                        .tag(providerID)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .disabled(!canEditProviderSelection)

            Picker("Model", selection: modelBinding) {
                ForEach(modelOptions, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)
            .disabled(!canEditProviderSelection || modelOptions.count <= 1)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(isReady ? Color.secondary : Color.orange)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if shouldShowTrustButton {
                Button(action: onTrustProject) {
                    Label("Trust Project", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderless)
                .help("Trust this project for \(providerDisplayName)")
            }

            Button(action: onRefreshProviders) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Refresh provider status")
        }
        .controlSize(.small)
    }

    private var providerBinding: Binding<AgentProviderID> {
        Binding(
            get: { providerId },
            set: { newValue in onProviderChange(newValue) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { selectedModelOptionID },
            set: { newValue in onModelChange(newValue) }
        )
    }

    private var orderedProviderIds: [AgentProviderID] {
        let extras = providerStatuses.keys.filter { !providerOrdering.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return providerOrdering + extras
    }

    private var modelOptions: [AgentModelOption] {
        let options = providerStatuses[providerId]?.modelOptions ?? []
        return options.isEmpty ? AgentDefaultModelOptions.providerDefault(for: providerId) : options
    }

    private var providerDisplayName: String {
        providerStatuses[providerId]?.definition?.displayName ?? providerId.rawValue.capitalized
    }

    private var isReady: Bool {
        providerStatuses[providerId]?.isReadyInProject == true
    }

    private var shouldShowTrustButton: Bool {
        guard let status = providerStatuses[providerId],
              status.isEnabled,
              status.isInstalled,
              status.isSetupReady,
              let projectTrust = status.projectTrust else {
            return false
        }
        return !projectTrust.allowsProviderWork
    }

    private var statusText: String {
        guard let status = providerStatuses[providerId] else {
            return "Status unknown"
        }
        return DemoModel.providerStatusSummary(status)
    }
}

private struct ChatRowView: View {
    let row: DemoChatRow
    var onSubmitPrompt: (AgentInteractionID, [DemoPromptAnswer]) -> Void

    var body: some View {
        HStack {
            if row.side == .user {
                Spacer(minLength: 48)
            }
            rowContent
            if row.side == .agent {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: row.side == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row.kind {
        case .message(let role, let text):
            MessageBubble(role: role, text: text)
        case .reasoning(let text):
            EventBubble(title: "Reasoning", text: text, monospaced: false)
        case .toolCall(let name, let input):
            EventBubble(title: "Tool: \(name)", text: input, monospaced: true)
        case .toolResult(let isError, let content):
            EventBubble(title: isError ? "Tool Error" : "Tool Result", text: content, monospaced: true)
        case .diagnostic(let severity, let message):
            EventBubble(title: severity.rawValue.capitalized, text: message, monospaced: true)
        case .rawOutput(let text):
            EventBubble(title: "Raw Output", text: text, monospaced: true)
        case .interaction(let kind, let prompt):
            EventBubble(title: "Interaction: \(kind.rawValue)", text: prompt, monospaced: false)
        case .prompt(let prompt):
            PromptBubble(prompt: prompt) { answers in
                onSubmitPrompt(prompt.id, answers)
            }
        case .rateLimit(let summary):
            StatusRow(text: "Rate limit: \(summary)")
        case .usage(let summary):
            StatusRow(text: "Usage: \(summary)")
        case .status(let summary):
            StatusRow(text: summary)
        case .lifecycle(let state, let message):
            StatusRow(text: [state.rawValue.capitalized, message].compactMap { $0 }.joined(separator: ": "))
        }
    }
}

private struct MessageBubble: View {
    let role: AgentMessageRole
    let text: String

    var body: some View {
        MarkdownText(text)
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: 640, alignment: role == .user ? .trailing : .leading)
    }

    private var backgroundColor: Color {
        role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10)
    }
}

private struct EventBubble: View {
    let title: String
    let text: String
    let monospaced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(text.isEmpty ? "No content" : text)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 640, alignment: .leading)
    }
}

private struct StatusRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.vertical, 3)
            .frame(maxWidth: 640, alignment: .leading)
    }
}

private struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        if let attributed = try? AttributedString(markdown: text) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

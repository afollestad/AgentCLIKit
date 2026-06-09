import AgentCLIKit
import SwiftUI

struct ProviderComposerControls: View {
    let providerId: AgentProviderID
    let selectedModelOptionID: String
    let effortOptions: [AgentProviderOption]
    let selectedEffortOptionValue: String
    let selectedSpeedMode: AgentSpeedMode
    let providerStatuses: [AgentProviderID: AgentProviderStatus]
    let providerOrdering: [AgentProviderID]
    let canEditProviderSelection: Bool
    var onProviderChange: (AgentProviderID) -> Void
    var onModelChange: (String) -> Void
    var onEffortChange: (String) -> Void
    var onSpeedChange: (AgentSpeedMode) -> Void
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

            if !effortOptions.isEmpty {
                Picker("Effort", selection: effortBinding) {
                    ForEach(effortOptions, id: \.value) { option in
                        Text(option.label)
                            .tag(option.value)
                            .help(option.description)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .disabled(!canEditProviderSelection || effortOptions.count <= 1)
                .help(selectedEffortDescription)
            }

            if supportsSpeedMode {
                Picker("Speed", selection: speedBinding) {
                    Text("Standard").tag(AgentSpeedMode.standard)
                    Text("Fast").tag(AgentSpeedMode.fast)
                }
                .pickerStyle(.menu)
                .frame(width: 105)
                .disabled(!canEditProviderSelection)
                .help("Select Codex speed mode")
            }

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

    private var effortBinding: Binding<String> {
        Binding(
            get: { selectedEffortOptionValue },
            set: { newValue in onEffortChange(newValue) }
        )
    }

    private var speedBinding: Binding<AgentSpeedMode> {
        Binding(
            get: { selectedSpeedMode },
            set: { newValue in onSpeedChange(newValue) }
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

    private var selectedEffortDescription: String {
        effortOptions.first { $0.value == selectedEffortOptionValue }?.description ?? "Select model effort"
    }

    private var isReady: Bool {
        providerStatuses[providerId]?.isReadyInProject == true
    }

    private var supportsSpeedMode: Bool {
        providerStatuses[providerId]?.definition?.capabilities.supportsSpeedMode == true
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

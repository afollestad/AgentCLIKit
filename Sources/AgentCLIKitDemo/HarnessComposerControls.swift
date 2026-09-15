import AgentCLIKit
import SwiftUI

struct HarnessComposerControls: View {
    let harnessId: AgentHarnessID
    let selectedModelOptionID: String
    let effortOptions: [AgentHarnessOption]
    let selectedEffortOptionValue: String
    let selectedSpeedMode: AgentSpeedMode
    let harnessStatuses: [AgentHarnessID: AgentHarnessStatus]
    let harnessOrdering: [AgentHarnessID]
    let canEditHarnessSelection: Bool
    var onHarnessChange: (AgentHarnessID) -> Void
    var onModelChange: (String) -> Void
    var onEffortChange: (String) -> Void
    var onSpeedChange: (AgentSpeedMode) -> Void
    var onTrustProject: () -> Void
    var onRefreshHarnesses: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Harness", selection: harnessBinding) {
                ForEach(orderedHarnessIds, id: \.self) { harnessID in
                    Text(harnessStatuses[harnessID]?.definition?.displayName ?? harnessID.rawValue.capitalized)
                        .tag(harnessID)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .disabled(!canEditHarnessSelection)

            Picker("Model", selection: modelBinding) {
                ForEach(modelOptions, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)
            .disabled(!canEditHarnessSelection || modelOptions.count <= 1)

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
                .disabled(!canEditHarnessSelection || effortOptions.count <= 1)
                .help(selectedEffortDescription)
            }

            if supportsSpeedMode {
                Picker("Speed", selection: speedBinding) {
                    Text("Standard").tag(AgentSpeedMode.standard)
                    Text("Fast").tag(AgentSpeedMode.fast)
                }
                .pickerStyle(.menu)
                .frame(width: 105)
                .disabled(!canEditHarnessSelection)
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
                .help("Trust this project for \(harnessDisplayName)")
            }

            Button(action: onRefreshHarnesses) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Refresh harness status")
        }
        .controlSize(.small)
    }

    private var harnessBinding: Binding<AgentHarnessID> {
        Binding(
            get: { harnessId },
            set: { newValue in onHarnessChange(newValue) }
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

    private var orderedHarnessIds: [AgentHarnessID] {
        let extras = harnessStatuses.keys.filter { !harnessOrdering.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return harnessOrdering + extras
    }

    private var modelOptions: [AgentModelOption] {
        let options = harnessStatuses[harnessId]?.modelOptions ?? []
        return options.isEmpty ? AgentDefaultModelOptions.staticOptions(for: harnessId) : options
    }

    private var harnessDisplayName: String {
        harnessStatuses[harnessId]?.definition?.displayName ?? harnessId.rawValue.capitalized
    }

    private var selectedEffortDescription: String {
        effortOptions.first { $0.value == selectedEffortOptionValue }?.description ?? "Select model effort"
    }

    private var isReady: Bool {
        harnessStatuses[harnessId]?.isReadyInProject == true
    }

    private var supportsSpeedMode: Bool {
        harnessStatuses[harnessId]?.definition?.capabilities.supportsSpeedMode == true
    }

    private var shouldShowTrustButton: Bool {
        guard let status = harnessStatuses[harnessId],
              status.isEnabled,
              status.isInstalled,
              status.isSetupReady,
              let projectTrust = status.projectTrust else {
            return false
        }
        return !projectTrust.allowsHarnessWork
    }

    private var statusText: String {
        guard let status = harnessStatuses[harnessId] else {
            return "Status unknown"
        }
        return DemoModel.harnessStatusSummary(status)
    }
}

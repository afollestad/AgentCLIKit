import AgentCLIKit

extension DemoModel {
    func defaultHarnessId() -> AgentHarnessID {
        harnessOrdering.first { harnessStatuses[$0]?.isReadyInProject == true }
            ?? harnessOrdering.first
            ?? .claude
    }

    func defaultModelOptionID(harnessId: AgentHarnessID) -> String {
        let options = modelOptions(for: harnessId)
        return options.first(where: \.isDefault)?.id ?? options.first?.id ?? "default"
    }

    func defaultEffortOptionValue(harnessId: AgentHarnessID, modelOptionID: String) -> String? {
        normalizedEffortOptionValue(harnessId: harnessId, modelOptionID: modelOptionID, current: nil)
    }

    func modelOptions(for harnessId: AgentHarnessID) -> [AgentModelOption] {
        let options = harnessStatuses[harnessId]?.modelOptions ?? []
        return options.isEmpty ? AgentDefaultModelOptions.staticOptions(for: harnessId) : options
    }

    func selectedModelOption(for sessionID: AgentConversationID, harnessId: AgentHarnessID) -> AgentModelOption? {
        let options = modelOptions(for: harnessId)
        let selectedID = modelSelectionBySession[sessionID] ?? defaultModelOptionID(harnessId: harnessId)
        return options.first { $0.id == selectedID } ?? options.first(where: \.isDefault) ?? options.first
    }

    func selectedModelOption(harnessId: AgentHarnessID, modelOptionID: String) -> AgentModelOption? {
        let options = modelOptions(for: harnessId)
        return options.first { $0.id == modelOptionID } ?? options.first(where: \.isDefault) ?? options.first
    }

    func selectedEffortOptionValueForSpawn(for sessionID: AgentConversationID) -> String? {
        let selectedEffort = selectedEffortOptionValue(for: sessionID)
        return selectedEffort.isEmpty ? nil : selectedEffort
    }

    func normalizedEffortOptionValue(harnessId: AgentHarnessID, modelOptionID: String, current: String?) -> String? {
        guard let modelOption = selectedModelOption(harnessId: harnessId, modelOptionID: modelOptionID),
              !modelOption.supportedEffortOptions.isEmpty else {
            return nil
        }
        if let current,
           modelOption.supportedEffortOptions.contains(where: { $0.value == current }) {
            return current
        }
        return modelOption.defaultEffortOption?.value ?? modelOption.supportedEffortOptions.first?.value
    }

    func normalizeModelAndEffortSelection(for sessionID: AgentConversationID, harnessId: AgentHarnessID) {
        let selectedModelOptionID = selectedModelOptionID(for: sessionID)
        modelSelectionBySession[sessionID] = selectedModelOptionID
        effortSelectionBySession[sessionID] = normalizedEffortOptionValue(
            harnessId: harnessId,
            modelOptionID: selectedModelOptionID,
            current: effortSelectionBySession[sessionID]
        )
    }

    func validateHarnessReadiness(_ harnessId: AgentHarnessID, sessionID: AgentConversationID) throws {
        guard let status = harnessStatuses[harnessId] else {
            throw AgentCLIError.harnessUnavailable(harnessId)
        }
        guard status.isReadyInProject else {
            let message = Self.harnessStatusSummary(status)
            appendStatus(message, to: sessionID)
            throw AgentCLIError.invalidInput(message)
        }
    }
}

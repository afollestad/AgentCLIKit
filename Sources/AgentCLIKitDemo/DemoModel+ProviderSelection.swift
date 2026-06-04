import AgentCLIKit

extension DemoModel {
    func defaultProviderId() -> AgentProviderID {
        providerOrdering.first { providerStatuses[$0]?.isReadyInProject == true }
            ?? providerOrdering.first
            ?? .claude
    }

    func defaultModelOptionID(providerId: AgentProviderID) -> String {
        let options = modelOptions(for: providerId)
        return options.first(where: \.isDefault)?.id ?? options.first?.id ?? "default"
    }

    func defaultEffortOptionValue(providerId: AgentProviderID, modelOptionID: String) -> String? {
        normalizedEffortOptionValue(providerId: providerId, modelOptionID: modelOptionID, current: nil)
    }

    func modelOptions(for providerId: AgentProviderID) -> [AgentModelOption] {
        let options = providerStatuses[providerId]?.modelOptions ?? []
        return options.isEmpty ? AgentDefaultModelOptions.providerDefault(for: providerId) : options
    }

    func selectedModelOption(for sessionID: AgentConversationID, providerId: AgentProviderID) -> AgentModelOption? {
        let options = modelOptions(for: providerId)
        let selectedID = modelSelectionBySession[sessionID] ?? defaultModelOptionID(providerId: providerId)
        return options.first { $0.id == selectedID } ?? options.first(where: \.isDefault) ?? options.first
    }

    func selectedModelOption(providerId: AgentProviderID, modelOptionID: String) -> AgentModelOption? {
        let options = modelOptions(for: providerId)
        return options.first { $0.id == modelOptionID } ?? options.first(where: \.isDefault) ?? options.first
    }

    func selectedEffortOptionValueForSpawn(for sessionID: AgentConversationID) -> String? {
        let selectedEffort = selectedEffortOptionValue(for: sessionID)
        return selectedEffort.isEmpty ? nil : selectedEffort
    }

    func normalizedEffortOptionValue(providerId: AgentProviderID, modelOptionID: String, current: String?) -> String? {
        guard let modelOption = selectedModelOption(providerId: providerId, modelOptionID: modelOptionID),
              !modelOption.supportedEffortOptions.isEmpty else {
            return nil
        }
        if let current,
           modelOption.supportedEffortOptions.contains(where: { $0.value == current }) {
            return current
        }
        return modelOption.defaultEffortOption?.value ?? modelOption.supportedEffortOptions.first?.value
    }

    func normalizeModelAndEffortSelection(for sessionID: AgentConversationID, providerId: AgentProviderID) {
        let selectedModelOptionID = selectedModelOptionID(for: sessionID)
        modelSelectionBySession[sessionID] = selectedModelOptionID
        effortSelectionBySession[sessionID] = normalizedEffortOptionValue(
            providerId: providerId,
            modelOptionID: selectedModelOptionID,
            current: effortSelectionBySession[sessionID]
        )
    }

    func validateProviderReadiness(_ providerId: AgentProviderID, sessionID: AgentConversationID) throws {
        guard let status = providerStatuses[providerId] else {
            throw AgentCLIError.providerUnavailable(providerId)
        }
        guard status.isReadyInProject else {
            let message = Self.providerStatusSummary(status)
            appendStatus(message, to: sessionID)
            throw AgentCLIError.invalidInput(message)
        }
    }
}

import AgentCLIKit

extension DemoModel {
    func selectedSpeedMode(for sessionID: AgentConversationID) -> AgentSpeedMode {
        guard supportsSpeedMode(for: providerId(for: sessionID)) else {
            return .standard
        }
        return speedSelectionBySession[sessionID] ?? .standard
    }

    func setSpeedMode(_ speedMode: AgentSpeedMode, for sessionID: AgentConversationID) {
        guard canEditProviderSelection(for: sessionID),
              supportsSpeedMode(for: providerId(for: sessionID)) else {
            return
        }
        speedSelectionBySession[sessionID] = speedMode
    }

    func supportsSpeedMode(for providerId: AgentProviderID) -> Bool {
        providerStatuses[providerId]?.definition?.capabilities.supportsSpeedMode == true
    }
}

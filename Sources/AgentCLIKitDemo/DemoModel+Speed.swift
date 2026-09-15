import AgentCLIKit

extension DemoModel {
    func selectedSpeedMode(for sessionID: AgentConversationID) -> AgentSpeedMode {
        guard supportsSpeedMode(for: harnessId(for: sessionID)) else {
            return .standard
        }
        return speedSelectionBySession[sessionID] ?? .standard
    }

    func setSpeedMode(_ speedMode: AgentSpeedMode, for sessionID: AgentConversationID) {
        guard canEditHarnessSelection(for: sessionID),
              supportsSpeedMode(for: harnessId(for: sessionID)) else {
            return
        }
        speedSelectionBySession[sessionID] = speedMode
    }

    func supportsSpeedMode(for harnessId: AgentHarnessID) -> Bool {
        harnessStatuses[harnessId]?.definition?.capabilities.supportsSpeedMode == true
    }
}

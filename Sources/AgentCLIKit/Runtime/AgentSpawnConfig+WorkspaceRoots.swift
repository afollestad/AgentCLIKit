import Foundation

extension AgentSpawnConfig {
    func validateAdditionalWorkspaceRoots() throws {
        guard additionalWorkspaceRoots.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else {
            throw AgentCLIError.invalidInput("Additional workspace roots must be absolute file URLs.")
        }
    }
}

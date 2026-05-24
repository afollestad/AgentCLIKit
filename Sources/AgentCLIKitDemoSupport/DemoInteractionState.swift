import AgentCLIKit
import Foundation

/// Testable demo-facing projection of pending interactions and runtime status.
public struct DemoInteractionState: Equatable, Sendable {
    /// Pending actions shown by the demo.
    public let pendingActions: [AgentPendingAction]
    /// Latest runtime status shown by the demo.
    public let status: AgentRuntimeStatus?

    /// Creates a demo interaction state.
    public init(pendingActions: [AgentPendingAction] = [], status: AgentRuntimeStatus? = nil) {
        self.pendingActions = pendingActions
        self.status = status
    }

    /// Whether the composer should accept user input.
    public var canSendInput: Bool {
        guard let status else {
            return false
        }
        return status.inputAvailability == .available
    }
}

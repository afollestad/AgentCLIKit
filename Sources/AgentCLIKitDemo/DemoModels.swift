import AgentCLIKit
import Foundation

enum DemoRowSide: Equatable {
    case agent
    case user
}

enum DemoChatRowKind: Equatable {
    case message(role: AgentMessageRole, text: String)
    case reasoning(String)
    case toolCall(name: String, input: String)
    case toolResult(isError: Bool, content: String)
    case diagnostic(severity: AgentDiagnosticSeverity, message: String)
    case rawOutput(String)
    case interaction(kind: AgentInteractionKind, prompt: String)
    case prompt(DemoPrompt)
    case rateLimit(String)
    case usage(String)
    case status(String)
    case lifecycle(AgentLifecycleState, String?)
}

struct DemoChatRow: Identifiable, Equatable {
    let id: String
    var kind: DemoChatRowKind

    var side: DemoRowSide {
        switch kind {
        case .message(role: .user, text: _):
            return .user
        default:
            return .agent
        }
    }
}

struct DemoSession: Identifiable {
    let id: AgentConversationID
    var record: AgentSessionRecord?
    var createdAt: Date

    var title: String {
        if let rawValue = record?.providerSessionId.rawValue, !rawValue.isEmpty {
            let providerName = record?.providerId.rawValue.capitalized ?? "Provider"
            return "\(providerName) \(rawValue.prefix(8))"
        }
        return "Session \(id.rawValue.prefix(8))"
    }

    var subtitle: String {
        record?.providerId.rawValue ?? "New session"
    }
}

struct DemoTurnState: Equatable {
    var isActive = false
    var streamingText: String?
    var statusMessage: String?
    var canCancel = false
}

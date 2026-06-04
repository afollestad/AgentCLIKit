import Foundation

/// Claude hook request after transport parsing.
public struct ClaudeHookRequest: Codable, Equatable, Sendable {
    /// Bearer token supplied by Claude hook configuration.
    public let bearerToken: String?
    /// Claude hook name, such as `PreToolUse`.
    public let hookName: String
    /// Host conversation identifier when known.
    public let conversationId: AgentConversationID
    /// Runtime process generation token when the generated hook URL supplied one.
    public let processToken: UUID?
    /// Hook payload.
    public let payload: JSONValue

    /// Creates a Claude hook request.
    public init(
        bearerToken: String?,
        hookName: String,
        conversationId: AgentConversationID,
        payload: JSONValue,
        processToken: UUID? = nil
    ) {
        self.bearerToken = bearerToken
        self.hookName = hookName
        self.conversationId = conversationId
        self.processToken = processToken
        self.payload = payload
    }
}

/// Live hook decision provider used by Claude hook handling.
///
/// Implementations may run on any actor. Host UI should use `MainActorClaudeHookDecisionProvider` when collecting decisions
/// from SwiftUI or AppKit state.
public protocol ClaudeHookDecisionProviding: Sendable {
    /// Returns a decision for a Claude hook request.
    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision
}

/// Main-actor bridge for host UI objects that collect live Claude hook decisions.
public struct MainActorClaudeHookDecisionProvider: ClaudeHookDecisionProviding {
    private let handler: @MainActor @Sendable (ClaudeHookRequest, AgentInteractionID) async -> ClaudeHookDecision

    /// Creates a provider that always evaluates decisions on the main actor.
    public init(_ handler: @escaping @MainActor @Sendable (ClaudeHookRequest, AgentInteractionID) async -> ClaudeHookDecision) {
        self.handler = handler
    }

    /// Returns a decision by hopping to the main actor before invoking the host handler.
    public func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        await handler(request, interactionId)
    }
}

public extension ClaudeHookDecisionProviding where Self == MainActorClaudeHookDecisionProvider {
    /// Creates a main-actor provider for app-owned approval UI.
    static func mainActor(
        _ handler: @escaping @MainActor @Sendable (ClaudeHookRequest, AgentInteractionID) async -> ClaudeHookDecision
    ) -> MainActorClaudeHookDecisionProvider {
        MainActorClaudeHookDecisionProvider(handler)
    }
}

/// Claude hook policy values shared by settings generation and host integrations.
public enum ClaudeHookPolicy {
    private static let directlyApprovalControlledTools = [
        "Bash",
        "Write",
        "Edit",
        "MultiEdit",
        "NotebookEdit"
    ]
    /// Matcher used for the Claude `PreToolUse` hook registration.
    public static let preToolUseMatcher = "AskUserQuestion|Bash|Write|Edit|MultiEdit|NotebookEdit|EnterPlanMode|ExitPlanMode|mcp__.*"
    /// Matcher used for Claude context compaction lifecycle hooks.
    public static let compactMatcher = "manual|auto"
    /// Claude hook transport timeout registered in generated settings.
    public static let defaultHookTimeoutSeconds = 600
    /// Default maximum wait for app-owned decisions before returning a deferred response.
    public static let defaultDecisionTimeout: TimeInterval = 115

    /// Returns whether generated hooks should be enabled for a launch permission mode.
    public static func shouldEnableHooks(permissionMode: String?) -> Bool {
        switch permissionMode {
        case "auto", "bypassPermissions", "dontAsk":
            false
        default:
            true
        }
    }

    /// Returns whether a tool should be deferred to the host for the active permission mode.
    public static func shouldDefer(toolName: String, permissionMode: String?) -> Bool {
        if toolName == "AskUserQuestion" {
            return true
        }
        if toolName == "ExitPlanMode" {
            return permissionMode == "plan"
        }

        switch permissionMode {
        case "auto", "bypassPermissions", "dontAsk":
            return false
        case "acceptEdits":
            return toolName == "Bash" || isMutatingMCPTool(toolName)
        default:
            return isPotentiallyApprovalControlledTool(toolName)
        }
    }

    /// Returns whether a tool can become a host-controlled approval.
    public static func isPotentiallyApprovalControlledTool(_ toolName: String) -> Bool {
        switch toolName {
        case "AskUserQuestion", "ExitPlanMode":
            return true
        default:
            return directlyApprovalControlledTools.contains(toolName) || isMutatingMCPTool(toolName)
        }
    }

    /// Returns whether an MCP tool name appears mutating.
    public static func isMutatingMCPTool(_ toolName: String) -> Bool {
        guard toolName.hasPrefix("mcp__"),
              let lastComponent = toolName.split(separator: "__").last?.lowercased() else {
            return false
        }
        return ["write", "create", "update", "delete", "remove", "send", "post"].contains {
            lastComponent.hasPrefix($0)
        }
    }
}

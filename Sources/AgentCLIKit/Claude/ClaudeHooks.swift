import Foundation

/// Claude hook request after transport parsing.
public struct ClaudeHookRequest: Codable, Equatable, Sendable {
    /// Bearer token supplied by Claude hook configuration.
    public let bearerToken: String?
    /// Claude hook name, such as `PreToolUse`.
    public let hookName: String
    /// Host conversation identifier when known.
    public let conversationId: AgentConversationID
    /// Hook payload.
    public let payload: JSONValue

    /// Creates a Claude hook request.
    public init(bearerToken: String?, hookName: String, conversationId: AgentConversationID, payload: JSONValue) {
        self.bearerToken = bearerToken
        self.hookName = hookName
        self.conversationId = conversationId
        self.payload = payload
    }
}

/// Live hook decision provider used by Claude hook handling.
public protocol ClaudeHookDecisionProviding: Sendable {
    /// Returns a decision for a Claude hook request.
    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision
}

/// Claude hook policy values shared by settings generation and host integrations.
public enum ClaudeHookPolicy {
    /// Matcher used for the Claude `PreToolUse` hook registration.
    public static let preToolUseMatcher = "AskUserQuestion|Bash|Write|Edit|MultiEdit|NotebookEdit|EnterPlanMode|ExitPlanMode|mcp__.*"
    /// Claude hook transport timeout registered in generated settings.
    public static let defaultHookTimeoutSeconds = 600
    /// Default maximum wait for app-owned decisions before returning a deferred response.
    public static let defaultDecisionTimeout: TimeInterval = 115
}

/// Claude hook settings payload for registering AgentCLIKit's local hook endpoint.
public struct ClaudeHookSettings: Equatable, Sendable {
    /// Local HTTP endpoint that Claude should call for `PreToolUse`.
    public let endpointURL: URL
    /// Environment variable name that holds the bearer token.
    public let tokenEnvironmentVariable: String
    /// Claude hook timeout in seconds.
    public let timeoutSeconds: Int

    /// Creates Claude hook settings.
    public init(
        endpointURL: URL,
        tokenEnvironmentVariable: String = "AGENTCLIKIT_CLAUDE_HOOK_TOKEN",
        timeoutSeconds: Int = ClaudeHookPolicy.defaultHookTimeoutSeconds
    ) {
        self.endpointURL = endpointURL
        self.tokenEnvironmentVariable = tokenEnvironmentVariable
        self.timeoutSeconds = timeoutSeconds
    }

    /// Encodes Claude-compatible settings JSON.
    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private var payload: ClaudeHookSettingsPayload {
        ClaudeHookSettingsPayload(hooks: [
            "PreToolUse": [
                ClaudeHookMatcher(
                    matcher: ClaudeHookPolicy.preToolUseMatcher,
                    hooks: [
                        ClaudeHookTransport(
                            type: "http",
                            url: endpointURL.absoluteString,
                            timeout: timeoutSeconds,
                            headers: [
                                "Authorization": "Bearer $\(tokenEnvironmentVariable)"
                            ],
                            allowedEnvVars: [tokenEnvironmentVariable]
                        )
                    ]
                )
            ]
        ])
    }
}

/// Claude hook handler with bearer-token validation and approval fallback behavior.
public actor ClaudeHookServer {
    private let tokenStore: AgentHookTokenStore
    private let interactionStore: any AgentInteractionStore
    private let approvalPolicyStore: ClaudeApprovalPolicyStore
    private let decisionProvider: (any ClaudeHookDecisionProviding)?
    private let decisionTimeout: TimeInterval?
    private var pendingDecisionRaces: [String: [UUID: ClaudeHookDecisionRace]] = [:]

    /// Creates a Claude hook server.
    /// - Parameters:
    ///   - tokenStore: Token store used to validate bearer tokens.
    ///   - interactionStore: Store used to surface pending hook interactions.
    ///   - approvalPolicyStore: Store for session and transient approvals.
    ///   - decisionProvider: Optional live decision provider for app-owned approval UI.
    ///   - decisionTimeout: Maximum live decision wait before deferring; pass `nil` to wait indefinitely. The default is
    ///     shorter than the generated hook transport timeout so deferred responses can be returned before Claude closes the request.
    public init(
        tokenStore: AgentHookTokenStore,
        interactionStore: any AgentInteractionStore,
        approvalPolicyStore: ClaudeApprovalPolicyStore = ClaudeApprovalPolicyStore(),
        decisionProvider: (any ClaudeHookDecisionProviding)? = nil,
        decisionTimeout: TimeInterval? = ClaudeHookPolicy.defaultDecisionTimeout
    ) {
        self.tokenStore = tokenStore
        self.interactionStore = interactionStore
        self.approvalPolicyStore = approvalPolicyStore
        self.decisionProvider = decisionProvider
        self.decisionTimeout = decisionTimeout
    }

    /// Handles a Claude hook request.
    public func handle(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        guard let token = request.bearerToken, await tokenStore.validate(token) else {
            return response(for: .deny(reason: "invalid_token"))
        }
        switch request.hookName {
        case "PreToolUse":
            return await handlePreToolUse(request)
        case "AskUserQuestion":
            return await handlePrompt(request)
        case "PlanModeExit":
            return await handlePlanModeExit(request)
        default:
            return response(for: .deferDecision)
        }
    }

    /// Invalidates a hook bearer token.
    public func invalidateToken(_ token: String) async {
        await tokenStore.invalidate(token)
        releasePendingDecisionRaces(for: token)
    }

    private func handlePreToolUse(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        let operation = request.toolName
        switch operation {
        case "AskUserQuestion":
            return await handlePrompt(request)
        case "ExitPlanMode":
            return await handlePlanModeExit(request)
        default:
            break
        }

        let interactionId = request.interactionId
        if let policyDecision = await policyDecision(operation: operation, interactionId: interactionId, request: request) {
            return response(for: policyDecision)
        }
        let approval = AgentApprovalRequest(
            id: interactionId,
            providerId: ClaudeProviderAdapter.providerId,
            conversationId: request.conversationId,
            operation: operation,
            reason: "Claude requested tool approval.",
            input: request.payload
        )
        await interactionStore.save(AgentInteractionRecord(
            id: interactionId,
            conversationId: request.conversationId,
            kind: .approval,
            approvalRequest: approval
        ))
        let decision = await liveDecision(for: request, interactionId: interactionId)
        await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .approved, deniedOutcome: .denied)
        return response(for: decision)
    }

    private func handlePrompt(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        let interactionId = request.interactionId
        let prompt = request.promptText ?? "Claude asked a question."
        await interactionStore.save(AgentInteractionRecord(
            id: interactionId,
            conversationId: request.conversationId,
            kind: .prompt,
            promptRequest: AgentPromptRequest(id: interactionId, conversationId: request.conversationId, prompt: prompt)
        ))
        let decision = await liveDecision(for: request, interactionId: interactionId)
        await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .answered, deniedOutcome: .cancelled)
        return response(for: decision, interactionId: interactionId)
    }

    private func handlePlanModeExit(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        let interactionId = request.interactionId
        if let policyDecision = await policyDecision(operation: "ExitPlanMode", interactionId: interactionId, request: request) {
            return response(for: policyDecision)
        }
        let approval = AgentApprovalRequest(
            id: interactionId,
            providerId: ClaudeProviderAdapter.providerId,
            conversationId: request.conversationId,
            operation: "ExitPlanMode",
            reason: "Claude requested to exit planning mode.",
            input: request.payload
        )
        await interactionStore.save(AgentInteractionRecord(
            id: interactionId,
            conversationId: request.conversationId,
            kind: .planModeExit,
            approvalRequest: approval
        ))
        let decision = await liveDecision(for: request, interactionId: interactionId)
        await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .approved, deniedOutcome: .denied)
        return response(for: decision)
    }

    private func liveDecision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        guard let decisionProvider else {
            return .deferDecision
        }

        let raceId = UUID()
        let race = ClaudeHookDecisionRace()
        let token = request.bearerToken
        if let token {
            guard await tokenStore.validate(token) else {
                return .deferDecision
            }
            pendingDecisionRaces[token, default: [:]][raceId] = race
        }

        // Hook transports have hard deadlines and launch teardown can invalidate tokens, so an unstructured race keeps the HTTP
        // request releasable even if a host UI provider is still waiting on user input.
        let decision = await withCheckedContinuation { continuation in
            race.setContinuation(continuation)
            let decisionTask = Task {
                let decision = await decisionProvider.decision(for: request, interactionId: interactionId)
                race.resolve(with: decision, winner: .decision)
            }
            race.setDecisionTask(decisionTask)
            if let decisionTimeout, decisionTimeout > 0 {
                let timeoutNanoseconds = Self.timeoutNanoseconds(from: decisionTimeout)
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    race.resolve(with: .deferDecision, winner: .timeout)
                }
                race.setTimeoutTask(timeoutTask)
            }
        }

        if let token {
            pendingDecisionRaces[token]?[raceId] = nil
            if pendingDecisionRaces[token]?.isEmpty == true {
                pendingDecisionRaces[token] = nil
            }
        }
        return decision
    }

    private func releasePendingDecisionRaces(for token: String) {
        let races: [ClaudeHookDecisionRace] = pendingDecisionRaces.removeValue(forKey: token).map { Array($0.values) } ?? []
        for race in races {
            race.resolve(with: .deferDecision, winner: .invalidation)
        }
    }

    private static func timeoutNanoseconds(from interval: TimeInterval) -> UInt64 {
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(max(interval, 0), maximumSeconds) * 1_000_000_000)
    }

    private func policyDecision(
        operation: String,
        interactionId: AgentInteractionID,
        request: ClaudeHookRequest
    ) async -> ClaudeHookDecision? {
        // Transient approvals are keyed by Claude's tool_use_id when present, so a retried hook can resolve the same record.
        if await approvalPolicyStore.consumeTransientApproval(id: interactionId) {
            let decision = ClaudeHookDecision.allow(updatedInput: request.updatedInputForAllowedOperation(operation))
            await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .approved, deniedOutcome: .denied)
            return decision
        }
        if await approvalPolicyStore.isSessionApproved(operation: operation) {
            let decision = ClaudeHookDecision.allow(updatedInput: request.updatedInputForAllowedOperation(operation))
            await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .approved, deniedOutcome: .denied)
            return decision
        }
        return nil
    }

    private func resolveInteractionIfNeeded(
        _ decision: ClaudeHookDecision,
        interactionId: AgentInteractionID,
        approvedOutcome: AgentInteractionOutcome,
        deniedOutcome: AgentInteractionOutcome
    ) async {
        let outcome: AgentInteractionOutcome
        switch decision.approval {
        case .allow:
            outcome = approvedOutcome
        case .deny:
            outcome = deniedOutcome
        case .deferDecision:
            return
        }
        await interactionStore.resolve(AgentInteractionResolution(
            id: interactionId,
            outcome: outcome,
            responseText: decision.reason,
            metadata: decision.resolutionMetadata
        ), updatedAt: Date())
    }

    private func response(for decision: ClaudeHookDecision, interactionId: AgentInteractionID? = nil) -> AgentHookResponse {
        switch decision.approval {
        case .allow:
            AgentHookResponse(statusCode: 200, body: decisionBody(decision, permissionDecision: "allow", interactionId: interactionId))
        case .deny:
            AgentHookResponse(statusCode: 200, body: decisionBody(decision, permissionDecision: "deny", interactionId: interactionId))
        case .deferDecision:
            AgentHookResponse(statusCode: 200, body: decisionBody(decision, permissionDecision: "defer", interactionId: interactionId))
        }
    }

    private func decisionBody(
        _ decision: ClaudeHookDecision,
        permissionDecision: String,
        interactionId: AgentInteractionID? = nil
    ) -> JSONValue {
        var output: [String: JSONValue] = [
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string(permissionDecision)
        ]
        if let reason = decision.reason {
            output["permissionDecisionReason"] = .string(reason)
        }
        if let updatedInput = decision.updatedInput {
            output["updatedInput"] = updatedInput
        }
        var body: [String: JSONValue] = [
            "hookSpecificOutput": .object(output)
        ]
        if let interactionId {
            body["interaction_id"] = .string(interactionId.rawValue)
        }
        return .object(body)
    }
}

private extension ClaudeHookDecision {
    var resolutionMetadata: [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        if let updatedInput {
            metadata["updated_input"] = updatedInput
        }
        return metadata
    }
}

private extension ClaudeHookRequest {
    var interactionId: AgentInteractionID {
        if let toolUseId = payload.objectValue?["tool_use_id"]?.stringValue ?? payload.objectValue?["toolUseId"]?.stringValue,
           !toolUseId.isEmpty {
            return AgentInteractionID(rawValue: toolUseId)
        }
        return AgentInteractionID(rawValue: UUID().uuidString)
    }

    var toolName: String {
        payload.objectValue?["tool_name"]?.stringValue
            ?? payload.objectValue?["toolName"]?.stringValue
            ?? "tool"
    }

    var promptText: String? {
        if let question = payload.objectValue?["question"]?.stringValue {
            return question
        }
        let toolInput = payload.objectValue?["tool_input"] ?? payload.objectValue?["toolInput"]
        guard case let .array(questions)? = toolInput?.objectValue?["questions"],
              case let .object(firstQuestion)? = questions.first else {
            return nil
        }
        return firstQuestion["question"]?.stringValue
    }

    func updatedInputForAllowedOperation(_ operation: String) -> JSONValue? {
        switch operation {
        case "AskUserQuestion", "ExitPlanMode":
            toolInput
        default:
            nil
        }
    }

    var toolInput: JSONValue? {
        payload.objectValue?["tool_input"] ?? payload.objectValue?["toolInput"]
    }
}

private struct ClaudeHookSettingsPayload: Codable {
    let hooks: [String: [ClaudeHookMatcher]]
}

private struct ClaudeHookMatcher: Codable {
    let matcher: String
    let hooks: [ClaudeHookTransport]
}

private struct ClaudeHookTransport: Codable {
    let type: String
    let url: String
    let timeout: Int
    let headers: [String: String]
    let allowedEnvVars: [String]
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}

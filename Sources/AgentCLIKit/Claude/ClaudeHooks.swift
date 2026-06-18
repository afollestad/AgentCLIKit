import Foundation

/// Claude hook handler with bearer-token validation and approval fallback behavior.
public actor ClaudeHookServer {
    private let tokenStore: AgentHookTokenStore
    private let interactionStore: any AgentInteractionStore
    private let approvalPolicyStore: any ClaudeApprovalPolicyStoring
    private let commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy
    private let decisionProvider: (any ClaudeHookDecisionProviding)?
    private let decisionTimeout: TimeInterval?
    private let compactionTracker: ClaudeContextCompactionTracker
    private var pendingDecisionRaces: [String: [UUID: ClaudeHookDecisionRace]] = [:]
    private var permissionModes: [AgentConversationID: String] = [:]
    private var compactHookTokensByProcess: [UUID: String] = [:]
    private var launchContextsByProcess: [UUID: ClaudeHookLaunchContext] = [:]
    private var compactHookContinuations: [UUID: AsyncStream<AgentProviderRuntimeEvent>.Continuation] = [:]
    private var pendingCompactHookEvents: [UUID: [AgentProviderRuntimeEvent]] = [:]

    /// Creates a Claude hook server.
    /// - Parameters:
    ///   - tokenStore: Token store used to validate bearer tokens.
    ///   - interactionStore: Store used to surface pending hook interactions.
    ///   - approvalPolicyStore: Store for session and transient approvals.
    ///   - commandApprovalNormalizationPolicy: Policy used to derive Bash command approval identity.
    ///   - decisionProvider: Optional live decision provider for app-owned approval UI.
    ///   - decisionTimeout: Maximum live decision wait before deferring; pass `nil` to wait indefinitely. The default is
    ///     shorter than the generated hook transport timeout so deferred responses can be returned before Claude closes the request.
    public init(
        tokenStore: AgentHookTokenStore,
        interactionStore: any AgentInteractionStore,
        approvalPolicyStore: any ClaudeApprovalPolicyStoring = ClaudeApprovalPolicyStore(),
        commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy = .default,
        decisionProvider: (any ClaudeHookDecisionProviding)? = nil,
        decisionTimeout: TimeInterval? = ClaudeHookPolicy.defaultDecisionTimeout
    ) {
        self.init(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore,
            commandApprovalNormalizationPolicy: commandApprovalNormalizationPolicy,
            decisionProvider: decisionProvider,
            decisionTimeout: decisionTimeout,
            compactionTracker: ClaudeContextCompactionTracker()
        )
    }

    init(
        tokenStore: AgentHookTokenStore,
        interactionStore: any AgentInteractionStore,
        approvalPolicyStore: any ClaudeApprovalPolicyStoring = ClaudeApprovalPolicyStore(),
        commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy = .default,
        decisionProvider: (any ClaudeHookDecisionProviding)? = nil,
        decisionTimeout: TimeInterval? = ClaudeHookPolicy.defaultDecisionTimeout,
        compactionTracker: ClaudeContextCompactionTracker
    ) {
        self.tokenStore = tokenStore
        self.interactionStore = interactionStore
        self.approvalPolicyStore = approvalPolicyStore
        self.commandApprovalNormalizationPolicy = commandApprovalNormalizationPolicy
        self.decisionProvider = decisionProvider
        self.decisionTimeout = decisionTimeout
        self.compactionTracker = compactionTracker
    }

    /// Handles a Claude hook request.
    public func handle(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        if Self.isCompactHook(request.hookName) {
            return await handleCompact(request)
        }
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
            return .noDecision
        }
    }

    /// Invalidates a hook bearer token.
    public func invalidateToken(_ token: String) async {
        await tokenStore.invalidate(token)
        releasePendingDecisionRaces(for: token)
        let invalidatedProcessTokens = compactHookTokensByProcess.compactMap { processToken, launchToken in
            launchToken == token ? processToken : nil
        }
        for processToken in invalidatedProcessTokens {
            compactHookTokensByProcess[processToken] = nil
            launchContextsByProcess[processToken] = nil
            compactHookContinuations[processToken]?.finish()
            compactHookContinuations[processToken] = nil
            pendingCompactHookEvents[processToken] = nil
            await compactionTracker.reset(processToken: processToken)
        }
    }

    /// Registers a compact hook token for one process generation.
    public func registerCompactHooks(processToken: UUID, token: String) {
        compactHookTokensByProcess[processToken] = token
    }

    /// Registers path context for one process generation so native read-only hooks can preserve Claude's project boundary.
    public func registerLaunchContext(processToken: UUID, workingDirectory: URL, homeDirectory: URL) {
        launchContextsByProcess[processToken] = ClaudeHookLaunchContext(
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )
    }

    /// Attaches a runtime event continuation for compact hook events.
    public func registerCompactRuntimeEvents(
        processToken: UUID,
        continuation: AsyncStream<AgentProviderRuntimeEvent>.Continuation
    ) {
        compactHookContinuations[processToken] = continuation
        let pending = pendingCompactHookEvents.removeValue(forKey: processToken) ?? []
        pending.forEach { continuation.yield($0) }
    }

    /// Detaches the runtime event continuation for one process generation.
    public func unregisterCompactRuntimeEvents(processToken: UUID) {
        compactHookContinuations[processToken] = nil
        pendingCompactHookEvents[processToken] = nil
    }

    /// Updates the cached permission mode for a conversation from provider status output.
    public func updatePermissionMode(_ permissionMode: String?, for conversationId: AgentConversationID) {
        if let permissionMode {
            permissionModes[conversationId] = permissionMode
        } else {
            permissionModes.removeValue(forKey: conversationId)
        }
    }

    private func handlePreToolUse(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        rememberPermissionMode(from: request)
        let operation = request.toolName
        switch operation {
        case "AskUserQuestion":
            return await handlePrompt(request)
        case "EnterPlanMode":
            return .noDecision
        case "ExitPlanMode":
            return await handlePlanModeExit(request)
        default:
            break
        }
        let launchContext = launchContext(for: request)
        guard ClaudeHookPolicy.shouldDeferToolUse(
            toolName: operation,
            toolInput: request.toolInput ?? .object([:]),
            permissionMode: permissionMode(for: request),
            workingDirectory: launchContext?.workingDirectory,
            homeDirectory: launchContext?.homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        ) else {
            return .noDecision
        }

        let interactionId = request.interactionId
        if let policyDecision = await policyDecision(operation: operation, interactionId: interactionId, request: request) {
            return response(for: policyDecision)
        }
        let approvalIdentityInput = approvalIdentityInput(operation: operation, request: request)
        let approval = AgentApprovalRequest(
            id: interactionId,
            providerId: ClaudeProviderAdapter.providerId,
            conversationId: request.conversationId,
            providerSessionId: request.sessionId,
            operation: operation,
            reason: "Claude requested tool approval.",
            input: request.toolInput ?? request.payload,
            approvalIdentityInput: approvalIdentityInput,
            permissionMode: permissionMode(for: request)
        )
        await interactionStore.save(AgentInteractionRecord(
            id: interactionId,
            conversationId: request.conversationId,
            kind: .approval,
            approvalRequest: approval
        ))
        let decision = await liveDecision(
            for: request.withApprovalIdentityToolInput(approvalIdentityInput),
            interactionId: interactionId
        )
        await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .approved, deniedOutcome: .denied)
        return response(for: decision)
    }

    private func handleCompact(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        guard let token = request.bearerToken,
              await tokenStore.validate(token),
              let processToken = request.processToken,
              compactHookTokensByProcess[processToken] == token else {
            return .continueProcessing
        }
        let events = await compactionTracker.hookEvents(
            hookName: request.hookName,
            conversationId: request.conversationId,
            processToken: processToken,
            payload: request.payload
        )
        for event in events {
            if let continuation = compactHookContinuations[processToken] {
                continuation.yield(event)
            } else {
                pendingCompactHookEvents[processToken, default: []].append(event)
            }
        }
        return .continueProcessing
    }

    private func handlePrompt(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        rememberPermissionMode(from: request)
        let interactionId = request.interactionId
        let prompt = request.promptText ?? "Claude asked a question."
        await interactionStore.save(AgentInteractionRecord(
            id: interactionId,
            conversationId: request.conversationId,
            kind: .prompt,
            promptRequest: AgentPromptRequest(
                id: interactionId,
                conversationId: request.conversationId,
                providerSessionId: request.sessionId,
                prompt: prompt,
                options: request.promptOptions,
                allowsCustomResponse: request.allowsCustomPromptResponse
            )
        ))
        if let policyDecision = await transientDecision(operation: "AskUserQuestion", interactionId: interactionId, request: request) {
            await resolveInteractionIfNeeded(policyDecision, interactionId: interactionId, approvedOutcome: .answered, deniedOutcome: .cancelled)
            return response(for: policyDecision, interactionId: interactionId)
        }
        let decision = await liveDecision(for: request, interactionId: interactionId)
        await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .answered, deniedOutcome: .cancelled)
        return response(for: decision, interactionId: interactionId)
    }

    private func handlePlanModeExit(_ request: ClaudeHookRequest) async -> AgentHookResponse {
        rememberPermissionMode(from: request)
        guard ClaudeHookPolicy.shouldDefer(toolName: "ExitPlanMode", permissionMode: permissionMode(for: request)) else {
            return .noDecision
        }
        let interactionId = request.interactionId
        if let policyDecision = await policyDecision(operation: "ExitPlanMode", interactionId: interactionId, request: request) {
            return response(for: policyDecision)
        }
        let approval = AgentApprovalRequest(
            id: interactionId,
            providerId: ClaudeProviderAdapter.providerId,
            conversationId: request.conversationId,
            providerSessionId: request.sessionId,
            operation: "ExitPlanMode",
            reason: "Claude requested to exit planning mode.",
            input: request.toolInput ?? request.payload,
            permissionMode: permissionMode(for: request)
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

    private static func isCompactHook(_ hookName: String) -> Bool {
        hookName == "PreCompact" || hookName == "PostCompact"
    }

    private func policyDecision(
        operation: String,
        interactionId: AgentInteractionID,
        request: ClaudeHookRequest
    ) async -> ClaudeHookDecision? {
        // Transient approvals are keyed by Claude's provider session plus tool_use_id so a retried hook can resolve the same record.
        if let decision = await transientDecision(operation: operation, interactionId: interactionId, request: request) {
            await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .approved, deniedOutcome: .denied)
            return decision
        }
        if let sessionId = request.sessionId {
            let approvalRequest = AgentSessionApprovalRequest(
                providerId: ClaudeProviderAdapter.providerId,
                conversationId: request.conversationId,
                sessionId: sessionId,
                toolName: operation,
                toolInput: request.toolInput ?? .object([:]),
                approvalIdentityToolInput: approvalIdentityInput(operation: operation, request: request)
            )
            if await approvalPolicyStore.allowsSessionApproval(approvalRequest) {
                let decision = ClaudeHookDecision.allow(updatedInput: request.updatedInputForAllowedOperation(operation))
                await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .approved, deniedOutcome: .denied)
                return decision
            }
        }
        if await approvalPolicyStore.isSessionApproved(operation: operation, input: request.toolInput ?? .object([:])) {
            let decision = ClaudeHookDecision.allow(updatedInput: request.updatedInputForAllowedOperation(operation))
            await resolveInteractionIfNeeded(decision, interactionId: interactionId, approvedOutcome: .approved, deniedOutcome: .denied)
            return decision
        }
        return nil
    }

    private func approvalIdentityInput(operation: String, request: ClaudeHookRequest) -> JSONValue? {
        commandApprovalNormalizationPolicy.normalizedApprovalIdentityToolInput(
            toolName: operation,
            toolInput: request.toolInput ?? .object([:])
        )
    }

    private func transientDecision(
        operation: String,
        interactionId: AgentInteractionID,
        request: ClaudeHookRequest
    ) async -> ClaudeHookDecision? {
        let decision: ClaudeHookDecision?
        if let transientDecisionStore = approvalPolicyStore as? any ClaudeTransientDecisionStoring {
            decision = await transientDecisionStore.consumeTransientDecision(for: ClaudeTransientDecisionKey(
                sessionId: request.sessionId,
                interactionId: interactionId
            ))
        } else if await approvalPolicyStore.consumeTransientApproval(id: interactionId) {
            decision = .allow()
        } else {
            decision = nil
        }
        guard let decision else {
            return nil
        }
        guard decision.approval == .allow,
              decision.updatedInput == nil,
              let updatedInput = request.updatedInputForAllowedOperation(operation) else {
            return decision
        }
        return .allow(reason: decision.reason, updatedInput: updatedInput)
    }

    private func rememberPermissionMode(from request: ClaudeHookRequest) {
        if let permissionMode = request.permissionMode {
            permissionModes[request.conversationId] = permissionMode
        }
    }

    private func permissionMode(for request: ClaudeHookRequest) -> String? {
        request.permissionMode ?? permissionModes[request.conversationId]
    }

    private func launchContext(for request: ClaudeHookRequest) -> ClaudeHookLaunchContext? {
        guard let processToken = request.processToken,
              compactHookTokensByProcess[processToken] == request.bearerToken else {
            return nil
        }
        return launchContextsByProcess[processToken]
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

}

private struct ClaudeHookLaunchContext {
    let workingDirectory: URL
    let homeDirectory: URL
}

private extension ClaudeHookServer {
    func response(for decision: ClaudeHookDecision, interactionId: AgentInteractionID? = nil) -> AgentHookResponse {
        switch decision.approval {
        case .allow:
            AgentHookResponse(statusCode: 200, body: decisionBody(decision, permissionDecision: "allow", interactionId: interactionId))
        case .deny:
            AgentHookResponse(statusCode: 200, body: decisionBody(decision, permissionDecision: "deny", interactionId: interactionId))
        case .deferDecision:
            AgentHookResponse(statusCode: 200, body: decisionBody(decision, permissionDecision: "defer", interactionId: interactionId))
        }
    }

    func decisionBody(
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

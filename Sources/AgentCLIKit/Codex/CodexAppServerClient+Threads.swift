import Foundation

extension CodexAppServerClient {
    func bootstrapThread(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?,
        hostToolEndpoint: AgentHostToolEndpoint? = nil,
        processToken: UUID? = nil
    ) async throws -> CodexThreadBootstrap {
        let workspaceRoots = runtimeWorkspaceRoots(spawnConfig)
        try await validateRuntimeWorkspaceRootsIfNeeded(workspaceRoots)
        let supportsFastMode = try await speedModeSupportForSettings(spawnConfig: spawnConfig)
        let forkSourceSessionId = resolvedForkSourceSessionId(
            spawnConfig: spawnConfig, resumedSession: resumedSession, hostToolEndpoint: hostToolEndpoint
        )
        let shouldHydrateExistingGoal = resumedSession != nil || forkSourceSessionId != nil
        let supportsGoalMode = try await goalModeSupportForSettings(
            spawnConfig: spawnConfig,
            shouldHydrateExistingGoal: shouldHydrateExistingGoal
        )
        let transport = try await initializedTransport()
        let sensitiveValues = hostToolEndpoint.map { [$0.bearerToken] } ?? []
        if let processToken, !sensitiveValues.isEmpty {
            await transport.registerSensitiveValues(sensitiveValues, processToken: processToken)
        }
        let request = Self.threadRequest(resumedSession: resumedSession, forkSourceSessionId: forkSourceSessionId)
        let params = threadParams(
            spawnConfig: spawnConfig,
            resumedSession: resumedSession,
            forkSourceSessionId: forkSourceSessionId,
            supportsFastMode: supportsFastMode,
            hostToolEndpoint: hostToolEndpoint
        )
        let response = try await sendThreadRequest(
            transport: transport,
            method: request.method,
            params: params,
            usesWorkspaceRoots: workspaceRoots != nil,
            sensitiveValues: sensitiveValues
        )
        guard let threadId = response.threadResponseId else {
            throw CodexAppServerError.missingThreadID(method: request.method)
        }
        let providerThreadId = AgentSessionID(rawValue: threadId)
        let goal = try await bootstrapGoalRedacting(
            threadId: providerThreadId,
            spawnConfig: spawnConfig,
            supportsGoalMode: supportsGoalMode,
            shouldHydrateExistingGoal: shouldHydrateExistingGoal,
            sensitiveValues: sensitiveValues
        )
        return CodexThreadBootstrap(
            threadId: providerThreadId,
            name: response.threadResponseName,
            preview: response.threadResponsePreview,
            forkedFromId: response.threadResponseForkedFromId.map(AgentSessionID.init(rawValue:)),
            continuity: request.continuity,
            goal: goal
        )
    }

    private func resolvedForkSourceSessionId(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?,
        hostToolEndpoint: AgentHostToolEndpoint?
    ) -> AgentSessionID? {
        if let explicitSource = spawnConfig.sessionFork?.sourceSessionId {
            return explicitSource
        }
        if spawnConfig.forkSession {
            return resumedSession?.providerSessionId
        }
        // Codex ignores thread/resume config overrides while its shared App Server still has the thread loaded. Host-tool
        // endpoints are process-scoped, so preserve the conversation by forking when a resumed runtime needs a fresh route.
        return hostToolEndpoint == nil ? nil : resumedSession?.providerSessionId
    }

    func archiveThread(_ threadId: AgentSessionID) async throws {
        let transport = try await initializedTransport()
        _ = try await transport.sendRequest(
            method: "thread/archive",
            params: threadActionParams(threadId)
        )
    }

    func unarchiveThread(_ threadId: AgentSessionID) async throws {
        let transport = try await initializedTransport()
        _ = try await transport.sendRequest(
            method: "thread/unarchive",
            params: threadActionParams(threadId)
        )
    }

    func deleteThread(_ threadId: AgentSessionID) async throws {
        let transport = try await initializedTransport()
        _ = try await transport.sendRequest(
            method: "thread/delete",
            params: threadActionParams(threadId)
        )
    }

    func setThreadGoal(_ threadId: AgentSessionID, objective: String) async throws -> AgentGoalSnapshot? {
        let transport = try await initializedTransport()
        let response = try await transport.sendRequest(
            method: "thread/goal/set",
            params: .object([
                "threadId": .string(threadId.rawValue),
                "objective": .string(objective)
            ])
        )
        return codexGoalSnapshot(from: response)
    }

    func updateThreadGoalStatus(_ threadId: AgentSessionID, status: String) async throws -> AgentGoalSnapshot? {
        let transport = try await initializedTransport()
        let response = try await transport.sendRequest(
            method: "thread/goal/set",
            params: .object([
                "threadId": .string(threadId.rawValue),
                "status": .string(status)
            ])
        )
        return codexGoalSnapshot(from: response)
    }

    func getThreadGoal(_ threadId: AgentSessionID) async throws -> AgentGoalSnapshot? {
        let transport = try await initializedTransport()
        let response = try await transport.sendRequest(
            method: "thread/goal/get",
            params: threadActionParams(threadId)
        )
        return codexGoalSnapshot(from: response)
    }

    func clearThreadGoal(_ threadId: AgentSessionID) async throws -> Bool {
        let transport = try await initializedTransport()
        let response = try await transport.sendRequest(
            method: "thread/goal/clear",
            params: threadActionParams(threadId)
        )
        guard case let .object(object) = response,
              case let .bool(cleared)? = object["cleared"] else {
            return false
        }
        return cleared
    }

    func startGoal(_ objective: String, context: AgentProviderGoalStartContext) async throws {
        guard await configuration.featureSupportChecker.supportsGoalMode(configuration: configuration, availability: nil) else {
            throw AgentCLIError.unsupportedCapability(providerId: CodexProviderAdapter.providerId, capability: "goal mode")
        }
        guard let binding = bindingsByConversation[context.conversationId],
              binding.processToken == context.processToken else {
            throw AgentCLIError.goalUnavailable(providerId: CodexProviderAdapter.providerId, reason: "Codex App Server thread is unavailable.")
        }
        guard let snapshot = try await setThreadGoal(binding.threadId, objective: objective) else {
            throw AgentCLIError.goalUnavailable(providerId: CodexProviderAdapter.providerId, reason: "Codex did not return an active goal.")
        }
        yieldGoal(snapshot, conversationId: context.conversationId)
    }

    func performGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws {
        guard await configuration.featureSupportChecker.supportsGoalMode(configuration: configuration, availability: nil) else {
            throw AgentCLIError.unsupportedCapability(providerId: CodexProviderAdapter.providerId, capability: "goal mode")
        }
        guard let binding = bindingsByConversation[context.conversationId],
              binding.processToken == context.processToken else {
            throw AgentCLIError.goalUnavailable(providerId: CodexProviderAdapter.providerId, reason: "Codex App Server thread is unavailable.")
        }
        switch action {
        case .pause:
            guard let snapshot = try await updateThreadGoalStatus(binding.threadId, status: "paused") else {
                throw AgentCLIError.goalUnavailable(providerId: CodexProviderAdapter.providerId, reason: "Codex did not return a paused goal.")
            }
            yieldGoal(snapshot, conversationId: context.conversationId)
        case .resume:
            guard let snapshot = try await updateThreadGoalStatus(binding.threadId, status: "active") else {
                throw AgentCLIError.goalUnavailable(providerId: CodexProviderAdapter.providerId, reason: "Codex did not return an active goal.")
            }
            yieldGoal(snapshot, conversationId: context.conversationId)
        case .delete:
            let cleared = try await clearThreadGoal(binding.threadId)
            guard cleared else {
                throw AgentCLIError.goalUnavailable(providerId: CodexProviderAdapter.providerId, reason: "Codex reported no goal to clear.")
            }
            bindingsByConversation[context.conversationId]?.continuation?.yield(
                AgentProviderRuntimeEvent(event: .goal(.cleared(objective: context.goal?.objective)))
            )
        }
    }

    private func threadParams(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?,
        forkSourceSessionId: AgentSessionID?,
        supportsFastMode: Bool,
        hostToolEndpoint: AgentHostToolEndpoint?
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(spawnConfig.workingDirectory.path)
        ]
        if let forkSourceSessionId {
            params["threadId"] = .string(forkSourceSessionId.rawValue)
            params["ephemeral"] = .bool(false)
        } else if let resumedSession {
            params["threadId"] = .string(resumedSession.providerSessionId.rawValue)
        } else {
            params["ephemeral"] = .bool(false)
        }
        if let model = spawnConfig.model {
            params["model"] = .string(model)
        }
        if let permissionMode = spawnConfig.permissionMode {
            params["approvalPolicy"] = .string(permissionMode)
        }
        if let workspaceRoots = runtimeWorkspaceRoots(spawnConfig) {
            params["runtimeWorkspaceRoots"] = .array(workspaceRoots.map(JSONValue.string))
        }
        if hostToolEndpoint != nil,
           let instructions = spawnConfig.hostToolServer.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            params["developerInstructions"] = .string(instructions)
        }
        if let config = threadConfig(
            spawnConfig: spawnConfig,
            supportsFastMode: supportsFastMode,
            hostToolEndpoint: hostToolEndpoint
        ) {
            params["config"] = config
        }
        return .object(params)
    }

    private func threadConfig(
        spawnConfig: AgentSpawnConfig,
        supportsFastMode: Bool,
        hostToolEndpoint: AgentHostToolEndpoint?
    ) -> JSONValue? {
        var config: [String: JSONValue] = [:]
        if let effort = spawnConfig.effort {
            config["model_reasoning_effort"] = .string(effort)
        }
        if let reasoningSummaryMode = spawnConfig.reasoningSummaryMode {
            config["model_reasoning_summary"] = .string(reasoningSummaryMode.rawValue)
        }
        mergeSpeedModeConfig(spawnConfig: spawnConfig, supportsFastMode: supportsFastMode, into: &config)
        if let hostToolEndpoint {
            let toolApprovals = Dictionary(uniqueKeysWithValues: hostToolEndpoint.enabledToolNames.map {
                ($0, JSONValue.object(["approval_mode": .string("approve")]))
            })
            config["mcp_servers.\(hostToolEndpoint.serverName)"] = .object([
                "url": .string(hostToolEndpoint.url.absoluteString),
                "http_headers": .object([
                    "Authorization": .string("Bearer \(hostToolEndpoint.bearerToken)")
                ]),
                "enabled": .bool(true),
                "required": .bool(false),
                "enabled_tools": .array(hostToolEndpoint.enabledToolNames.map(JSONValue.string)),
                "tools": .object(toolApprovals)
            ])
        }
        return config.isEmpty ? nil : .object(config)
    }

    private func runtimeWorkspaceRoots(_ spawnConfig: AgentSpawnConfig) -> [String]? {
        guard !spawnConfig.additionalWorkspaceRoots.isEmpty else {
            return nil
        }
        let workingDirectory = AgentPathHelpers.canonicalFileURL(spawnConfig.workingDirectory)
        let additional = spawnConfig.additionalWorkspaceRoots.filter {
            !AgentPathHelpers.isSameCanonicalPath($0, workingDirectory)
        }
        return [workingDirectory.path] + additional.map(\.path)
    }

    private func validateRuntimeWorkspaceRootsIfNeeded(_ workspaceRoots: [String]?) async throws {
        guard workspaceRoots != nil else {
            return
        }
        guard configuration.experimentalAPIEnabled,
              await configuration.featureSupportChecker.supportsRuntimeWorkspaceRoots(
                  configuration: configuration,
                  availability: nil
              ) else {
            throw Self.unsupportedWorkspaceRootsError()
        }
    }

    private func sendThreadRequest(
        transport: any CodexAppServerTransport,
        method: String,
        params: JSONValue,
        usesWorkspaceRoots: Bool,
        sensitiveValues: [String]
    ) async throws -> JSONValue {
        do {
            return try await transport.sendRequest(method: method, params: params)
        } catch let error as CodexAppServerError {
            if usesWorkspaceRoots, Self.isUnsupportedWorkspaceRootError(error) {
                throw Self.unsupportedWorkspaceRootsError()
            }
            throw error.redacting(sensitiveValues: sensitiveValues)
        }
    }

    private func bootstrapGoalRedacting(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        supportsGoalMode: Bool,
        shouldHydrateExistingGoal: Bool,
        sensitiveValues: [String]
    ) async throws -> AgentGoalSnapshot? {
        do {
            return try await bootstrapGoal(
                threadId: threadId,
                spawnConfig: spawnConfig,
                supportsGoalMode: supportsGoalMode,
                shouldHydrateExistingGoal: shouldHydrateExistingGoal
            )
        } catch let error as CodexAppServerError {
            throw error.redacting(sensitiveValues: sensitiveValues)
        }
    }

    private static func threadRequest(
        resumedSession: AgentSessionRecord?,
        forkSourceSessionId: AgentSessionID?
    ) -> (method: String, continuity: AgentSessionContinuity) {
        if forkSourceSessionId != nil {
            return ("thread/fork", .forked)
        }
        if resumedSession == nil {
            return ("thread/start", .fresh)
        }
        return ("thread/resume", .resumed)
    }

    private static func isUnsupportedWorkspaceRootError(_ error: CodexAppServerError) -> Bool {
        guard case let .jsonRPCError(_, _, message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("runtimeWorkspaceRoots")
    }

    private static func unsupportedWorkspaceRootsError() -> AgentCLIError {
        AgentCLIError.unsupportedCapability(
            providerId: CodexProviderAdapter.providerId,
            capability: "runtime workspace roots (requires Codex 0.144.0 or newer with experimental APIs enabled)"
        )
    }

    private func threadActionParams(_ threadId: AgentSessionID) -> JSONValue {
        .object(["threadId": .string(threadId.rawValue)])
    }

    private func bootstrapGoal(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        supportsGoalMode: Bool,
        shouldHydrateExistingGoal: Bool
    ) async throws -> AgentGoalSnapshot? {
        if let initialGoal = spawnConfig.initialGoal?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initialGoal.isEmpty {
            guard supportsGoalMode else {
                throw AgentCLIError.unsupportedCapability(providerId: CodexProviderAdapter.providerId, capability: "goal mode")
            }
            return try await setThreadGoal(threadId, objective: initialGoal)
        }
        guard supportsGoalMode, shouldHydrateExistingGoal else {
            return nil
        }
        return try await getThreadGoal(threadId)
    }

    private func yieldGoal(_ snapshot: AgentGoalSnapshot, conversationId: AgentConversationID) {
        bindingsByConversation[conversationId]?.continuation?.yield(
            AgentProviderRuntimeEvent(event: .goal(AgentGoalEvent(snapshot: snapshot)))
        )
    }
}

func codexGoalSnapshot(from response: JSONValue) -> AgentGoalSnapshot? {
    guard case let .object(responseObject) = response,
          case let .object(goal)? = responseObject["goal"] else {
        return nil
    }
    return codexGoalSnapshot(fromGoalObject: goal)
}

func codexGoalSnapshot(fromGoalObject goal: [String: JSONValue]) -> AgentGoalSnapshot? {
    guard case let .string(objective)? = goal["objective"],
          !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    let providerStatus = goal.stringValue("status") ?? "active"
    let status = AgentGoalStatus(codexStatus: providerStatus)
    let metadata = codexGoalMetadata(goal: goal, providerStatus: providerStatus)
    return AgentGoalSnapshot(
        objective: objective,
        status: status,
        availableActions: codexGoalActions(for: status),
        elapsedSeconds: goal.intValue("timeUsedSeconds", "time_used_seconds", "elapsedSeconds", "elapsed_seconds"),
        turnCount: goal.intValue("turnCount", "turn_count"),
        tokenCount: goal.intValue("tokensUsed", "tokens_used", "tokenCount", "token_count"),
        statusReason: goal.stringValue("reason", "statusReason", "status_reason"),
        metadata: metadata
    )
}

private func codexGoalMetadata(goal: [String: JSONValue], providerStatus: String) -> [String: JSONValue] {
    var metadata: [String: JSONValue] = [
        "codex_goal_status": .string(providerStatus),
        "codex_goal": .object(goal)
    ]
    if let threadId = goal.stringValue("threadId", "thread_id") {
        metadata["codex_thread_id"] = .string(threadId)
    }
    if let tokenBudget = goal.intValue("tokenBudget", "token_budget") {
        metadata["token_budget"] = .number(Double(tokenBudget))
    }
    return metadata
}

private func codexGoalActions(for status: AgentGoalStatus) -> [AgentGoalAction] {
    switch status {
    case .active:
        [.pause, .delete]
    case .paused:
        [.resume, .delete]
    case .achieved, .blocked, .usageLimited, .cleared:
        []
    }
}

private extension AgentGoalStatus {
    init(codexStatus: String) {
        switch codexStatus {
        case "active", "inProgress", "in_progress":
            self = .active
        case "paused":
            self = .paused
        case "complete", "completed", "achieved", "success", "succeeded":
            self = .achieved
        case "blocked", "failed":
            self = .blocked
        case "usageLimited", "usage_limited", "budgetLimited", "budget_limited", "limitReached", "limit_reached":
            self = .usageLimited
        case "cleared", "cancelled", "canceled":
            self = .cleared
        default:
            self = .active
        }
    }
}

private extension [String: JSONValue] {
    func stringValue(_ keys: String...) -> String? {
        keys.lazy.compactMap { key -> String? in
            guard case let .string(value)? = self[key], !value.isEmpty else {
                return nil
            }
            return value
        }.first
    }

    func intValue(_ keys: String...) -> Int? {
        keys.lazy.compactMap { key -> Int? in
            guard let value = self[key] else {
                return nil
            }
            switch value {
            case let .number(number):
                return Int(number)
            case let .string(string):
                return Int(string)
            default:
                return nil
            }
        }.first
    }
}

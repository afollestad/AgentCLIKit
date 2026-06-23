import Foundation

extension CodexAppServerClient {
    func bootstrapThread(spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?) async throws -> CodexThreadBootstrap {
        let supportsFastMode = try await speedModeSupportForSettings(spawnConfig: spawnConfig)
        let legacyForkSourceSessionId = spawnConfig.forkSession ? resumedSession?.providerSessionId : nil
        let forkSourceSessionId = spawnConfig.sessionFork?.sourceSessionId ?? legacyForkSourceSessionId
        let shouldHydrateExistingGoal = resumedSession != nil || forkSourceSessionId != nil
        let supportsGoalMode = try await goalModeSupportForSettings(
            spawnConfig: spawnConfig,
            shouldHydrateExistingGoal: shouldHydrateExistingGoal
        )
        let transport = try await initializedTransport()
        let method: String
        let continuity: AgentSessionContinuity
        if forkSourceSessionId != nil {
            method = "thread/fork"
            continuity = .forked
        } else if resumedSession == nil {
            method = "thread/start"
            continuity = .fresh
        } else {
            method = "thread/resume"
            continuity = .resumed
        }
        let response = try await transport.sendRequest(
            method: method,
            params: threadParams(
                spawnConfig: spawnConfig,
                resumedSession: resumedSession,
                forkSourceSessionId: forkSourceSessionId,
                supportsFastMode: supportsFastMode
            )
        )
        guard let threadId = response.threadResponseId else {
            throw CodexAppServerError.missingThreadID(method: method)
        }
        let providerThreadId = AgentSessionID(rawValue: threadId)
        let goal = try await bootstrapGoal(
            threadId: providerThreadId,
            spawnConfig: spawnConfig,
            supportsGoalMode: supportsGoalMode,
            shouldHydrateExistingGoal: shouldHydrateExistingGoal
        )
        return CodexThreadBootstrap(
            threadId: providerThreadId,
            name: response.threadResponseName,
            preview: response.threadResponsePreview,
            forkedFromId: response.threadResponseForkedFromId.map(AgentSessionID.init(rawValue:)),
            continuity: continuity,
            goal: goal
        )
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
        supportsFastMode: Bool
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
        if let config = threadConfig(spawnConfig: spawnConfig, supportsFastMode: supportsFastMode) {
            params["config"] = config
        }
        return .object(params)
    }

    private func threadConfig(spawnConfig: AgentSpawnConfig, supportsFastMode: Bool) -> JSONValue? {
        var config: [String: JSONValue] = [:]
        if let effort = spawnConfig.effort {
            config["model_reasoning_effort"] = .string(effort)
        }
        mergeSpeedModeConfig(spawnConfig: spawnConfig, supportsFastMode: supportsFastMode, into: &config)
        return config.isEmpty ? nil : .object(config)
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

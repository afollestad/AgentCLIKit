import Foundation

extension CodexAppServerClient {
    func bootstrapThread(spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?) async throws -> CodexThreadBootstrap {
        let supportsFastMode = try await speedModeSupportForSettings(spawnConfig: spawnConfig)
        let transport = try await initializedTransport()
        let method = resumedSession == nil ? "thread/start" : "thread/resume"
        let response = try await transport.sendRequest(
            method: method,
            params: threadParams(
                spawnConfig: spawnConfig,
                resumedSession: resumedSession,
                supportsFastMode: supportsFastMode
            )
        )
        guard let threadId = response.threadResponseId else {
            throw CodexAppServerError.missingThreadID(method: method)
        }
        return CodexThreadBootstrap(
            threadId: AgentSessionID(rawValue: threadId),
            name: response.threadResponseName,
            preview: response.threadResponsePreview,
            continuity: resumedSession == nil ? .fresh : .resumed
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

    private func threadParams(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?,
        supportsFastMode: Bool
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(spawnConfig.workingDirectory.path)
        ]
        if let resumedSession {
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
}

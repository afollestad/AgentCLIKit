import Foundation

extension CodexAppServerClient {
    func updateBootstrapThreadSettingsIfNeeded(conversationId: AgentConversationID) async throws {
        guard let binding = bindingsByConversation[conversationId],
              binding.spawnConfig.collaborationMode != nil else {
            return
        }
        // thread/start cannot carry collaboration mode, so apply it before any initial prompt turn.
        try await updateThreadSettings(threadId: binding.threadId, spawnConfig: binding.spawnConfig)
    }

    func updateThreadSettings(threadId: AgentSessionID, spawnConfig: AgentSpawnConfig) async throws {
        let supportsFastMode = try await speedModeSupportForSettings(spawnConfig: spawnConfig)
        let transport = try await initializedTransport()
        _ = try await transport.sendRequest(
            method: "thread/settings/update",
            params: try threadSettingsUpdateParams(
                threadId: threadId,
                spawnConfig: spawnConfig,
                supportsFastMode: supportsFastMode
            )
        )
    }

    func threadSettingsUpdateParams(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        supportsFastMode: Bool
    ) throws -> JSONValue {
        var params = try stickySettingsParams(spawnConfig: spawnConfig, supportsFastMode: supportsFastMode)
        params["threadId"] = .string(threadId.rawValue)
        return .object(params)
    }

    func turnStartParams(
        message: AgentMessageInput,
        binding: ConversationBinding,
        includeSettings: Bool,
        supportsFastMode: Bool
    ) throws -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(binding.threadId.rawValue),
            "input": userInputArray(message)
        ]
        if includeSettings {
            params.merge(try stickySettingsParams(
                spawnConfig: binding.spawnConfig,
                supportsFastMode: supportsFastMode
            )) { _, new in new }
        }
        return .object(params)
    }

    func stickySettingsParams(spawnConfig: AgentSpawnConfig, supportsFastMode: Bool) throws -> [String: JSONValue] {
        // Shared by turn/start and thread/settings/update so sticky Codex settings cannot drift.
        var params: [String: JSONValue] = [
            "cwd": .string(spawnConfig.workingDirectory.path)
        ]
        if let model = spawnConfig.model {
            params["model"] = .string(model)
        }
        if let permissionMode = spawnConfig.permissionMode {
            params["approvalPolicy"] = .string(permissionMode)
        }
        if let effort = spawnConfig.effort {
            params["effort"] = .string(effort)
        }
        if let collaborationMode = try collaborationModeValue(spawnConfig: spawnConfig) {
            params["collaborationMode"] = collaborationMode
        }
        if let config = stickyConfig(spawnConfig: spawnConfig, supportsFastMode: supportsFastMode) {
            params["config"] = config
        }
        return params
    }

    func speedModeSupportForSettings(spawnConfig: AgentSpawnConfig) async throws -> Bool {
        guard let speedMode = spawnConfig.speedMode else {
            return false
        }
        let supportsFastMode = await configuration.featureSupportChecker.supportsFastMode(
            configuration: configuration,
            availability: nil
        )
        if speedMode == .fast, !supportsFastMode {
            throw AgentCLIError.unsupportedCapability(
                providerId: CodexProviderAdapter.providerId,
                capability: "fast mode"
            )
        }
        return supportsFastMode
    }

    func stickyConfig(spawnConfig: AgentSpawnConfig, supportsFastMode: Bool) -> JSONValue? {
        var config: [String: JSONValue] = [:]
        mergeSpeedModeConfig(spawnConfig: spawnConfig, supportsFastMode: supportsFastMode, into: &config)
        return config.isEmpty ? nil : .object(config)
    }

    func mergeSpeedModeConfig(
        spawnConfig: AgentSpawnConfig,
        supportsFastMode: Bool,
        into config: inout [String: JSONValue]
    ) {
        guard let speedMode = spawnConfig.speedMode, supportsFastMode else {
            return
        }
        var features: [String: JSONValue] = [:]
        if case let .object(existingFeatures)? = config["features"] {
            features = existingFeatures
        }
        features["fast_mode"] = .bool(speedMode == .fast)
        config["features"] = .object(features)
    }

    func collaborationModeValue(spawnConfig: AgentSpawnConfig) throws -> JSONValue? {
        guard let collaborationMode = spawnConfig.collaborationMode else {
            return nil
        }
        guard let model = spawnConfig.model else {
            throw AgentCLIError.invalidInput("Codex collaboration mode requires a concrete model.")
        }
        var settings: [String: JSONValue] = [
            "model": .string(model),
            "developer_instructions": .null
        ]
        if let effort = spawnConfig.effort {
            settings["reasoning_effort"] = .string(effort)
        }
        return .object([
            "mode": .string(collaborationMode.rawValue),
            "settings": .object(settings)
        ])
    }

    func userInputArray(_ message: AgentMessageInput) -> JSONValue {
        .array([.object([
            "type": .string("text"),
            "text": .string(message.text),
            "text_elements": .array([])
        ])])
    }
}

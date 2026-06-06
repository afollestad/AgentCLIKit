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
        let transport = try await initializedTransport()
        _ = try await transport.sendRequest(
            method: "thread/settings/update",
            params: try threadSettingsUpdateParams(threadId: threadId, spawnConfig: spawnConfig)
        )
    }

    func threadSettingsUpdateParams(threadId: AgentSessionID, spawnConfig: AgentSpawnConfig) throws -> JSONValue {
        var params = try stickySettingsParams(spawnConfig: spawnConfig)
        params["threadId"] = .string(threadId.rawValue)
        return .object(params)
    }

    func turnStartParams(message: AgentMessageInput, binding: ConversationBinding, includeSettings: Bool) throws -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(binding.threadId.rawValue),
            "input": userInputArray(message)
        ]
        if includeSettings {
            params.merge(try stickySettingsParams(spawnConfig: binding.spawnConfig)) { _, new in new }
        }
        return .object(params)
    }

    func stickySettingsParams(spawnConfig: AgentSpawnConfig) throws -> [String: JSONValue] {
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
        return params
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

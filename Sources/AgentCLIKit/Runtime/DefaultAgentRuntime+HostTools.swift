import Foundation

extension DefaultAgentRuntime {
    func registerSensitiveValues(_ values: [String], processToken: UUID) {
        let values = Set(values.filter { !$0.isEmpty })
        sensitiveValuesByProcessToken[processToken] = values.isEmpty ? nil : values
    }

    func redactedProviderOutput(_ value: String, processToken: UUID) -> String {
        AgentSensitiveValueRedactor.redact(
            value,
            sensitiveValues: sensitiveValuesByProcessToken[processToken] ?? []
        )
    }

    func trackInFlightStart(
        conversationId: AgentConversationID,
        adapter: any AgentProviderAdapter,
        processToken: UUID
    ) {
        inFlightStartResources[conversationId] = InFlightStartResources(adapter: adapter, processToken: processToken)
    }

    func untrackInFlightStart(conversationId: AgentConversationID, processToken: UUID) {
        guard inFlightStartResources[conversationId]?.processToken == processToken else {
            return
        }
        inFlightStartResources.removeValue(forKey: conversationId)
    }

    func invalidateTrackedStartResources(
        conversationId: AgentConversationID,
        adapter: any AgentProviderAdapter,
        processToken: UUID
    ) async {
        guard inFlightStartResources[conversationId]?.processToken == processToken else {
            return
        }
        inFlightStartResources.removeValue(forKey: conversationId)
        await invalidateProcessResources(adapter: adapter, processToken: processToken)
    }

    func registerHostToolsIfNeeded(
        conversationId: AgentConversationID,
        config: AgentSpawnConfig,
        processToken: UUID
    ) async throws -> AgentHostToolEndpoint? {
        guard !config.hostTools.isEmpty else {
            return nil
        }
        guard let hostToolServer else {
            throw AgentCLIError.hostToolsUnavailable(reason: "No host tool handler was injected into the runtime.")
        }
        await startHostToolFailureMonitoringIfNeeded(server: hostToolServer)
        do {
            return try await hostToolServer.register(
                conversationId: conversationId,
                providerId: config.providerId,
                processToken: processToken,
                server: config.hostToolServer,
                tools: config.hostTools
            )
        } catch let error as AgentCLIError {
            if case .hostToolsUnavailable = error {
                throw error
            }
            throw AgentCLIError.hostToolsUnavailable(reason: error.localizedDescription)
        } catch {
            throw AgentCLIError.hostToolsUnavailable(reason: error.localizedDescription)
        }
    }

    private func startHostToolFailureMonitoringIfNeeded(server: any AgentHostToolServing) async {
        guard hostToolFailureTask == nil, !isShutdown else {
            return
        }
        let startTask: Task<AsyncStream<AgentHostToolServerFailure>, Never>
        if let existing = hostToolFailureMonitorStartTask {
            startTask = existing
        } else {
            startTask = Task { await server.failures() }
            hostToolFailureMonitorStartTask = startTask
        }
        let failures = await startTask.value
        guard !isShutdown else {
            hostToolFailureMonitorStartTask = nil
            return
        }
        guard hostToolFailureTask == nil else {
            return
        }
        hostToolFailureMonitorStartTask = nil
        hostToolFailureTask = Task { [weak self] in
            for await failure in failures {
                guard !Task.isCancelled else {
                    break
                }
                await self?.handleHostToolServerFailure(failure)
            }
        }
    }

    private func handleHostToolServerFailure(_ failure: AgentHostToolServerFailure) {
        guard !isShutdown else {
            return
        }
        let affectedTokens = Set(failure.processTokens)
        for (conversationId, resources) in inFlightStartResources where affectedTokens.contains(resources.processToken) {
            cancelStartForHostToolFailure(
                conversationId: conversationId,
                reason: failure.message
            )
        }
        for (conversationId, state) in states where affectedTokens.contains(state.processToken) {
            emitDiagnostic(
                code: .hostToolServerUnavailable,
                severity: .error,
                message: failure.message,
                metadata: [
                    "host_tools_unavailable": .bool(true),
                    "replacement_required": .bool(true)
                ],
                source: .runtime,
                conversationId: conversationId
            )
        }
    }

}

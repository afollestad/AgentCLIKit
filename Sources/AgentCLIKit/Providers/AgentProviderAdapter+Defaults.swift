import Foundation

/// Default implementations so an adapter only overrides the provider behavior it actually has.
public extension AgentProviderAdapter {
    /// Bridges context-aware launches to the legacy launch requirement for source compatibility.
    func makeLaunchConfiguration(context: AgentProviderLaunchContext) async throws -> AgentLaunchConfiguration {
        guard context.hostToolEndpoint == nil,
              context.spawnConfig.hostTools.isEmpty,
              context.spawnConfig.additionalWorkspaceRoots.isEmpty else {
            throw AgentCLIError.unsupportedCapability(
                providerId: definition.id,
                capability: "host tools or additional workspace roots"
            )
        }
        return try await makeLaunchConfiguration(
            spawnConfig: context.spawnConfig,
            resumedSession: context.resumedSession
        )
    }

    /// Throws by default for providers that do not support sessionless one-shot prompts.
    func makeOneShotPromptCommand(request: AgentOneShotPromptRequest) async throws -> ShellCommand {
        throw AgentOneShotPromptError.unsupportedProvider(definition.id)
    }

    /// Throws by default for providers that do not support sessionless one-shot prompts.
    func finalOneShotPromptText(
        stdout: String,
        stderr: String,
        request: AgentOneShotPromptRequest
    ) async throws -> String {
        throw AgentOneShotPromptError.unsupportedProvider(definition.id)
    }

    /// Returns the launch unchanged for providers that do not need runtime-managed launch augmentation.
    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        launch
    }

    /// Returns no session identifier for providers that do not expose resumable sessions in events.
    func sessionID(from event: AgentEvent) -> AgentSessionID? {
        nil
    }

    /// Decodes stdout using the legacy provider stdout decoder.
    func decodeStdoutLine(_ line: String, context: AgentProviderOutputContext) async throws -> [AgentEvent] {
        try await decodeStdoutLine(line)
    }

    /// Encodes input using the legacy provider stdin encoder.
    func encodeInput(_ input: AgentInput, context: AgentProviderInputContext) async throws -> Data {
        try await encodeInput(input)
    }

    /// Returns no runtime marker for providers that require provider-native steering proof.
    func acceptedSteeringInputEvent(for message: AgentMessageInput, context: AgentProviderInputContext) -> AgentEvent? {
        nil
    }

    /// Returns an immediately finished stream for providers that only emit process stdout or stderr.
    func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Performs no provider-native interruption for process-only providers.
    func interrupt(context: AgentProviderInterruptContext) async throws {}

    /// Throws for providers that do not support existing-session goal start.
    func startGoal(_ objective: String, context: AgentProviderGoalStartContext) async throws {
        throw AgentCLIError.unsupportedCapability(providerId: definition.id, capability: "existing-session goal start")
    }

    /// Returns no stdin bytes for providers that do not start existing-session goals through stdin.
    func encodeGoalStart(_ objective: String, context: AgentProviderGoalStartContext) async throws -> AgentProviderEncodedGoalStart? {
        nil
    }

    /// Returns provider-reported actions by default.
    func availableGoalActions(for goal: AgentGoalSnapshot, context: AgentProviderGoalActionContext) -> [AgentGoalAction] {
        goal.availableActions
    }

    /// Throws for providers that do not support provider-native goal actions.
    func performGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws {
        throw AgentCLIError.unsupportedCapability(providerId: definition.id, capability: "goal \(action.rawValue)")
    }

    /// Returns no stdin bytes for providers that do not control goals through stdin.
    func encodeGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws -> Data? {
        nil
    }

    /// Requests the runtime's replacement-process reconfigure path for providers without in-place settings updates.
    func reconfigure(context: AgentProviderReconfigureContext) async throws -> AgentProviderReconfigureResult {
        .restartRequired
    }

    /// Validates the provider record and otherwise no-ops for providers without native archiving.
    func archiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Validates the provider record and otherwise no-ops for providers without native unarchiving.
    func unarchiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Validates the provider record and otherwise no-ops for providers without native deletion.
    func deleteSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Does nothing for providers without permission-mode-sensitive runtime resources.
    func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async {}

    /// Does nothing for providers that do not retain process-scoped resources.
    func processDidTerminate(processToken: UUID) async {}

    /// Does nothing for providers that do not retain shared runtime resources.
    func shutdownProviderResources() async {}

    /// Validates that a provider session record belongs to this provider adapter.
    func validateSessionActionRecord(_ record: AgentSessionRecord) throws {
        guard record.providerId == definition.id else {
            throw AgentCLIError.invalidInput(
                "Provider session record for '\(record.providerId.rawValue)' cannot be handled by '\(definition.id.rawValue)'."
            )
        }
    }
}

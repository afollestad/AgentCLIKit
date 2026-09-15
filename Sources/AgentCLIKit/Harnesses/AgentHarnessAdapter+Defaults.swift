import Foundation

/// Default implementations so an adapter only overrides the harness behavior it actually has.
public extension AgentHarnessAdapter {
    /// Bridges context-aware launches to the legacy launch requirement for source compatibility.
    func makeLaunchConfiguration(context: AgentHarnessLaunchContext) async throws -> AgentLaunchConfiguration {
        guard context.hostToolEndpoint == nil,
              context.spawnConfig.hostTools.isEmpty,
              context.spawnConfig.additionalWorkspaceRoots.isEmpty else {
            throw AgentCLIError.unsupportedCapability(
                harnessId: definition.id,
                capability: "host tools or additional workspace roots"
            )
        }
        return try await makeLaunchConfiguration(
            spawnConfig: context.spawnConfig,
            resumedSession: context.resumedSession
        )
    }

    /// Throws by default for harnesses that do not support sessionless one-shot prompts.
    func makeOneShotPromptCommand(request: AgentOneShotPromptRequest) async throws -> ShellCommand {
        throw AgentOneShotPromptError.unsupportedHarness(definition.id)
    }

    /// Throws by default for harnesses that do not support sessionless one-shot prompts.
    func finalOneShotPromptText(
        stdout: String,
        stderr: String,
        request: AgentOneShotPromptRequest
    ) async throws -> String {
        throw AgentOneShotPromptError.unsupportedHarness(definition.id)
    }

    /// Returns the launch unchanged for harnesses that do not need runtime-managed launch augmentation.
    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        launch
    }

    /// Returns no session identifier for harnesses that do not expose resumable sessions in events.
    func sessionID(from event: AgentEvent) -> AgentSessionID? {
        nil
    }

    /// Decodes stdout using the legacy harness stdout decoder.
    func decodeStdoutLine(_ line: String, context: AgentHarnessOutputContext) async throws -> [AgentEvent] {
        try await decodeStdoutLine(line)
    }

    /// Encodes input using the legacy harness stdin encoder.
    func encodeInput(_ input: AgentInput, context: AgentHarnessInputContext) async throws -> Data {
        try await encodeInput(input)
    }

    /// Returns no runtime marker for harnesses that require harness-native steering proof.
    func acceptedSteeringInputEvent(for message: AgentMessageInput, context: AgentHarnessInputContext) -> AgentEvent? {
        nil
    }

    /// Returns an immediately finished stream for harnesses that only emit process stdout or stderr.
    func runtimeEvents(context: AgentHarnessRuntimeContext) async -> AsyncStream<AgentHarnessRuntimeEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Performs no harness-native interruption for process-only harnesses.
    func interrupt(context: AgentHarnessInterruptContext) async throws {}

    /// Throws for harnesses that do not support existing-session goal start.
    func startGoal(_ objective: String, context: AgentHarnessGoalStartContext) async throws {
        throw AgentCLIError.unsupportedCapability(harnessId: definition.id, capability: "existing-session goal start")
    }

    /// Returns no stdin bytes for harnesses that do not start existing-session goals through stdin.
    func encodeGoalStart(_ objective: String, context: AgentHarnessGoalStartContext) async throws -> AgentHarnessEncodedGoalStart? {
        nil
    }

    /// Returns harness-reported actions by default.
    func availableGoalActions(for goal: AgentGoalSnapshot, context: AgentHarnessGoalActionContext) -> [AgentGoalAction] {
        goal.availableActions
    }

    /// Throws for harnesses that do not support harness-native goal actions.
    func performGoalAction(_ action: AgentGoalAction, context: AgentHarnessGoalActionContext) async throws {
        throw AgentCLIError.unsupportedCapability(harnessId: definition.id, capability: "goal \(action.rawValue)")
    }

    /// Returns no stdin bytes for harnesses that do not control goals through stdin.
    func encodeGoalAction(_ action: AgentGoalAction, context: AgentHarnessGoalActionContext) async throws -> Data? {
        nil
    }

    /// Requests the runtime's replacement-process reconfigure path for harnesses without in-place settings updates.
    func reconfigure(context: AgentHarnessReconfigureContext) async throws -> AgentHarnessReconfigureResult {
        .restartRequired
    }

    /// Validates the harness record and otherwise no-ops for harnesses without native archiving.
    func archiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Validates the harness record and otherwise no-ops for harnesses without native unarchiving.
    func unarchiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Validates the harness record and otherwise no-ops for harnesses without native deletion.
    func deleteSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Does nothing for harnesses without permission-mode-sensitive runtime resources.
    func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async {}

    /// Does nothing for harnesses that do not retain process-scoped resources.
    func processDidTerminate(processToken: UUID) async {}

    /// Does nothing for harnesses that do not retain shared runtime resources.
    func shutdownHarnessResources() async {}

    /// Validates that a harness session record belongs to this harness adapter.
    func validateSessionActionRecord(_ record: AgentSessionRecord) throws {
        guard record.harnessId == definition.id else {
            throw AgentCLIError.invalidInput(
                "Harness session record for '\(record.harnessId.rawValue)' cannot be handled by '\(definition.id.rawValue)'."
            )
        }
    }
}

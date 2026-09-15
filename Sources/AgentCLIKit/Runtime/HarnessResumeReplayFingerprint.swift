// Deferred approval resumes can replay harness frames with fresh bookkeeping metadata.
// Fingerprints keep the replay gate strict on transcript-visible content while ignoring volatile fields.
enum HarnessResumeReplayFingerprint: Equatable {
    case message(role: AgentMessageRole, text: String, metadata: [HarnessResumeMetadataEntry])
    case messageDelta(role: AgentMessageRole, text: String, metadata: [HarnessResumeMetadataEntry])
    case reasoning(text: String, metadata: [HarnessResumeMetadataEntry])
    case toolCall(id: String, name: String, input: JSONValue, metadata: [HarnessResumeMetadataEntry])
    case toolResult(id: String, isError: Bool, content: String, metadata: [HarnessResumeMetadataEntry])
    case usage(HarnessResumeUsageFingerprint)
    case rateLimit(HarnessResumeRateLimitFingerprint)
    case permissionMode(String)
    case collaborationMode(AgentCollaborationMode)
    case task(HarnessResumeTaskFingerprint)
    case subAgent(HarnessResumeSubAgentFingerprint)
    case contextCompaction(HarnessResumeCompactionFingerprint)
    case goal(AgentGoalEvent)
    case interaction(kind: AgentInteractionKind, prompt: String, metadata: [HarnessResumeMetadataEntry])
    case rawOutput(text: String, isComplete: Bool)

    func matchesReplay(of replayed: HarnessResumeReplayFingerprint) -> Bool {
        if self == replayed {
            return true
        }
        // Claude may assign fresh tool_use_id values while replaying the same
        // visible tool transcript after a deferred approval resume.
        switch (self, replayed) {
        case let (
            .toolCall(_, retainedName, retainedInput, retainedMetadata),
            .toolCall(_, replayedName, replayedInput, replayedMetadata)
        ):
            return retainedName == replayedName &&
                retainedInput == replayedInput &&
                retainedMetadata == replayedMetadata
        case let (
            .toolResult(_, retainedIsError, retainedContent, retainedMetadata),
            .toolResult(_, replayedIsError, replayedContent, replayedMetadata)
        ):
            return retainedIsError == replayedIsError &&
                retainedContent == replayedContent &&
                retainedMetadata == replayedMetadata
        default:
            return false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    init?(_ event: AgentEvent) {
        switch event {
        case .message(let message):
            self = .message(
                role: message.role,
                text: message.text,
                metadata: metadataFingerprint(message.metadata, keys: ["parent_tool_use_id"])
            )
        case .messageDelta(let delta):
            self = .messageDelta(
                role: delta.role,
                text: delta.text,
                metadata: metadataFingerprint(delta.metadata, keys: ["parent_tool_use_id"])
            )
        case .reasoning(let reasoning):
            self = .reasoning(
                text: reasoning.text,
                metadata: metadataFingerprint(reasoning.metadata, keys: ["parent_tool_use_id"])
            )
        case .toolCall(let toolCall):
            self = .toolCall(
                id: toolCall.id,
                name: toolCall.name,
                input: toolCall.input,
                metadata: metadataFingerprint(toolCall.metadata, keys: ["parent_tool_use_id", "caller_agent"])
            )
        case .toolResult(let toolResult):
            self = .toolResult(
                id: toolResult.id,
                isError: toolResult.isError,
                content: toolResult.content,
                metadata: metadataFingerprint(
                    toolResult.metadata,
                    keys: ["parent_tool_use_id", "stderr", "interrupted", "is_image", "no_output_expected"]
                )
            )
        case .usage(let usage):
            self = .usage(HarnessResumeUsageFingerprint(usage))
        case .rateLimit(let rateLimit):
            self = .rateLimit(HarnessResumeRateLimitFingerprint(rateLimit))
        case .permissionMode(let permissionMode):
            self = .permissionMode(permissionMode.mode)
        case .collaborationMode(let collaborationMode):
            self = .collaborationMode(collaborationMode.mode)
        case .task(let task):
            self = .task(HarnessResumeTaskFingerprint(task))
        case .subAgent(let subAgent):
            self = .subAgent(HarnessResumeSubAgentFingerprint(subAgent))
        case .contextCompaction(let compaction):
            self = .contextCompaction(HarnessResumeCompactionFingerprint(compaction))
        case .goal(let goal):
            self = .goal(goal)
        case .interaction(let interaction):
            self = .interaction(
                kind: interaction.kind,
                prompt: interaction.prompt,
                metadata: metadataFingerprint(
                    interaction.metadata,
                    keys: ["session_id", "sessionId", "tool_name", "toolName", "tool_input", "toolInput", "plan"]
                )
            )
        case .rawOutput(let rawOutput):
            self = .rawOutput(text: rawOutput.text, isComplete: rawOutput.isComplete)
        case .activity, .backgroundTasks, .sessionMetadata, .sessionContinuity, .lifecycle, .diagnostic:
            return nil
        }
    }
}

struct HarnessResumeCompactionFingerprint: Equatable {
    let id: String
    let phase: AgentContextCompactionPhase
    let trigger: String?
    let summary: String?
    let errorMessage: String?
    let preTokens: Int?
    let postTokens: Int?
    let durationMs: Int?

    init(_ compaction: AgentContextCompactionEvent) {
        id = compaction.id
        phase = compaction.phase
        trigger = compaction.trigger
        summary = compaction.summary
        errorMessage = compaction.errorMessage
        preTokens = compaction.preTokens
        postTokens = compaction.postTokens
        durationMs = compaction.durationMs
    }
}

struct HarnessResumeUsageFingerprint: Equatable {
    let model: String?
    let stopReason: String?
    let isTerminal: Bool
    let isError: Bool
    let permissionDenials: [HarnessResumeDenialFingerprint]

    init(_ usage: AgentUsageEvent) {
        model = usage.model
        stopReason = usage.stopReason ?? usage.metadata.stringValue("stop_reason")
        isTerminal = usage.isTerminal
        isError = usage.isError
        permissionDenials = usage.permissionDenials.map(HarnessResumeDenialFingerprint.init)
    }
}

struct HarnessResumeDenialFingerprint: Equatable {
    let toolUseId: String?
    let toolName: String?
    let reason: String?

    init(_ denial: AgentPermissionDenialSummary) {
        toolUseId = denial.toolUseId
        toolName = denial.toolName
        reason = denial.reason
    }
}

struct HarnessResumeRateLimitFingerprint: Equatable {
    let status: AgentRateLimitStatus
    let limitType: String?
    let overageStatus: AgentRateLimitStatus?
    let overageDisabledReason: String?

    init(_ rateLimit: AgentRateLimitEvent) {
        status = rateLimit.status
        limitType = rateLimit.limitType
        overageStatus = rateLimit.overageStatus
        overageDisabledReason = rateLimit.overageDisabledReason
    }
}

struct HarnessResumeTaskFingerprint: Equatable {
    let id: String
    let phase: AgentTaskPhase
    let description: String?
    let taskType: String?
    let lastToolName: String?
    let status: String?

    init(_ task: AgentTaskEvent) {
        id = task.id
        phase = task.phase
        description = task.description
        taskType = task.taskType
        lastToolName = task.lastToolName
        status = task.status
    }
}

struct HarnessResumeSubAgentFingerprint: Equatable {
    let id: String
    let phase: AgentSubAgentPhase
    let description: String?
    let prompt: String?
    let agentType: String?
    let lastToolName: String?
    let status: String?
    let result: String?
    let parentToolUseId: String?
    let callerAgent: String?
    let parentSessionId: String?
    let childSessionIds: [String]

    init(_ subAgent: AgentSubAgentEvent) {
        id = subAgent.id
        phase = subAgent.phase
        description = subAgent.description
        prompt = subAgent.prompt
        agentType = subAgent.agentType
        lastToolName = subAgent.lastToolName
        status = subAgent.status
        result = subAgent.result
        parentToolUseId = subAgent.parentToolUseId
        callerAgent = subAgent.callerAgent
        parentSessionId = subAgent.parentSessionId
        childSessionIds = subAgent.childSessionIds
    }
}

struct HarnessResumeMetadataEntry: Equatable {
    let key: String
    let value: JSONValue
}

private func metadataFingerprint(_ metadata: [String: JSONValue], keys: [String]) -> [HarnessResumeMetadataEntry] {
    keys.compactMap { key in
        metadata[key].map { HarnessResumeMetadataEntry(key: key, value: $0) }
    }
}

private extension [String: JSONValue] {
    func stringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else {
            return nil
        }
        return value
    }
}

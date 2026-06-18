// Deferred approval resumes can replay provider frames with fresh bookkeeping metadata.
// Fingerprints keep the replay gate strict on transcript-visible content while ignoring volatile fields.
enum ProviderResumeReplayFingerprint: Equatable {
    case message(role: AgentMessageRole, text: String, metadata: [ProviderResumeMetadataEntry])
    case messageDelta(role: AgentMessageRole, text: String, metadata: [ProviderResumeMetadataEntry])
    case reasoning(text: String, metadata: [ProviderResumeMetadataEntry])
    case toolCall(id: String, name: String, input: JSONValue, metadata: [ProviderResumeMetadataEntry])
    case toolResult(id: String, isError: Bool, content: String, metadata: [ProviderResumeMetadataEntry])
    case usage(ProviderResumeUsageFingerprint)
    case rateLimit(ProviderResumeRateLimitFingerprint)
    case permissionMode(String)
    case collaborationMode(AgentCollaborationMode)
    case task(ProviderResumeTaskFingerprint)
    case subAgent(ProviderResumeSubAgentFingerprint)
    case contextCompaction(ProviderResumeCompactionFingerprint)
    case interaction(kind: AgentInteractionKind, prompt: String, metadata: [ProviderResumeMetadataEntry])
    case rawOutput(text: String, isComplete: Bool)

    func matchesReplay(of replayed: ProviderResumeReplayFingerprint) -> Bool {
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
            self = .usage(ProviderResumeUsageFingerprint(usage))
        case .rateLimit(let rateLimit):
            self = .rateLimit(ProviderResumeRateLimitFingerprint(rateLimit))
        case .permissionMode(let permissionMode):
            self = .permissionMode(permissionMode.mode)
        case .collaborationMode(let collaborationMode):
            self = .collaborationMode(collaborationMode.mode)
        case .task(let task):
            self = .task(ProviderResumeTaskFingerprint(task))
        case .subAgent(let subAgent):
            self = .subAgent(ProviderResumeSubAgentFingerprint(subAgent))
        case .contextCompaction(let compaction):
            self = .contextCompaction(ProviderResumeCompactionFingerprint(compaction))
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
        case .activity, .sessionMetadata, .sessionContinuity, .lifecycle, .diagnostic:
            return nil
        }
    }
}

struct ProviderResumeCompactionFingerprint: Equatable {
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

struct ProviderResumeUsageFingerprint: Equatable {
    let model: String?
    let stopReason: String?
    let isTerminal: Bool
    let isError: Bool
    let permissionDenials: [ProviderResumeDenialFingerprint]

    init(_ usage: AgentUsageEvent) {
        model = usage.model
        stopReason = usage.stopReason ?? usage.metadata.stringValue("stop_reason")
        isTerminal = usage.isTerminal
        isError = usage.isError
        permissionDenials = usage.permissionDenials.map(ProviderResumeDenialFingerprint.init)
    }
}

struct ProviderResumeDenialFingerprint: Equatable {
    let toolUseId: String?
    let toolName: String?
    let reason: String?

    init(_ denial: AgentPermissionDenialSummary) {
        toolUseId = denial.toolUseId
        toolName = denial.toolName
        reason = denial.reason
    }
}

struct ProviderResumeRateLimitFingerprint: Equatable {
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

struct ProviderResumeTaskFingerprint: Equatable {
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

struct ProviderResumeSubAgentFingerprint: Equatable {
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

struct ProviderResumeMetadataEntry: Equatable {
    let key: String
    let value: JSONValue
}

private func metadataFingerprint(_ metadata: [String: JSONValue], keys: [String]) -> [ProviderResumeMetadataEntry] {
    keys.compactMap { key in
        metadata[key].map { ProviderResumeMetadataEntry(key: key, value: $0) }
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

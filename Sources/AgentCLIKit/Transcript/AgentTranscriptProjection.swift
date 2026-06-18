import Foundation

/// Provider-neutral kind for projected transcript UI items.
public enum AgentTranscriptProjectionKind: String, Codable, Hashable, Sendable {
    /// User, assistant, system, or tool message text.
    case message
    /// Tool invocation.
    case toolCall
    /// Tool result.
    case toolResult
    /// Host approval request.
    case approval
    /// Host prompt request.
    case prompt
    /// Provider task or todo activity.
    case task
    /// Provider sub-agent activity.
    case subAgent
    /// Provider task-list update.
    case taskList
    /// Centered note such as lifecycle, continuity, or interruption.
    case centeredNote
    /// Diagnostic detail.
    case diagnostic
}

/// Render-ready transcript projection derived from one event envelope.
public struct AgentTranscriptProjection: Codable, Equatable, Sendable, Identifiable {
    /// Stable projection identifier.
    public let id: String
    /// Projection kind.
    public let kind: AgentTranscriptProjectionKind
    /// Source envelope index range.
    public let indexRange: ClosedRange<Int>
    /// Message role when the projection represents message text.
    public let role: AgentMessageRole?
    /// Primary display text.
    public let title: String
    /// Optional secondary display text.
    public let detail: String?
    /// Source envelopes included in this projection.
    public let envelopes: [AgentEventEnvelope]

    /// Creates a transcript projection.
    public init(
        id: String,
        kind: AgentTranscriptProjectionKind,
        indexRange: ClosedRange<Int>,
        role: AgentMessageRole? = nil,
        title: String,
        detail: String? = nil,
        envelopes: [AgentEventEnvelope]
    ) {
        self.id = id
        self.kind = kind
        self.indexRange = indexRange
        self.role = role
        self.title = title
        self.detail = detail
        self.envelopes = envelopes
    }
}

/// Builds provider-neutral transcript projections for host UIs.
public struct AgentTranscriptProjector: Sendable {
    /// Creates a transcript projector.
    public init() {}

    /// Projects ordered event envelopes into renderable items.
    public func project(_ envelopes: [AgentEventEnvelope]) -> [AgentTranscriptProjection] {
        envelopes.sorted(by: eventOrder).compactMap(project)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func project(_ envelope: AgentEventEnvelope) -> AgentTranscriptProjection? {
        switch envelope.event {
        case let .message(message):
            projection(envelope, kind: .message, role: message.role, title: message.text)
        case let .toolCall(tool):
            projection(envelope, kind: .toolCall, title: tool.name, detail: tool.id)
        case let .toolResult(result):
            projection(envelope, kind: .toolResult, title: result.isError ? "Tool failed" : "Tool finished", detail: result.content)
        case let .interaction(interaction):
            projectInteraction(interaction, envelope: envelope)
        case let .task(task):
            projectTask(task, envelope: envelope)
        case let .subAgent(subAgent):
            projectSubAgent(subAgent, envelope: envelope)
        case let .contextCompaction(compaction):
            projectContextCompaction(compaction, envelope: envelope)
        case let .lifecycle(lifecycle):
            projection(envelope, kind: .centeredNote, title: lifecycle.message ?? lifecycle.state.rawValue)
        case let .sessionContinuity(continuity):
            projection(envelope, kind: .centeredNote, title: continuity.message ?? continuity.continuity.rawValue)
        case let .diagnostic(diagnostic):
            projection(envelope, kind: .diagnostic, title: diagnostic.message, detail: diagnostic.severity.rawValue)
        case .sessionMetadata:
            nil
        default:
            nil
        }
    }

    private func projectInteraction(_ interaction: AgentInteractionEvent, envelope: AgentEventEnvelope) -> AgentTranscriptProjection {
        let kind: AgentTranscriptProjectionKind = switch interaction.kind {
        case .approval, .planModeExit:
            .approval
        case .prompt:
            .prompt
        }
        return projection(envelope, kind: kind, title: interaction.prompt, detail: interaction.kind.rawValue)
    }

    private func projectTask(_ task: AgentTaskEvent, envelope: AgentEventEnvelope) -> AgentTranscriptProjection {
        let isTaskList = task.metadata["todos"] != nil || task.metadata["tasks"] != nil
        return projection(
            envelope,
            kind: isTaskList ? .taskList : .task,
            title: task.description ?? task.taskType ?? task.id,
            detail: task.status
        )
    }

    private func projectSubAgent(_ subAgent: AgentSubAgentEvent, envelope: AgentEventEnvelope) -> AgentTranscriptProjection {
        projection(
            envelope,
            kind: .subAgent,
            title: subAgent.description ?? subAgent.agentType ?? subAgent.id,
            detail: subAgent.status ?? subAgent.phase.rawValue
        )
    }

    private func projectContextCompaction(
        _ compaction: AgentContextCompactionEvent,
        envelope: AgentEventEnvelope
    ) -> AgentTranscriptProjection {
        let title: String = switch compaction.phase {
        case .started:
            "Compacting context"
        case .completed:
            "Context compacted"
        case .failed:
            "Context compaction failed"
        }
        return projection(envelope, kind: .centeredNote, title: title, detail: compaction.errorMessage ?? compaction.summary)
    }

    private func projection(
        _ envelope: AgentEventEnvelope,
        kind: AgentTranscriptProjectionKind,
        role: AgentMessageRole? = nil,
        title: String,
        detail: String? = nil
    ) -> AgentTranscriptProjection {
        AgentTranscriptProjection(
            id: "\(envelope.generation):\(envelope.index)",
            kind: kind,
            indexRange: envelope.index...envelope.index,
            role: role,
            title: title,
            detail: detail,
            envelopes: [envelope]
        )
    }

    private func eventOrder(_ lhs: AgentEventEnvelope, _ rhs: AgentEventEnvelope) -> Bool {
        if lhs.generation == rhs.generation {
            return lhs.index < rhs.index
        }
        return lhs.generation < rhs.generation
    }
}

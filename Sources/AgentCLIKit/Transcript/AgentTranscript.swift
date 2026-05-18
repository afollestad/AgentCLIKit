import Foundation

/// Transcript item produced from one or more event envelopes.
public struct AgentTranscriptEntry: Codable, Equatable, Sendable {
    /// Envelope index range included in this entry.
    public let indexRange: ClosedRange<Int>
    /// Message role when the entry represents message text.
    public let role: AgentMessageRole?
    /// Renderable text content.
    public let text: String
    /// Source events included in the entry.
    public let envelopes: [AgentEventEnvelope]

    /// Creates a transcript entry.
    public init(indexRange: ClosedRange<Int>, role: AgentMessageRole?, text: String, envelopes: [AgentEventEnvelope]) {
        self.indexRange = indexRange
        self.role = role
        self.text = text
        self.envelopes = envelopes
    }
}

/// Policy that decides whether two event envelopes can be grouped in a transcript.
public protocol AgentTranscriptGroupingPolicy: Sendable {
    /// Returns whether `next` should be appended to the current transcript entry.
    func canGroup(_ current: AgentTranscriptEntry, with next: AgentEventEnvelope) -> Bool
    /// Creates a transcript entry from one event envelope.
    func makeEntry(from envelope: AgentEventEnvelope) -> AgentTranscriptEntry?
    /// Appends an envelope to an existing transcript entry.
    func append(_ envelope: AgentEventEnvelope, to entry: AgentTranscriptEntry) -> AgentTranscriptEntry
}

/// Default transcript grouping policy for message events.
public struct MessageTranscriptGroupingPolicy: AgentTranscriptGroupingPolicy {
    /// Creates a message transcript grouping policy.
    public init() {}

    /// Returns whether adjacent message events share the same role.
    public func canGroup(_ current: AgentTranscriptEntry, with next: AgentEventEnvelope) -> Bool {
        guard case let .message(message) = next.event else {
            return false
        }
        guard let previous = current.envelopes.last else {
            return false
        }
        return current.role == message.role
            && previous.providerId == next.providerId
            && previous.conversationId == next.conversationId
            && previous.providerSessionId == next.providerSessionId
            && previous.generation == next.generation
            && previous.index + 1 == next.index
    }

    /// Creates a transcript entry from a message envelope.
    public func makeEntry(from envelope: AgentEventEnvelope) -> AgentTranscriptEntry? {
        guard case let .message(message) = envelope.event else {
            return nil
        }
        return AgentTranscriptEntry(indexRange: envelope.index...envelope.index, role: message.role, text: message.text, envelopes: [envelope])
    }

    /// Appends a message envelope to an existing transcript entry.
    public func append(_ envelope: AgentEventEnvelope, to entry: AgentTranscriptEntry) -> AgentTranscriptEntry {
        guard case let .message(message) = envelope.event else {
            return entry
        }
        return AgentTranscriptEntry(
            indexRange: entry.indexRange.lowerBound...envelope.index,
            role: entry.role,
            text: [entry.text, message.text].filter { !$0.isEmpty }.joined(separator: "\n"),
            envelopes: entry.envelopes + [envelope]
        )
    }
}

/// Builder that converts event envelopes into transcript entries using an injected policy.
public struct AgentTranscriptBuilder: Sendable {
    private let policy: any AgentTranscriptGroupingPolicy

    /// Creates a transcript builder.
    public init(policy: any AgentTranscriptGroupingPolicy = MessageTranscriptGroupingPolicy()) {
        self.policy = policy
    }

    /// Builds transcript entries from ordered event envelopes.
    public func build(from envelopes: [AgentEventEnvelope]) -> [AgentTranscriptEntry] {
        var entries: [AgentTranscriptEntry] = []
        let sortedEnvelopes = envelopes.sorted {
            if $0.generation == $1.generation {
                return $0.index < $1.index
            }
            return $0.generation < $1.generation
        }
        for envelope in sortedEnvelopes {
            guard let candidate = policy.makeEntry(from: envelope) else {
                continue
            }
            if let last = entries.last, policy.canGroup(last, with: envelope) {
                entries[entries.count - 1] = policy.append(envelope, to: last)
            } else {
                entries.append(candidate)
            }
        }
        return entries
    }
}

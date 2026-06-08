import Foundation

/// Latest conversation metrics derived from runtime events.
public struct AgentConversationMetrics: Codable, Equatable, Sendable {
    /// Latest usage event when known.
    public let usage: AgentUsageEvent?
    /// Latest rate-limit event when known.
    public let rateLimit: AgentRateLimitEvent?
    /// Latest model name when known.
    public let model: String?
    /// Latest context-window size when known.
    public let contextWindow: Int?

    /// Creates conversation metrics.
    public init(
        usage: AgentUsageEvent? = nil,
        rateLimit: AgentRateLimitEvent? = nil,
        model: String? = nil,
        contextWindow: Int? = nil
    ) {
        self.usage = usage
        self.rateLimit = rateLimit
        self.model = model
        self.contextWindow = contextWindow
    }
}

/// Builds conversation metrics from event envelopes.
public struct AgentConversationMetricsBuilder: Sendable {
    /// Creates a metrics builder.
    public init() {}

    /// Returns the latest known metrics in the supplied envelopes.
    public func build(from envelopes: [AgentEventEnvelope]) -> AgentConversationMetrics {
        var latestUsage: AgentUsageEvent?
        var latestRateLimit: AgentRateLimitEvent?
        for envelope in envelopes.sorted(by: eventOrder) {
            switch envelope.event {
            case let .usage(usage):
                latestUsage = usage
            case let .rateLimit(rateLimit):
                latestRateLimit = rateLimit
            case .sessionMetadata:
                break
            default:
                break
            }
        }
        return AgentConversationMetrics(
            usage: latestUsage,
            rateLimit: latestRateLimit,
            model: latestUsage?.model,
            contextWindow: latestUsage?.contextWindow
        )
    }

    private func eventOrder(_ lhs: AgentEventEnvelope, _ rhs: AgentEventEnvelope) -> Bool {
        if lhs.generation == rhs.generation {
            return lhs.index < rhs.index
        }
        return lhs.generation < rhs.generation
    }
}

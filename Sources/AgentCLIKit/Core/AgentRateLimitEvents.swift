import Foundation

/// Harness-reported rate-limit status.
public struct AgentRateLimitStatus: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// Request is allowed.
    public static let allowed: AgentRateLimitStatus = "allowed"
    /// Request is allowed, but the harness reports that usage is approaching a limit.
    public static let allowedWarning: AgentRateLimitStatus = "allowed_warning"
    /// Request was rejected because a limit was reached.
    public static let rejected: AgentRateLimitStatus = "rejected"

    /// Raw harness status value.
    public let rawValue: String

    /// Creates a rate-limit status.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a rate-limit status from a string literal.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

/// Harness-reported rate-limit state.
public struct AgentRateLimitEvent: Codable, Equatable, Sendable {
    /// Current rate-limit status.
    public let status: AgentRateLimitStatus
    /// Date when the active limit resets, if reported by the harness.
    public let resetDate: Date?
    /// Harness-specific limit bucket, such as `five_hour` or `seven_day`.
    public let limitType: String?
    /// Fraction of the limit currently used, when available.
    public let utilization: Double?
    /// Overage status for harnesses that support paid overflow usage.
    public let overageStatus: AgentRateLimitStatus?
    /// Date when the overage limit resets, if reported by the harness.
    public let overageResetDate: Date?
    /// Harness-reported reason overage is unavailable.
    public let overageDisabledReason: String?
    /// Harness-specific rate-limit fields.
    public let metadata: [String: JSONValue]

    /// Creates a rate-limit event.
    public init(
        status: AgentRateLimitStatus,
        resetDate: Date? = nil,
        limitType: String? = nil,
        utilization: Double? = nil,
        overageStatus: AgentRateLimitStatus? = nil,
        overageResetDate: Date? = nil,
        overageDisabledReason: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.status = status
        self.resetDate = resetDate
        self.limitType = limitType
        self.utilization = utilization
        self.overageStatus = overageStatus
        self.overageResetDate = overageResetDate
        self.overageDisabledReason = overageDisabledReason
        self.metadata = metadata
    }
}

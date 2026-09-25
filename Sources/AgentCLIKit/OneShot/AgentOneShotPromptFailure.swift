import Foundation

/// Harness-reported one-shot failures, shared by the default runner and hosts that run prepared commands themselves.
public extension AgentHarnessAdapter {
    /// Returns the failure a harness reported through its structured stdout, or `nil` when it reported no message.
    ///
    /// Harnesses can exit unsuccessfully with an empty stderr and report the cause only in stdout. Only the harness's own
    /// error survives; stdout that parses as a normal or malformed stream yields `nil`, because it may carry intermediate
    /// reasoning or tool content.
    func reportedOneShotPromptFailure(
        stdout: String,
        stderr: String,
        request: AgentOneShotPromptRequest
    ) async -> AgentOneShotPromptError? {
        do {
            _ = try await finalOneShotPromptText(stdout: stdout, stderr: stderr, request: request)
        } catch let error as AgentOneShotPromptError {
            guard let message = error.reportedMessage,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return error
        } catch {}
        return nil
    }
}

public extension AgentOneShotPromptError {
    /// The harness's own failure text, for errors it reported rather than ones the host observed.
    var reportedMessage: String? {
        switch self {
        case let .unavailableModel(_, message),
             let .approvalRequired(_, message),
             let .promptRequired(_, message),
             let .harnessReportedError(_, message, _, _):
            message
        default:
            nil
        }
    }
}

extension AgentOneShotPromptError {
    /// Maps harness failure text onto the cases hosts handle specially; `nil` leaves the caller's fallback in place.
    static func classified(harnessId: AgentHarnessID, message: String) -> AgentOneShotPromptError? {
        let normalized = message.lowercased()
        if normalized.contains("model") && (normalized.contains("unavailable") || normalized.contains("not available")) {
            return .unavailableModel(harnessId: harnessId, message: message)
        }
        if normalized.contains("approval") ||
            (normalized.contains("permission") && (normalized.contains("denied") || normalized.contains("required"))) {
            return .approvalRequired(harnessId: harnessId, message: message)
        }
        if normalized.contains("askuserquestion") ||
            (normalized.contains("prompt") && (normalized.contains("required") || normalized.contains("requested"))) {
            return .promptRequired(harnessId: harnessId, message: message)
        }
        return nil
    }
}

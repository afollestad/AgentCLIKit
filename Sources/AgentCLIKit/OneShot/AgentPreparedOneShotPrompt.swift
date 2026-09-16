import Foundation

/// A command and its disposable resources. Keep this alive until the child process has terminated.
/// Call `cleanup()` on every exit path; deinitialization is only a best-effort fallback for abandoned preparations.
public final class AgentPreparedOneShotPrompt: @unchecked Sendable {
    /// The complete command, including any environment isolation required by the harness.
    public let command: ShellCommand
    /// When present, reject an expired preparation and terminate the process by this deadline.
    /// It bounds temporary credential validity even if the caller delays launch after preparation.
    public let executionDeadline: Date?
    private let lock = NSLock()
    private var cleanupAction: (@Sendable () throws -> Void)?

    /// Creates a prepared command. Cleanup must remove only resources owned by this preparation.
    public init(command: ShellCommand, executionDeadline: Date? = nil, cleanup: @escaping @Sendable () throws -> Void = {}) {
        self.command = command
        self.executionDeadline = executionDeadline
        cleanupAction = cleanup
    }

    /// Releases resources after process termination. Successful cleanup runs once; failed cleanup can be retried.
    public func cleanup() throws {
        try lock.withLock {
            try cleanupAction?()
            cleanupAction = nil
        }
    }

    deinit {
        try? cleanup()
    }
}

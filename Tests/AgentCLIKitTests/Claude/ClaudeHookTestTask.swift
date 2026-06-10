import Foundation

enum ClaudeHookTestTask {
    static func value<T: Sendable>(of task: Task<T, Never>, timeoutNanoseconds: UInt64) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let race = ClaudeHookTestTaskRace(task: task, continuation: continuation)
            Task {
                let value = await task.value
                race.succeed(value)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                race.fail(ClaudeHookTestTimeout())
            }
        }
    }
}

private struct ClaudeHookTestTimeout: Error {}

private final class ClaudeHookTestTaskRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let task: Task<T, Never>
    private var continuation: CheckedContinuation<T, Error>?

    init(task: Task<T, Never>, continuation: CheckedContinuation<T, Error>) {
        self.task = task
        self.continuation = continuation
    }

    func succeed(_ value: T) {
        takeContinuation()?.resume(returning: value)
    }

    func fail(_ error: Error) {
        task.cancel()
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
    }
}

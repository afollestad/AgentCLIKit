import Foundation

final class ClaudeHookDecisionRace: @unchecked Sendable {
    enum Winner {
        case decision
        case timeout
        case invalidation
    }

    private let lock = NSLock()
    private var hasResolved = false
    private var resolvedDecision: ClaudeHookDecision?
    private var continuation: CheckedContinuation<ClaudeHookDecision, Never>?
    private var decisionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func setContinuation(_ continuation: CheckedContinuation<ClaudeHookDecision, Never>) {
        var decision: ClaudeHookDecision?
        lock.withLock {
            if hasResolved {
                decision = resolvedDecision ?? .deferDecision
            } else {
                self.continuation = continuation
            }
        }
        if let decision {
            continuation.resume(returning: decision)
        }
    }

    func setDecisionTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard !hasResolved else {
                return true
            }
            decisionTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard !hasResolved else {
                return true
            }
            timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func resolve(with decision: ClaudeHookDecision, winner: Winner) {
        var didResolve = false
        var continuationToResume: CheckedContinuation<ClaudeHookDecision, Never>?
        let taskToCancel: Task<Void, Never>? = lock.withLock {
            guard !hasResolved else {
                return nil
            }
            hasResolved = true
            resolvedDecision = decision
            didResolve = true
            continuationToResume = continuation
            continuation = nil
            switch winner {
            case .decision:
                return timeoutTask
            case .timeout, .invalidation:
                return decisionTask
            }
        }
        guard didResolve else {
            return
        }
        continuationToResume?.resume(returning: decision)
        taskToCancel?.cancel()
    }
}

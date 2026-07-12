import Foundation

final class AgentHostToolInvocationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private var executions: [UUID: AgentHostToolInvocationExecution] = [:]

    func execute(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async -> AgentHostToolResult
    ) async -> AgentHostToolResult {
        let execution = AgentHostToolInvocationExecution()
        guard register(execution) else {
            return Self.cancelledResult
        }
        defer { unregister(execution) }
        return await withTaskCancellationHandler {
            await execution.run(timeoutNanoseconds: timeoutNanoseconds, operation: operation)
        } onCancel: {
            execution.cancel()
        }
    }

    func deactivate() {
        let activeExecutions = lock.withLock {
            isActive = false
            let activeExecutions = Array(executions.values)
            executions.removeAll()
            return activeExecutions
        }
        activeExecutions.forEach { $0.cancel() }
    }

    private func register(_ execution: AgentHostToolInvocationExecution) -> Bool {
        lock.withLock {
            guard isActive else {
                return false
            }
            executions[execution.id] = execution
            return true
        }
    }

    private func unregister(_ execution: AgentHostToolInvocationExecution) {
        _ = lock.withLock {
            executions.removeValue(forKey: execution.id)
        }
    }

    fileprivate static let cancelledResult = AgentHostToolResult(text: "Host tool call was cancelled.", isError: true)
}

private final class AgentHostToolInvocationExecution: @unchecked Sendable {
    private struct ResolutionState {
        let continuation: CheckedContinuation<AgentHostToolResult, Never>?
        let handlerTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?
    }

    let id = UUID()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<AgentHostToolResult, Never>?
    private var handlerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var terminalResult: AgentHostToolResult?

    func run(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async -> AgentHostToolResult
    ) async -> AgentHostToolResult {
        await withCheckedContinuation { continuation in
            if let terminalResult = install(continuation: continuation) {
                continuation.resume(returning: terminalResult)
                return
            }
            let startGate = AgentHostToolInvocationStartGate()
            let handlerTask = Task { [weak self] in
                guard await startGate.wait(), !Task.isCancelled else {
                    return
                }
                let result = await operation()
                self?.resolve(result)
            }
            startGate.resolve(install(handlerTask: handlerTask))
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                self?.resolve(AgentHostToolResult(text: "Host tool call timed out.", isError: true))
            }
            install(timeoutTask: timeoutTask)
        }
    }

    func cancel() {
        resolve(AgentHostToolInvocationLifetime.cancelledResult)
    }

    private func install(continuation: CheckedContinuation<AgentHostToolResult, Never>) -> AgentHostToolResult? {
        lock.withLock {
            guard terminalResult == nil else {
                return terminalResult
            }
            self.continuation = continuation
            return nil
        }
    }

    private func install(handlerTask: Task<Void, Never>) -> Bool {
        let shouldCancel = lock.withLock {
            guard terminalResult == nil else {
                return true
            }
            self.handlerTask = handlerTask
            return false
        }
        if shouldCancel {
            handlerTask.cancel()
        }
        return !shouldCancel
    }

    private func install(timeoutTask: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard terminalResult == nil else {
                return true
            }
            self.timeoutTask = timeoutTask
            return false
        }
        if shouldCancel {
            timeoutTask.cancel()
        }
    }

    private func resolve(_ result: AgentHostToolResult) {
        let state: ResolutionState? = lock.withLock {
            guard terminalResult == nil else {
                return nil
            }
            terminalResult = result
            let state = ResolutionState(
                continuation: continuation,
                handlerTask: handlerTask,
                timeoutTask: timeoutTask
            )
            continuation = nil
            handlerTask = nil
            timeoutTask = nil
            return state
        }
        state?.handlerTask?.cancel()
        state?.timeoutTask?.cancel()
        state?.continuation?.resume(returning: result)
    }
}

private final class AgentHostToolInvocationStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var decision: Bool?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let decision = lock.withLock {
                guard self.decision == nil else {
                    return self.decision
                }
                self.continuation = continuation
                return nil
            }
            if let decision {
                continuation.resume(returning: decision)
            }
        }
    }

    func resolve(_ shouldStart: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard decision == nil else {
                return nil
            }
            decision = shouldStart
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: shouldStart)
    }
}

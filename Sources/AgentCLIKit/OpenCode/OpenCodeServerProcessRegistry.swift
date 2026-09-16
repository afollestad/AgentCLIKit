import Darwin
import Foundation

/// Retains every SDK-owned server until its termination is observed, including discovery tasks
/// whose callers have gone away. Normal host exit cannot await those actors, so its fallback is synchronous.
final class OpenCodeServerProcessRegistry: @unchecked Sendable {
    static let shared: OpenCodeServerProcessRegistry = {
        let registry = OpenCodeServerProcessRegistry()
        atexit { OpenCodeServerProcessRegistry.shared.shutdown() }
        return registry
    }()

    private let lock = NSLock()
    private let launchProcess: @Sendable (Process) throws -> Void
    private var processes: [ObjectIdentifier: OpenCodeOwnedServerProcess] = [:]
    private var isShutdown = false

    init(launchProcess: @escaping @Sendable (Process) throws -> Void = { try $0.run() }) {
        self.launchProcess = launchProcess
    }

    /// Launch and registration share the shutdown lock: a late resolver cannot spawn past the exit sweep.
    func launch(_ process: Process) throws -> OpenCodeOwnedServerProcess {
        try lock.withLock {
            guard !isShutdown else { throw CancellationError() }
            let owned = OpenCodeOwnedServerProcess(process)
            let identity = ObjectIdentifier(owned)
            process.terminationHandler = { [weak self, weak owned] _ in
                owned?.didTerminate()
                self?.remove(identity)
            }
            processes[identity] = owned
            do {
                try launchProcess(process)
                return owned
            } catch {
                processes.removeValue(forKey: identity)
                process.terminationHandler = nil
                owned.didTerminate()
                throw error
            }
        }
    }

    /// Uses one deadline for all children; an arbitrary number of unfinished probes cannot delay exit indefinitely.
    func shutdown(grace: TimeInterval = 1) {
        let owned = lock.withLock {
            isShutdown = true
            return Array(processes.values)
        }
        owned.forEach { $0.terminate() }
        let deadline = DispatchTime.now() + grace
        owned.forEach { _ = $0.wait(until: deadline) }
        owned.forEach { $0.forceKill() }
        let killDeadline = DispatchTime.now() + 1
        owned.forEach { _ = $0.wait(until: killDeadline) }
    }

    private func remove(_ identity: ObjectIdentifier) {
        _ = lock.withLock { processes.removeValue(forKey: identity) }
    }
}

/// The termination handler is installed before launch. DispatchGroup observation works across executors;
/// Foundation's waitUntilExit can hang when the process was launched on a different thread/run loop.
final class OpenCodeOwnedServerProcess: @unchecked Sendable {
    let process: Process
    private let exited = DispatchGroup()
    private let lock = NSLock()
    private var didExit = false

    init(_ process: Process) {
        self.process = process
        exited.enter()
    }

    func didTerminate() {
        lock.withLock {
            guard !didExit else { return }
            didExit = true
            exited.leave()
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    func wait(until deadline: DispatchTime) -> DispatchTimeoutResult {
        exited.wait(timeout: deadline)
    }

    /// Cancellation must not abandon teardown, and callers join the observed exit before deleting related state.
    func stop(grace: TimeInterval) async {
        terminate()
        await Task.detached { [self] in
            if wait(until: .now() + grace) == .timedOut { forceKill() }
        }.value
        await withCheckedContinuation { continuation in
            exited.notify(queue: .global()) { continuation.resume() }
        }
    }
}

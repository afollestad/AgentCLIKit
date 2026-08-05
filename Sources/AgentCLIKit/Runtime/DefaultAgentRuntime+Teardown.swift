import Foundation

/// Cancellation, kill, destroy, and shutdown paths: everything that tears a provider process down.
extension DefaultAgentRuntime {

    /// Sends an interrupt request and terminates the provider process.
    public func cancel(conversationId: AgentConversationID) async {
        guard shouldAcceptCancellation(conversationId: conversationId) else {
            return
        }
        let state = states[conversationId]
        emitFailedContextCompactionsForTerminalProcess(
            conversationId: conversationId,
            reason: "cancelled",
            message: "Context compaction was interrupted by host cancellation."
        )
        emitFailedSubAgentsForTerminalProcess(
            conversationId: conversationId,
            reason: "cancelled",
            message: "Sub-agent was interrupted by host cancellation."
        )
        emitLifecycle(.cancelled, conversationId: conversationId, exitCode: nil, message: "Cancelled by host.")
        states[conversationId]?.stdin = nil
        states[conversationId]?.stdinWriter = nil
        if let state {
            let context = AgentProviderInterruptContext(
                conversationId: conversationId,
                processToken: state.processToken,
                providerSessionId: state.providerSessionId,
                spawnConfig: state.spawnConfig,
                reason: "Cancelled by host."
            )
            do {
                try await state.adapter.interrupt(context: context)
            } catch {
                emitDiagnostic(
                    severity: .warning,
                    message: "Provider interrupt failed: \(error.localizedDescription)",
                    metadata: ["interrupt_error": .string(error.localizedDescription)],
                    source: .runtime,
                    conversationId: conversationId
                )
            }
        }
        states[conversationId]?.process?.terminate()
    }

    /// Immediately kills the provider process.
    public func kill(conversationId: AgentConversationID) async {
        guard shouldAcceptKill(conversationId: conversationId) else {
            return
        }
        let process = states[conversationId]?.process
        states[conversationId]?.stdin = nil
        states[conversationId]?.stdinWriter = nil
        forceKill(process)
    }

    /// Destroys runtime state for a conversation.
    public func destroy(conversationId: AgentConversationID) async {
        cancelStart(conversationId: conversationId)
        let inFlight = inFlightStartResources[conversationId]
        let removedState = states.removeValue(forKey: conversationId)
        let removedPendingSubscribers = pendingSubscribers.removeValue(forKey: conversationId)
        removedState?.subscribers.values.forEach { $0.finish() }
        removedPendingSubscribers?.values.forEach { $0.finish() }
        statusSubscribers.removeValue(forKey: conversationId)?.values.forEach { $0.finish() }
        removedState?.outputPumps.forEach { $0.cancel() }
        removedState?.providerEventTasks.forEach { $0.cancel() }
        // Remove visible state before teardown awaits so input and status cannot race with destruction.
        forceKill(removedState?.process)
        if let inFlight {
            // Keep the tracked tombstone so a suspended launch performs one final cleanup after it resumes.
            await invalidateProcessResources(adapter: inFlight.adapter, processToken: inFlight.processToken)
        }
        if let removedState {
            await invalidateProcessResources(adapter: removedState.adapter, processToken: removedState.processToken)
        }
    }

    /// Shuts down runtime-owned shared resources.
    public func shutdown() async {
        if isShutdown {
            guard !isShutdownComplete else {
                return
            }
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        isShutdown = true
        hostToolFailureMonitorStartTask?.cancel()
        hostToolFailureMonitorStartTask = nil
        hostToolFailureTask?.cancel()
        hostToolFailureTask = nil
        cancelAllStarts()
        let inFlightStarts = Array(inFlightStartResources.values)
        let activeStates = Array(states.values)
        states.removeAll()
        pendingSubscribers.values.flatMap(\.values).forEach { $0.finish() }
        pendingSubscribers.removeAll()
        statusSubscribers.values.flatMap(\.values).forEach { $0.finish() }
        statusSubscribers.removeAll()
        for state in activeStates {
            state.outputPumps.forEach { $0.cancel() }
            state.providerEventTasks.forEach { $0.cancel() }
            state.subscribers.values.forEach { $0.finish() }
            forceKill(state.process)
        }
        for inFlight in inFlightStarts {
            // Retain in-flight tombstones until suspended launches resume and perform final cleanup.
            await invalidateProcessResources(adapter: inFlight.adapter, processToken: inFlight.processToken)
        }
        for state in activeStates {
            await invalidateProcessResources(adapter: state.adapter, processToken: state.processToken)
        }
        for adapter in adapters.values {
            await adapter.shutdownProviderResources()
        }
        await hostToolServer?.shutdown()
        sensitiveValuesByProcessToken.removeAll()
        isShutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func shouldAcceptCancellation(conversationId: AgentConversationID) -> Bool {
        guard let state = states[conversationId] else {
            return false
        }
        // Host commands can race with process exit callbacks; cancellation must not rewrite terminal status.
        return !state.lifecycleState.isTerminal
    }

    func shouldAcceptKill(conversationId: AgentConversationID) -> Bool {
        guard let state = states[conversationId] else {
            return false
        }
        // Allow kill to escalate an already cancelled process, but avoid acting on completed sessions.
        return state.lifecycleState != .exited && state.lifecycleState != .failed
    }

    func forceKill(_ process: Process?) {
        guard let process, process.isRunning else {
            return
        }
        process.interrupt()
        process.terminate()
        // SIGINT/SIGTERM are advisory; SIGKILL makes `kill` reliable for providers that trap softer signals.
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func invalidateProcessResources(adapter: any AgentProviderAdapter, processToken: UUID) async {
        await hostToolServer?.invalidate(processToken: processToken)
        await adapter.processDidTerminate(processToken: processToken)
        sensitiveValuesByProcessToken[processToken] = nil
    }
}

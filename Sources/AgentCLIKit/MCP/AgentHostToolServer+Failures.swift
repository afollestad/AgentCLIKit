import Foundation
import MCP

extension DefaultAgentHostToolServer {
    func failures() async -> AsyncStream<AgentHostToolServerFailure> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        installFailureHandlerIfNeeded()
        let id = UUID()
        let stream = AsyncStream<AgentHostToolServerFailure>.makeStream()
        failureContinuations[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeFailureContinuation(id) }
        }
        return stream.stream
    }

    func invalidateRegistrationsAfterListenerFailure() async {
        let staleRegistrations = registrations
        registrations.removeAll()
        for registration in staleRegistrations.values {
            registration.invocationLifetime.deactivate()
            listener.removeRoute(path: registration.path)
        }
        publishUnexpectedListenerFailure(processTokens: Array(staleRegistrations.keys))
        for registration in staleRegistrations.values {
            await registration.server.stop()
        }
    }

    func installFailureHandlerIfNeeded() {
        guard !isFailureHandlerInstalled else {
            return
        }
        isFailureHandlerInstalled = true
        listener.setUnexpectedFailureHandler { [weak self] failure in
            Task { await self?.handleUnexpectedListenerFailure(failure) }
        }
    }

    private func handleUnexpectedListenerFailure(_ failure: AgentHostToolHTTPListenerFailure) async {
        guard !isShutdown else {
            return
        }
        port = nil
        var serversToStop = [Server]()
        var affectedProcessTokens = Set<UUID>()
        for affectedRoute in failure.affectedRoutes {
            guard let registration = registrations[affectedRoute.processToken],
                  registration.path == affectedRoute.path else {
                continue
            }
            registrations.removeValue(forKey: affectedRoute.processToken)
            registration.invocationLifetime.deactivate()
            listener.removeRoute(path: registration.path)
            serversToStop.append(registration.server)
            affectedProcessTokens.insert(affectedRoute.processToken)
        }
        publishUnexpectedListenerFailure(processTokens: Array(affectedProcessTokens))
        for server in serversToStop {
            await server.stop()
        }
    }

    private func publishUnexpectedListenerFailure(processTokens: [UUID]) {
        let processTokens = Set(processTokens).sorted { $0.uuidString < $1.uuidString }
        guard !processTokens.isEmpty else {
            return
        }
        let event = AgentHostToolServerFailure(
            processTokens: processTokens,
            message: "Host tools became unavailable because the local listener stopped unexpectedly. "
                + "Replace the affected provider process before using host tools again."
        )
        failureContinuations.values.forEach { $0.yield(event) }
    }

    private func removeFailureContinuation(_ id: UUID) {
        failureContinuations.removeValue(forKey: id)
    }
}

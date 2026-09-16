import Foundation

/// Routes harness session actions through owned or runtime-shared harness adapters.
public struct AgentHarnessSessionActionRouter: Sendable {
    /// Creates a router that builds a fresh default harness adapter set for each action.
    public init() {
        self.init {
            AgentHarnessAdapterSet(adapters: [
                ClaudeHarnessAdapter(),
                CodexHarnessAdapter(),
                OpenCodeHarnessAdapter()
            ])
        }
    }

    /// Creates a router that builds a fresh harness adapter set for each action.
    /// - Parameter makeAdapterSet: Factory that must return owned adapters that are not shared with an active runtime.
    public init(makeAdapterSet: @escaping @Sendable () -> AgentHarnessAdapterSet) {
        self.makeAdapterSet = makeAdapterSet
        self.ownsAdapters = true
    }

    /// Reuses the runtime's adapters so session actions reach the server holding the session's writer lock.
    /// The runtime retains shutdown ownership; neither successful nor failed actions shut down these adapters.
    public init(borrowing adapterSet: AgentHarnessAdapterSet) {
        self.makeAdapterSet = { adapterSet }
        self.ownsAdapters = false
    }

    /// Archives the harness session associated with `record`, if the harness has a native archive action.
    public func archiveSession(_ record: AgentSessionRecord) async throws {
        try await route(record) { adapter in
            try await adapter.archiveSession(record)
        }
    }

    /// Unarchives the harness session associated with `record`, if the harness has a native unarchive action.
    public func unarchiveSession(_ record: AgentSessionRecord) async throws {
        try await route(record) { adapter in
            try await adapter.unarchiveSession(record)
        }
    }

    /// Deletes the harness session associated with `record`, if the harness has a native delete action.
    public func deleteSession(_ record: AgentSessionRecord) async throws {
        try await route(record) { adapter in
            try await adapter.deleteSession(record)
        }
    }

    private let makeAdapterSet: @Sendable () -> AgentHarnessAdapterSet
    private let ownsAdapters: Bool

    private func route(
        _ record: AgentSessionRecord,
        action: (any AgentHarnessAdapter) async throws -> Void
    ) async throws {
        let adapterSet = makeAdapterSet()
        do {
            guard let adapter = adapterSet.adapters.first(where: { $0.definition.id == record.harnessId }) else {
                throw AgentCLIError.harnessNotRegistered(record.harnessId)
            }
            try await action(adapter)
        } catch {
            await shutdown(adapterSet)
            throw error
        }
        await shutdown(adapterSet)
    }

    private func shutdown(_ adapterSet: AgentHarnessAdapterSet) async {
        guard ownsAdapters else {
            return
        }
        for adapter in adapterSet.adapters {
            await adapter.shutdownHarnessResources()
        }
    }
}

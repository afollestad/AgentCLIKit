import Foundation
import XCTest

@testable import AgentCLIKit

final class AgentProviderSessionActionRouterTests: XCTestCase {
    func testRoutesArchiveUnarchiveAndDeleteToMatchingProvider() async throws {
        let state = ActionRecordingProviderState()
        let router = AgentProviderSessionActionRouter {
            AgentProviderAdapterSet(adapters: [
                ActionRecordingProviderAdapter(providerId: .codex, state: state)
            ])
        }
        let record = sessionRecord(providerId: .codex)

        try await router.archiveSession(record)
        try await router.unarchiveSession(record)
        try await router.deleteSession(record)

        let archivedSessionIds = await state.archivedSessionIds
        let unarchivedSessionIds = await state.unarchivedSessionIds
        let deletedSessionIds = await state.deletedSessionIds
        let shutdownCount = await state.shutdownCount

        XCTAssertEqual(archivedSessionIds, ["session"])
        XCTAssertEqual(unarchivedSessionIds, ["session"])
        XCTAssertEqual(deletedSessionIds, ["session"])
        XCTAssertEqual(shutdownCount, 3)
    }

    func testDefaultProviderActionNoOpsForMatchingProviderRecord() async throws {
        let adapter = DefaultSessionActionProviderAdapter(providerId: .claude)
        let record = sessionRecord(providerId: .claude)

        try await adapter.archiveSession(record)
        try await adapter.unarchiveSession(record)
        try await adapter.deleteSession(record)
    }

    func testDefaultProviderActionThrowsForMismatchedProviderRecord() async throws {
        let adapter = DefaultSessionActionProviderAdapter(providerId: .claude)
        let record = sessionRecord(providerId: .codex)

        do {
            try await adapter.archiveSession(record)
            XCTFail("Expected mismatched provider record to throw.")
        } catch let error as AgentCLIError {
            guard case let .invalidInput(message) = error else {
                XCTFail("Expected invalidInput, got \(error).")
                return
            }
            XCTAssertTrue(message.contains("codex"))
            XCTAssertTrue(message.contains("claude"))
        }
    }

    func testThrowsProviderNotRegisteredAndStillShutsDownOwnedAdapters() async throws {
        let state = ActionRecordingProviderState()
        let router = AgentProviderSessionActionRouter {
            AgentProviderAdapterSet(adapters: [
                ActionRecordingProviderAdapter(providerId: .claude, state: state)
            ])
        }

        do {
            try await router.archiveSession(sessionRecord(providerId: .codex))
            XCTFail("Expected missing provider to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error, .providerNotRegistered(.codex))
        }
        let shutdownCount = await state.shutdownCount

        XCTAssertEqual(shutdownCount, 1)
    }

    func testUsesFreshAdapterFactoryForEachOperation() async throws {
        let state = ActionRecordingProviderState()
        let factoryCalls = LockingCounter()
        let router = AgentProviderSessionActionRouter {
            factoryCalls.increment()
            return AgentProviderAdapterSet(adapters: [
                ActionRecordingProviderAdapter(providerId: .codex, state: state)
            ])
        }

        try await router.archiveSession(sessionRecord(providerId: .codex))
        try await router.unarchiveSession(sessionRecord(providerId: .codex))
        try await router.deleteSession(sessionRecord(providerId: .codex))

        let shutdownCount = await state.shutdownCount

        XCTAssertEqual(factoryCalls.value, 3)
        XCTAssertEqual(shutdownCount, 3)
    }

    func testShutsDownOwnedAdaptersAfterActionFailure() async {
        let state = ActionRecordingProviderState()
        let router = AgentProviderSessionActionRouter {
            AgentProviderAdapterSet(adapters: [
                ActionRecordingProviderAdapter(providerId: .codex, archiveError: AgentCLIError.invalidInput("archive failed"), state: state)
            ])
        }

        do {
            try await router.archiveSession(sessionRecord(providerId: .codex))
            XCTFail("Expected archive failure.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error, .invalidInput("archive failed"))
        } catch {
            XCTFail("Expected AgentCLIError, got \(error).")
        }
        let shutdownCount = await state.shutdownCount

        XCTAssertEqual(shutdownCount, 1)
    }

    func testShutsDownOwnedAdaptersAfterCancellationError() async {
        let state = ActionRecordingProviderState()
        let router = AgentProviderSessionActionRouter {
            AgentProviderAdapterSet(adapters: [
                ActionRecordingProviderAdapter(providerId: .codex, archiveError: CancellationError(), state: state)
            ])
        }

        do {
            try await router.archiveSession(sessionRecord(providerId: .codex))
            XCTFail("Expected cancellation error.")
        } catch is CancellationError {
            let shutdownCount = await state.shutdownCount

            XCTAssertEqual(shutdownCount, 1)
        } catch {
            XCTFail("Expected CancellationError, got \(error).")
        }
    }

    func testDoesNotMutateSessionStoreRecords() async throws {
        let record = sessionRecord(providerId: .codex)
        let store = InMemoryAgentSessionStore(records: [record])
        let router = AgentProviderSessionActionRouter {
            AgentProviderAdapterSet(adapters: [
                ActionRecordingProviderAdapter(providerId: .codex, state: ActionRecordingProviderState())
            ])
        }

        try await router.archiveSession(record)

        let records = try await store.allRecords()

        XCTAssertEqual(records, [record])
    }

    private func sessionRecord(providerId: AgentProviderID) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            providerId: providerId,
            providerSessionId: "session",
            workingDirectory: nil,
            generation: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct DefaultSessionActionProviderAdapter: AgentProviderAdapter {
    let providerId: AgentProviderID

    var definition: AgentProviderDefinition {
        AgentProviderDefinition(id: providerId, displayName: "Default Action", executableNames: ["fake"])
    }

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        AgentLaunchConfiguration(executable: "/usr/bin/true")
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

private struct ActionRecordingProviderAdapter: AgentProviderAdapter {
    let providerId: AgentProviderID
    var archiveError: (any Error & Sendable)?
    let state: ActionRecordingProviderState

    var definition: AgentProviderDefinition {
        AgentProviderDefinition(id: providerId, displayName: "Action Recorder", executableNames: ["fake"])
    }

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        AgentLaunchConfiguration(executable: "/usr/bin/true")
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func archiveSession(_ record: AgentSessionRecord) async throws {
        if let archiveError {
            throw archiveError
        }
        await state.recordArchive(record.providerSessionId)
    }

    func unarchiveSession(_ record: AgentSessionRecord) async throws {
        await state.recordUnarchive(record.providerSessionId)
    }

    func deleteSession(_ record: AgentSessionRecord) async throws {
        await state.recordDelete(record.providerSessionId)
    }

    func shutdownProviderResources() async {
        await state.recordShutdown()
    }
}

private actor ActionRecordingProviderState {
    private var archived: [AgentSessionID] = []
    private var unarchived: [AgentSessionID] = []
    private var deleted: [AgentSessionID] = []
    private var shutdowns = 0

    var archivedSessionIds: [AgentSessionID] {
        archived
    }

    var unarchivedSessionIds: [AgentSessionID] {
        unarchived
    }

    var deletedSessionIds: [AgentSessionID] {
        deleted
    }

    var shutdownCount: Int {
        shutdowns
    }

    func recordArchive(_ sessionId: AgentSessionID) {
        archived.append(sessionId)
    }

    func recordUnarchive(_ sessionId: AgentSessionID) {
        unarchived.append(sessionId)
    }

    func recordDelete(_ sessionId: AgentSessionID) {
        deleted.append(sessionId)
    }

    func recordShutdown() {
        shutdowns += 1
    }
}

private final class LockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

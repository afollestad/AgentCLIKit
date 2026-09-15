import Foundation
import XCTest

@testable import AgentCLIKit

final class AgentHarnessSessionActionRouterTests: XCTestCase {
    func testBorrowedAdaptersRouteEveryActionWithoutShuttingDown() async throws {
        let state = ActionRecordingHarnessState()
        let router = AgentHarnessSessionActionRouter(borrowing: AgentHarnessAdapterSet(adapters: [
            ActionRecordingHarnessAdapter(harnessId: .codex, state: state)
        ]))
        let record = sessionRecord(harnessId: .codex)

        try await router.archiveSession(record)
        try await router.unarchiveSession(record)
        try await router.deleteSession(record)

        let archived = await state.archivedSessionIds
        let unarchived = await state.unarchivedSessionIds
        let deleted = await state.deletedSessionIds
        let shutdownCount = await state.shutdownCount
        XCTAssertEqual(archived, ["session"])
        XCTAssertEqual(unarchived, ["session"])
        XCTAssertEqual(deleted, ["session"])
        XCTAssertEqual(shutdownCount, 0)
    }

    func testBorrowedAdaptersSurviveActionFailureAndCancellation() async throws {
        let errors: [any Error & Sendable] = [AgentCLIError.invalidInput("archive failed"), CancellationError()]
        for error in errors {
            let state = ActionRecordingHarnessState()
            let router = AgentHarnessSessionActionRouter(borrowing: AgentHarnessAdapterSet(adapters: [
                ActionRecordingHarnessAdapter(harnessId: .codex, archiveError: error, state: state)
            ]))
            let record = sessionRecord(harnessId: .codex)

            do {
                try await router.archiveSession(record)
                XCTFail("Expected archive failure.")
            } catch let caught as AgentCLIError {
                XCTAssertEqual(caught, error as? AgentCLIError)
            } catch is CancellationError {
                XCTAssertTrue(error is CancellationError)
            }
            try await router.deleteSession(record)

            let deleted = await state.deletedSessionIds
            let shutdownCount = await state.shutdownCount
            XCTAssertEqual(deleted, ["session"])
            XCTAssertEqual(shutdownCount, 0)
        }
    }

    func testMissingHarnessDoesNotShutDownBorrowedAdapters() async throws {
        let state = ActionRecordingHarnessState()
        let router = AgentHarnessSessionActionRouter(borrowing: AgentHarnessAdapterSet(adapters: [
            ActionRecordingHarnessAdapter(harnessId: .claude, state: state)
        ]))

        do {
            try await router.deleteSession(sessionRecord(harnessId: .codex))
            XCTFail("Expected missing harness to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error, .harnessNotRegistered(.codex))
        }

        let shutdownCount = await state.shutdownCount
        XCTAssertEqual(shutdownCount, 0)
    }

    func testRoutesArchiveUnarchiveAndDeleteToMatchingHarness() async throws {
        let state = ActionRecordingHarnessState()
        let router = AgentHarnessSessionActionRouter {
            AgentHarnessAdapterSet(adapters: [
                ActionRecordingHarnessAdapter(harnessId: .codex, state: state)
            ])
        }
        let record = sessionRecord(harnessId: .codex)

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

    func testDefaultHarnessActionNoOpsForMatchingHarnessRecord() async throws {
        let adapter = DefaultSessionActionHarnessAdapter(harnessId: .claude)
        let record = sessionRecord(harnessId: .claude)

        try await adapter.archiveSession(record)
        try await adapter.unarchiveSession(record)
        try await adapter.deleteSession(record)
    }

    func testDefaultHarnessActionThrowsForMismatchedHarnessRecord() async throws {
        let adapter = DefaultSessionActionHarnessAdapter(harnessId: .claude)
        let record = sessionRecord(harnessId: .codex)

        do {
            try await adapter.archiveSession(record)
            XCTFail("Expected mismatched harness record to throw.")
        } catch let error as AgentCLIError {
            guard case let .invalidInput(message) = error else {
                XCTFail("Expected invalidInput, got \(error).")
                return
            }
            XCTAssertTrue(message.contains("codex"))
            XCTAssertTrue(message.contains("claude"))
        }
    }

    func testThrowsHarnessNotRegisteredAndStillShutsDownOwnedAdapters() async throws {
        let state = ActionRecordingHarnessState()
        let router = AgentHarnessSessionActionRouter {
            AgentHarnessAdapterSet(adapters: [
                ActionRecordingHarnessAdapter(harnessId: .claude, state: state)
            ])
        }

        do {
            try await router.archiveSession(sessionRecord(harnessId: .codex))
            XCTFail("Expected missing harness to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error, .harnessNotRegistered(.codex))
        }
        let shutdownCount = await state.shutdownCount

        XCTAssertEqual(shutdownCount, 1)
    }

    func testUsesFreshAdapterFactoryForEachOperation() async throws {
        let state = ActionRecordingHarnessState()
        let factoryCalls = LockingCounter()
        let router = AgentHarnessSessionActionRouter {
            factoryCalls.increment()
            return AgentHarnessAdapterSet(adapters: [
                ActionRecordingHarnessAdapter(harnessId: .codex, state: state)
            ])
        }

        try await router.archiveSession(sessionRecord(harnessId: .codex))
        try await router.unarchiveSession(sessionRecord(harnessId: .codex))
        try await router.deleteSession(sessionRecord(harnessId: .codex))

        let shutdownCount = await state.shutdownCount

        XCTAssertEqual(factoryCalls.value, 3)
        XCTAssertEqual(shutdownCount, 3)
    }

    func testShutsDownOwnedAdaptersAfterActionFailure() async {
        let state = ActionRecordingHarnessState()
        let router = AgentHarnessSessionActionRouter {
            AgentHarnessAdapterSet(adapters: [
                ActionRecordingHarnessAdapter(harnessId: .codex, archiveError: AgentCLIError.invalidInput("archive failed"), state: state)
            ])
        }

        do {
            try await router.archiveSession(sessionRecord(harnessId: .codex))
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
        let state = ActionRecordingHarnessState()
        let router = AgentHarnessSessionActionRouter {
            AgentHarnessAdapterSet(adapters: [
                ActionRecordingHarnessAdapter(harnessId: .codex, archiveError: CancellationError(), state: state)
            ])
        }

        do {
            try await router.archiveSession(sessionRecord(harnessId: .codex))
            XCTFail("Expected cancellation error.")
        } catch is CancellationError {
            let shutdownCount = await state.shutdownCount

            XCTAssertEqual(shutdownCount, 1)
        } catch {
            XCTFail("Expected CancellationError, got \(error).")
        }
    }

    func testDoesNotMutateSessionStoreRecords() async throws {
        let record = sessionRecord(harnessId: .codex)
        let store = InMemoryAgentSessionStore(records: [record])
        let router = AgentHarnessSessionActionRouter {
            AgentHarnessAdapterSet(adapters: [
                ActionRecordingHarnessAdapter(harnessId: .codex, state: ActionRecordingHarnessState())
            ])
        }

        try await router.archiveSession(record)

        let records = try await store.allRecords()

        XCTAssertEqual(records, [record])
    }

    private func sessionRecord(harnessId: AgentHarnessID) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            harnessId: harnessId,
            harnessSessionId: "session",
            workingDirectory: nil,
            generation: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct DefaultSessionActionHarnessAdapter: AgentHarnessAdapter {
    let harnessId: AgentHarnessID

    var definition: AgentHarnessDefinition {
        AgentHarnessDefinition(id: harnessId, displayName: "Default Action", executableNames: ["fake"])
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

private struct ActionRecordingHarnessAdapter: AgentHarnessAdapter {
    let harnessId: AgentHarnessID
    var archiveError: (any Error & Sendable)?
    let state: ActionRecordingHarnessState

    var definition: AgentHarnessDefinition {
        AgentHarnessDefinition(id: harnessId, displayName: "Action Recorder", executableNames: ["fake"])
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
        await state.recordArchive(record.harnessSessionId)
    }

    func unarchiveSession(_ record: AgentSessionRecord) async throws {
        await state.recordUnarchive(record.harnessSessionId)
    }

    func deleteSession(_ record: AgentSessionRecord) async throws {
        await state.recordDelete(record.harnessSessionId)
    }

    func shutdownHarnessResources() async {
        await state.recordShutdown()
    }
}

private actor ActionRecordingHarnessState {
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

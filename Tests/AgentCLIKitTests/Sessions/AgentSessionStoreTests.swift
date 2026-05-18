import XCTest

@testable import AgentCLIKit

final class AgentSessionStoreTests: XCTestCase {
    func testInMemoryStoreSavesLoadsAndRemovesRecords() async throws {
        let store = InMemoryAgentSessionStore()
        let record = AgentSessionRecord(
            conversationId: "conversation",
            providerId: "claude",
            providerSessionId: "session",
            generation: 2
        )

        try await store.save(record)
        let saved = try await store.record(conversationId: "conversation", providerId: "claude")
        XCTAssertEqual(saved, record)

        try await store.remove(conversationId: "conversation", providerId: "claude")
        let removed = try await store.record(conversationId: "conversation", providerId: "claude")
        XCTAssertNil(removed)
    }

    func testInMemoryStoreUsesLastDuplicateRecord() async throws {
        let first = AgentSessionRecord(
            conversationId: "conversation",
            providerId: "claude",
            providerSessionId: "first",
            generation: 1
        )
        let second = AgentSessionRecord(
            conversationId: "conversation",
            providerId: "claude",
            providerSessionId: "second",
            generation: 2
        )
        let store = InMemoryAgentSessionStore(records: [first, second])

        let saved = try await store.record(conversationId: "conversation", providerId: "claude")

        XCTAssertEqual(saved, second)
    }

    func testJSONFileStorePersistsRecordsDeterministically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("sessions.json")
        let store = JSONFileAgentSessionStore(fileURL: fileURL)
        let date = Date(timeIntervalSince1970: 10)
        let codex = AgentSessionRecord(
            conversationId: "b",
            providerId: "codex",
            providerSessionId: "codex-session",
            generation: 1,
            createdAt: date,
            updatedAt: date
        )
        let claude = AgentSessionRecord(
            conversationId: "a",
            providerId: "claude",
            providerSessionId: "claude-session",
            generation: 1,
            createdAt: date,
            updatedAt: date
        )

        try await store.save(codex)
        try await store.save(claude)

        let reloaded = JSONFileAgentSessionStore(fileURL: fileURL)
        let records = try await reloaded.allRecords()
        let savedClaude = try await reloaded.record(conversationId: "a", providerId: "claude")
        XCTAssertEqual(records.map(\.conversationId.rawValue), ["a", "b"])
        XCTAssertEqual(savedClaude, claude)
    }

    func testJSONFileStoreUsesLastDuplicateRecord() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sessions.json")
        let date = Date(timeIntervalSince1970: 10)
        let first = AgentSessionRecord(
            conversationId: "conversation",
            providerId: "claude",
            providerSessionId: "first",
            generation: 1,
            createdAt: date,
            updatedAt: date
        )
        let second = AgentSessionRecord(
            conversationId: "conversation",
            providerId: "claude",
            providerSessionId: "second",
            generation: 2,
            createdAt: date,
            updatedAt: date
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([first, second]).write(to: fileURL)

        let store = JSONFileAgentSessionStore(fileURL: fileURL)
        let saved = try await store.record(conversationId: "conversation", providerId: "claude")

        XCTAssertEqual(saved, second)
    }
}

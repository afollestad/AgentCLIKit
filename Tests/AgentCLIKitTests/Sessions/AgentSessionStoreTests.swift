import XCTest

@testable import AgentCLIKit

final class AgentSessionStoreTests: XCTestCase {
    func testInMemoryStoreSavesLoadsAndRemovesRecords() async throws {
        let store = InMemoryAgentSessionStore()
        let record = AgentSessionRecord(
            conversationId: "conversation",
            harnessId: .claude,
            harnessSessionId: "session",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            generation: 2
        )

        try await store.save(record)
        let saved = try await store.record(conversationId: "conversation", harnessId: .claude)
        XCTAssertEqual(saved, record)
        XCTAssertEqual(saved?.workingDirectory?.path, "/tmp/project")

        try await store.remove(conversationId: "conversation", harnessId: .claude)
        let removed = try await store.record(conversationId: "conversation", harnessId: .claude)
        XCTAssertNil(removed)
    }

    func testInMemoryStoreUsesLastDuplicateRecord() async throws {
        let first = AgentSessionRecord(
            conversationId: "conversation",
            harnessId: .claude,
            harnessSessionId: "first",
            generation: 1
        )
        let second = AgentSessionRecord(
            conversationId: "conversation",
            harnessId: .claude,
            harnessSessionId: "second",
            generation: 2
        )
        let store = InMemoryAgentSessionStore(records: [first, second])

        let saved = try await store.record(conversationId: "conversation", harnessId: .claude)

        XCTAssertEqual(saved, second)
    }

    func testJSONFileStorePersistsRecordsDeterministically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("sessions.json")
        let store = JSONFileAgentSessionStore(fileURL: fileURL)
        let date = Date(timeIntervalSince1970: 10)
        let secondConversation = AgentSessionRecord(
            conversationId: "b",
            harnessId: .claude,
            harnessSessionId: "second-session",
            generation: 1,
            createdAt: date,
            updatedAt: date
        )
        let claude = AgentSessionRecord(
            conversationId: "a",
            harnessId: .claude,
            harnessSessionId: "claude-session",
            generation: 1,
            createdAt: date,
            updatedAt: date
        )

        try await store.save(secondConversation)
        try await store.save(claude)

        let reloaded = JSONFileAgentSessionStore(fileURL: fileURL)
        let records = try await reloaded.allRecords()
        let savedClaude = try await reloaded.record(conversationId: "a", harnessId: .claude)
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
            harnessId: .claude,
            harnessSessionId: "first",
            generation: 1,
            createdAt: date,
            updatedAt: date
        )
        let second = AgentSessionRecord(
            conversationId: "conversation",
            harnessId: .claude,
            harnessSessionId: "second",
            generation: 2,
            createdAt: date,
            updatedAt: date
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([first, second]).write(to: fileURL)

        let store = JSONFileAgentSessionStore(fileURL: fileURL)
        let saved = try await store.record(conversationId: "conversation", harnessId: .claude)

        XCTAssertEqual(saved, second)
    }

    func testSessionRecordDefaultsMissingWorkingDirectory() throws {
        let data = Data("""
        {
          "conversationId": "conversation",
          "providerId": "claude",
          "providerSessionId": "session",
          "generation": 1,
          "createdAt": "1970-01-01T00:00:10Z",
          "updatedAt": "1970-01-01T00:00:10Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(AgentSessionRecord.self, from: data)

        XCTAssertNil(record.workingDirectory)
        XCTAssertEqual(record.metadata, [:])
    }

    func testReverseLookupFiltersByHarnessSessionHarnessAndCanonicalWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        let symlink = directory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: nested)
        let matching = AgentSessionRecord(
            conversationId: "matching",
            harnessId: .claude,
            harnessSessionId: "session",
            workingDirectory: nested,
            generation: 1
        )
        let otherDirectory = AgentSessionRecord(
            conversationId: "other-directory",
            harnessId: .claude,
            harnessSessionId: "session",
            workingDirectory: directory,
            generation: 1
        )
        let otherSession = AgentSessionRecord(
            conversationId: "other-session",
            harnessId: .claude,
            harnessSessionId: "other",
            workingDirectory: nested,
            generation: 1
        )
        let store = InMemoryAgentSessionStore(records: [matching, otherDirectory, otherSession])

        let records = try await store.records(harnessId: .claude, workingDirectory: symlink)
        let record = try await store.record(harnessId: .claude, harnessSessionId: "session", workingDirectory: symlink)

        XCTAssertEqual(records.map(\.conversationId.rawValue).sorted(), ["matching", "other-session"])
        XCTAssertEqual(record?.conversationId, "matching")
    }

    func testRemoveByHarnessSessionPreservesOtherWorkingDirectories() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        let first = AgentSessionRecord(
            conversationId: "first",
            harnessId: .claude,
            harnessSessionId: "session",
            workingDirectory: firstDirectory,
            generation: 1
        )
        let second = AgentSessionRecord(
            conversationId: "second",
            harnessId: .claude,
            harnessSessionId: "session",
            workingDirectory: secondDirectory,
            generation: 1
        )
        let store = InMemoryAgentSessionStore(records: [first, second])

        try await store.remove(harnessId: .claude, harnessSessionId: "session", workingDirectory: firstDirectory)
        let records = try await store.allRecords()

        XCTAssertEqual(records.map(\.conversationId.rawValue), ["second"])
    }

    func testRemoveByHarnessAndWorkingDirectorySupportsOrphanCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("project", isDirectory: true)
        let otherDirectory = directory.appendingPathComponent("other", isDirectory: true)
        let projectRecord = AgentSessionRecord(
            conversationId: "project",
            harnessId: .claude,
            harnessSessionId: "project-session",
            workingDirectory: projectDirectory,
            generation: 1
        )
        let otherRecord = AgentSessionRecord(
            conversationId: "other",
            harnessId: .claude,
            harnessSessionId: "other-session",
            workingDirectory: otherDirectory,
            generation: 1
        )
        let store = InMemoryAgentSessionStore(records: [projectRecord, otherRecord])

        try await store.remove(harnessId: .claude, workingDirectory: projectDirectory)
        let records = try await store.allRecords()

        XCTAssertEqual(records.map(\.conversationId.rawValue), ["other"])
    }
}

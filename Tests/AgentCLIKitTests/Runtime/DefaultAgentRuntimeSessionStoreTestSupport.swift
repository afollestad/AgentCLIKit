import Foundation

@testable import AgentCLIKit

actor OutOfOrderSessionStore: AgentSessionStore {
    private var records: [AgentConversationID: AgentSessionRecord] = [:]
    private let delays: [String: UInt64]

    init(delays: [String: UInt64]) {
        self.delays = delays
    }

    func record(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws -> AgentSessionRecord? {
        records[conversationId]
    }

    func save(_ record: AgentSessionRecord) async throws {
        let delayKey = record.harnessSessionName ?? record.harnessSessionPreview ?? record.harnessSessionId.rawValue
        if let delay = delays[delayKey] ?? delays[record.harnessSessionId.rawValue] {
            try await Task.sleep(nanoseconds: delay)
        }
        records[record.conversationId] = record
    }

    func remove(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws {
        records[conversationId] = nil
    }

    func allRecords() async throws -> [AgentSessionRecord] {
        Array(records.values)
    }
}

actor SelectiveFailureOutOfOrderSessionStore: AgentSessionStore {
    private var records: [AgentConversationID: AgentSessionRecord] = [:]
    private let delays: [String: UInt64]
    private let failingKeys: Set<String>

    init(delays: [String: UInt64], failingKeys: Set<String>) {
        self.delays = delays
        self.failingKeys = failingKeys
    }

    func record(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws -> AgentSessionRecord? {
        records[conversationId]
    }

    func save(_ record: AgentSessionRecord) async throws {
        let delayKey = record.harnessSessionName ?? record.harnessSessionPreview ?? record.harnessSessionId.rawValue
        if let delay = delays[delayKey] ?? delays[record.harnessSessionId.rawValue] {
            try await Task.sleep(nanoseconds: delay)
        }
        if failingKeys.contains(delayKey) || failingKeys.contains(record.harnessSessionId.rawValue) {
            throw AgentCLIError.invalidInput("session store rejected save")
        }
        records[record.conversationId] = record
    }

    func remove(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws {
        records[conversationId] = nil
    }

    func allRecords() async throws -> [AgentSessionRecord] {
        Array(records.values)
    }
}

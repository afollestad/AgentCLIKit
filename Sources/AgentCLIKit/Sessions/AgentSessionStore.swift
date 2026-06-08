import Foundation

/// Persisted mapping between a host conversation and a provider session.
public struct AgentSessionRecord: Codable, Equatable, Sendable {
    /// Host-defined conversation identifier.
    public let conversationId: AgentConversationID
    /// Provider identifier for the session.
    public let providerId: AgentProviderID
    /// Provider-defined session identifier.
    public let providerSessionId: AgentSessionID
    /// Provider-reported user-facing session name when known.
    public let providerSessionName: String?
    /// Canonical working directory associated with the provider session, when known.
    public let workingDirectory: URL?
    /// Runtime generation associated with the provider session.
    public let generation: Int
    /// Date the record was created.
    public let createdAt: Date
    /// Date the record was last updated.
    public let updatedAt: Date
    /// Additional provider-neutral metadata.
    public let metadata: [String: JSONValue]

    /// Creates a session record.
    public init(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        providerSessionId: AgentSessionID,
        providerSessionName: String? = nil,
        workingDirectory: URL? = nil,
        generation: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: JSONValue] = [:]
    ) {
        self.conversationId = conversationId
        self.providerId = providerId
        self.providerSessionId = providerSessionId
        self.providerSessionName = providerSessionName
        self.workingDirectory = workingDirectory.map(AgentPathHelpers.canonicalFileURL)
        self.generation = generation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    /// Decodes a session record, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try container.decode(AgentConversationID.self, forKey: .conversationId)
        providerId = try container.decode(AgentProviderID.self, forKey: .providerId)
        providerSessionId = try container.decode(AgentSessionID.self, forKey: .providerSessionId)
        providerSessionName = try container.decodeIfPresent(String.self, forKey: .providerSessionName)
        workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory).map(AgentPathHelpers.canonicalFileURL)
        generation = try container.decode(Int.self, forKey: .generation)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

/// Storage contract for provider session mappings.
public protocol AgentSessionStore: Sendable {
    /// Loads the latest record for a host conversation and provider.
    func record(conversationId: AgentConversationID, providerId: AgentProviderID) async throws -> AgentSessionRecord?
    /// Saves or replaces a session record.
    func save(_ record: AgentSessionRecord) async throws
    /// Removes a session record.
    func remove(conversationId: AgentConversationID, providerId: AgentProviderID) async throws
    /// Lists all session records.
    func allRecords() async throws -> [AgentSessionRecord]
}

public extension AgentSessionStore {
    /// Loads records matching a provider and, when supplied, a canonical working directory.
    func records(providerId: AgentProviderID, workingDirectory: URL? = nil) async throws -> [AgentSessionRecord] {
        let canonicalWorkingDirectory = workingDirectory.map(AgentPathHelpers.canonicalPath)
        return try await allRecords().filter { record in
            guard record.providerId == providerId else {
                return false
            }
            guard let canonicalWorkingDirectory else {
                return true
            }
            return record.workingDirectory.map(AgentPathHelpers.canonicalPath) == canonicalWorkingDirectory
        }
    }

    /// Loads a record by provider session, optionally scoped to a canonical working directory.
    func record(
        providerId: AgentProviderID,
        providerSessionId: AgentSessionID,
        workingDirectory: URL? = nil
    ) async throws -> AgentSessionRecord? {
        try await records(providerId: providerId, workingDirectory: workingDirectory)
            .first { $0.providerSessionId == providerSessionId }
    }

    /// Removes records matching a provider session, optionally scoped to a canonical working directory.
    func remove(
        providerId: AgentProviderID,
        providerSessionId: AgentSessionID,
        workingDirectory: URL? = nil
    ) async throws {
        let records = try await records(providerId: providerId, workingDirectory: workingDirectory)
            .filter { $0.providerSessionId == providerSessionId }
        for record in records {
            try await remove(conversationId: record.conversationId, providerId: record.providerId)
        }
    }

    /// Removes all records for a provider, optionally scoped to a canonical working directory.
    func remove(providerId: AgentProviderID, workingDirectory: URL? = nil) async throws {
        let records = try await records(providerId: providerId, workingDirectory: workingDirectory)
        for record in records {
            try await remove(conversationId: record.conversationId, providerId: record.providerId)
        }
    }
}

/// In-memory session store for tests and ephemeral hosts.
public actor InMemoryAgentSessionStore: AgentSessionStore {
    private var records: [SessionKey: AgentSessionRecord] = [:]

    /// Creates an in-memory session store.
    public init(records: [AgentSessionRecord] = []) {
        self.records = Dictionary(records.map { (SessionKey($0.conversationId, $0.providerId), $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Loads the latest record for a host conversation and provider.
    public func record(conversationId: AgentConversationID, providerId: AgentProviderID) async throws -> AgentSessionRecord? {
        records[SessionKey(conversationId, providerId)]
    }

    /// Saves or replaces a session record.
    public func save(_ record: AgentSessionRecord) async throws {
        records[SessionKey(record.conversationId, record.providerId)] = record
    }

    /// Removes a session record.
    public func remove(conversationId: AgentConversationID, providerId: AgentProviderID) async throws {
        records[SessionKey(conversationId, providerId)] = nil
    }

    /// Lists all session records.
    public func allRecords() async throws -> [AgentSessionRecord] {
        records.values.sorted {
            if $0.conversationId.rawValue == $1.conversationId.rawValue {
                return $0.providerId.rawValue < $1.providerId.rawValue
            }
            return $0.conversationId.rawValue < $1.conversationId.rawValue
        }
    }
}

/// JSON file-backed session store for small host applications.
public actor JSONFileAgentSessionStore: AgentSessionStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a JSON file-backed session store.
    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Loads the latest record for a host conversation and provider.
    public func record(conversationId: AgentConversationID, providerId: AgentProviderID) async throws -> AgentSessionRecord? {
        try readRecords()[SessionKey(conversationId, providerId)]
    }

    /// Saves or replaces a session record.
    public func save(_ record: AgentSessionRecord) async throws {
        var records = try readRecords()
        records[SessionKey(record.conversationId, record.providerId)] = record
        try writeRecords(records)
    }

    /// Removes a session record.
    public func remove(conversationId: AgentConversationID, providerId: AgentProviderID) async throws {
        var records = try readRecords()
        records[SessionKey(conversationId, providerId)] = nil
        try writeRecords(records)
    }

    /// Lists all session records.
    public func allRecords() async throws -> [AgentSessionRecord] {
        try readRecords().values.sorted {
            if $0.conversationId.rawValue == $1.conversationId.rawValue {
                return $0.providerId.rawValue < $1.providerId.rawValue
            }
            return $0.conversationId.rawValue < $1.conversationId.rawValue
        }
    }

    private func readRecords() throws -> [SessionKey: AgentSessionRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let records = try decoder.decode([AgentSessionRecord].self, from: data)
            return Dictionary(records.map { (SessionKey($0.conversationId, $0.providerId), $0) }, uniquingKeysWith: { _, new in new })
        } catch {
            throw AgentCLIError.sessionStoreFailed(error.localizedDescription)
        }
    }

    private func writeRecords(_ records: [SessionKey: AgentSessionRecord]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Store records as a sorted array to keep diffs deterministic for host apps that sync config files.
            let values = records.values.sorted {
                if $0.conversationId.rawValue == $1.conversationId.rawValue {
                    return $0.providerId.rawValue < $1.providerId.rawValue
                }
                return $0.conversationId.rawValue < $1.conversationId.rawValue
            }
            try encoder.encode(values).write(to: fileURL, options: [.atomic])
        } catch {
            throw AgentCLIError.sessionStoreFailed(error.localizedDescription)
        }
    }
}

private struct SessionKey: Hashable {
    let conversationId: AgentConversationID
    let providerId: AgentProviderID

    init(_ conversationId: AgentConversationID, _ providerId: AgentProviderID) {
        self.conversationId = conversationId
        self.providerId = providerId
    }
}

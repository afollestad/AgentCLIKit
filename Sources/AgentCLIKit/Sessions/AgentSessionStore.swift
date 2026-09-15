import Foundation

/// Persisted mapping between a host conversation and a harness session.
public struct AgentSessionRecord: Codable, Equatable, Sendable {
    /// Host-defined conversation identifier.
    public let conversationId: AgentConversationID
    /// Harness identifier for the session.
    public let harnessId: AgentHarnessID
    /// Harness-defined session identifier.
    public let harnessSessionId: AgentSessionID
    /// Harness-reported user-facing session name when known.
    public let harnessSessionName: String?
    /// Harness-reported user-facing session preview when known.
    public let harnessSessionPreview: String?
    /// Canonical working directory associated with the harness session, when known.
    public let workingDirectory: URL?
    /// Runtime generation associated with the harness session.
    public let generation: Int
    /// Date the record was created.
    public let createdAt: Date
    /// Date the record was last updated.
    public let updatedAt: Date
    /// Additional harness-neutral metadata.
    public let metadata: [String: JSONValue]

    /// Creates a session record.
    public init(
        conversationId: AgentConversationID,
        harnessId: AgentHarnessID,
        harnessSessionId: AgentSessionID,
        harnessSessionName: String? = nil,
        harnessSessionPreview: String? = nil,
        workingDirectory: URL? = nil,
        generation: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: JSONValue] = [:]
    ) {
        self.conversationId = conversationId
        self.harnessId = harnessId
        self.harnessSessionId = harnessSessionId
        self.harnessSessionName = harnessSessionName
        self.harnessSessionPreview = harnessSessionPreview
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
        harnessId = try container.decode(AgentHarnessID.self, forKey: .harnessId)
        harnessSessionId = try container.decode(AgentSessionID.self, forKey: .harnessSessionId)
        harnessSessionName = try container.decodeIfPresent(String.self, forKey: .harnessSessionName)
        harnessSessionPreview = try container.decodeIfPresent(String.self, forKey: .harnessSessionPreview)
        workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory).map(AgentPathHelpers.canonicalFileURL)
        generation = try container.decode(Int.self, forKey: .generation)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case conversationId
        case harnessId = "providerId"
        case harnessSessionId = "providerSessionId"
        case harnessSessionName = "providerSessionName"
        case harnessSessionPreview = "providerSessionPreview"
        case workingDirectory
        case generation
        case createdAt
        case updatedAt
        case metadata
    }
}

public extension AgentSessionRecord {
    /// Metadata key holding harness sessions this conversation used before `harnessSessionId`; retain its persisted spelling.
    static let supersededHarnessSessionIdsMetadataKey = "superseded_provider_session_ids"

    /// Maximum retained lineage entries, so a long-lived conversation cannot grow its record without bound.
    static let supersededHarnessSessionIdLimit = 128

    /// Harness sessions this conversation replaced, oldest first.
    ///
    /// A harness that swaps a conversation onto a new native session — Codex forks a thread whenever a resumed
    /// runtime needs a fresh host-tool route — leaves the previous session behind. Retiring only `harnessSessionId`
    /// would orphan every earlier one, so the lineage travels with the record.
    var supersededHarnessSessionIds: [AgentSessionID] {
        Self.supersededHarnessSessionRawValues(in: metadata).map(AgentSessionID.init(rawValue:))
    }

    /// Returns this record aimed at one superseded harness session, with no lineage of its own.
    ///
    /// Harness session actions fan out over `supersededHarnessSessionIds`, so the per-session record they act on
    /// must carry an empty lineage or the fan-out would recurse.
    func retargeted(to harnessSessionId: AgentSessionID) -> AgentSessionRecord {
        var retargetedMetadata = metadata
        retargetedMetadata[Self.supersededHarnessSessionIdsMetadataKey] = nil
        return AgentSessionRecord(
            conversationId: conversationId,
            harnessId: harnessId,
            harnessSessionId: harnessSessionId,
            harnessSessionName: harnessSessionName,
            harnessSessionPreview: harnessSessionPreview,
            workingDirectory: workingDirectory,
            generation: generation,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: retargetedMetadata
        )
    }

    /// Appends `harnessSessionId` to `metadata`'s lineage, ignoring duplicates and trimming to the retention limit.
    static func appendingSupersededHarnessSessionId(
        _ harnessSessionId: AgentSessionID,
        to metadata: [String: JSONValue]
    ) -> [String: JSONValue] {
        var existing = supersededHarnessSessionRawValues(in: metadata)
        guard !existing.contains(harnessSessionId.rawValue) else {
            return metadata
        }
        existing.append(harnessSessionId.rawValue)
        let retained = existing.suffix(supersededHarnessSessionIdLimit)
        var updated = metadata
        updated[supersededHarnessSessionIdsMetadataKey] = .array(retained.map(JSONValue.string))
        return updated
    }

    private static func supersededHarnessSessionRawValues(in metadata: [String: JSONValue]) -> [String] {
        guard case let .array(values)? = metadata[supersededHarnessSessionIdsMetadataKey] else {
            return []
        }
        return values.compactMap { value in
            guard case let .string(rawValue) = value, !rawValue.isEmpty else {
                return nil
            }
            return rawValue
        }
    }
}

/// Storage contract for harness session mappings.
public protocol AgentSessionStore: Sendable {
    /// Loads the latest record for a host conversation and harness.
    func record(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws -> AgentSessionRecord?
    /// Saves or replaces a session record.
    func save(_ record: AgentSessionRecord) async throws
    /// Removes a session record.
    func remove(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws
    /// Lists all session records.
    func allRecords() async throws -> [AgentSessionRecord]
}

public extension AgentSessionStore {
    /// Loads records matching a harness and, when supplied, a canonical working directory.
    func records(harnessId: AgentHarnessID, workingDirectory: URL? = nil) async throws -> [AgentSessionRecord] {
        let canonicalWorkingDirectory = workingDirectory.map(AgentPathHelpers.canonicalPath)
        return try await allRecords().filter { record in
            guard record.harnessId == harnessId else {
                return false
            }
            guard let canonicalWorkingDirectory else {
                return true
            }
            return record.workingDirectory.map(AgentPathHelpers.canonicalPath) == canonicalWorkingDirectory
        }
    }

    /// Loads a record by harness session, optionally scoped to a canonical working directory.
    func record(
        harnessId: AgentHarnessID,
        harnessSessionId: AgentSessionID,
        workingDirectory: URL? = nil
    ) async throws -> AgentSessionRecord? {
        try await records(harnessId: harnessId, workingDirectory: workingDirectory)
            .first { $0.harnessSessionId == harnessSessionId }
    }

    /// Removes records matching a harness session, optionally scoped to a canonical working directory.
    func remove(
        harnessId: AgentHarnessID,
        harnessSessionId: AgentSessionID,
        workingDirectory: URL? = nil
    ) async throws {
        let records = try await records(harnessId: harnessId, workingDirectory: workingDirectory)
            .filter { $0.harnessSessionId == harnessSessionId }
        for record in records {
            try await remove(conversationId: record.conversationId, harnessId: record.harnessId)
        }
    }

    /// Removes all records for a harness, optionally scoped to a canonical working directory.
    func remove(harnessId: AgentHarnessID, workingDirectory: URL? = nil) async throws {
        let records = try await records(harnessId: harnessId, workingDirectory: workingDirectory)
        for record in records {
            try await remove(conversationId: record.conversationId, harnessId: record.harnessId)
        }
    }
}

/// In-memory session store for tests and ephemeral hosts.
public actor InMemoryAgentSessionStore: AgentSessionStore {
    private var records: [SessionKey: AgentSessionRecord] = [:]

    /// Creates an in-memory session store.
    public init(records: [AgentSessionRecord] = []) {
        self.records = Dictionary(records.map { (SessionKey($0.conversationId, $0.harnessId), $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Loads the latest record for a host conversation and harness.
    public func record(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws -> AgentSessionRecord? {
        records[SessionKey(conversationId, harnessId)]
    }

    /// Saves or replaces a session record.
    public func save(_ record: AgentSessionRecord) async throws {
        records[SessionKey(record.conversationId, record.harnessId)] = record
    }

    /// Removes a session record.
    public func remove(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws {
        records[SessionKey(conversationId, harnessId)] = nil
    }

    /// Lists all session records.
    public func allRecords() async throws -> [AgentSessionRecord] {
        records.values.sorted {
            if $0.conversationId.rawValue == $1.conversationId.rawValue {
                return $0.harnessId.rawValue < $1.harnessId.rawValue
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

    /// Loads the latest record for a host conversation and harness.
    public func record(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws -> AgentSessionRecord? {
        try readRecords()[SessionKey(conversationId, harnessId)]
    }

    /// Saves or replaces a session record.
    public func save(_ record: AgentSessionRecord) async throws {
        var records = try readRecords()
        records[SessionKey(record.conversationId, record.harnessId)] = record
        try writeRecords(records)
    }

    /// Removes a session record.
    public func remove(conversationId: AgentConversationID, harnessId: AgentHarnessID) async throws {
        var records = try readRecords()
        records[SessionKey(conversationId, harnessId)] = nil
        try writeRecords(records)
    }

    /// Lists all session records.
    public func allRecords() async throws -> [AgentSessionRecord] {
        try readRecords().values.sorted {
            if $0.conversationId.rawValue == $1.conversationId.rawValue {
                return $0.harnessId.rawValue < $1.harnessId.rawValue
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
            return Dictionary(records.map { (SessionKey($0.conversationId, $0.harnessId), $0) }, uniquingKeysWith: { _, new in new })
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
                    return $0.harnessId.rawValue < $1.harnessId.rawValue
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
    let harnessId: AgentHarnessID

    init(_ conversationId: AgentConversationID, _ harnessId: AgentHarnessID) {
        self.conversationId = conversationId
        self.harnessId = harnessId
    }
}

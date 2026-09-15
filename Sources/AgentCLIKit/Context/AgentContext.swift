import Foundation

/// Snapshot of harness context-window usage.
public struct AgentContextWindowSnapshot: Codable, Equatable, Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Harness identifier.
    public let harnessId: AgentHarnessID
    /// Input tokens currently in context.
    public let usedTokens: Int
    /// Maximum harness context tokens when known.
    public let maximumTokens: Int?
    /// Snapshot date.
    public let measuredAt: Date

    /// Fraction of the context window currently used.
    public var usageFraction: Double? {
        guard let maximumTokens, maximumTokens > 0 else {
            return nil
        }
        return Double(usedTokens) / Double(maximumTokens)
    }

    /// Creates a context-window snapshot.
    public init(
        conversationId: AgentConversationID,
        harnessId: AgentHarnessID,
        usedTokens: Int,
        maximumTokens: Int?,
        measuredAt: Date = Date()
    ) {
        self.conversationId = conversationId
        self.harnessId = harnessId
        self.usedTokens = usedTokens
        self.maximumTokens = maximumTokens
        self.measuredAt = measuredAt
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case conversationId
        case harnessId = "providerId"
        case usedTokens
        case maximumTokens
        case measuredAt
    }
}

/// Cache for the latest context-window snapshot per conversation and harness.
public actor AgentContextWindowCache {
    private var snapshots: [ContextKey: AgentContextWindowSnapshot] = [:]

    /// Creates a context-window cache.
    public init() {}

    /// Stores the latest snapshot.
    public func save(_ snapshot: AgentContextWindowSnapshot) {
        snapshots[ContextKey(snapshot.conversationId, snapshot.harnessId)] = snapshot
    }

    /// Loads the latest snapshot.
    public func snapshot(conversationId: AgentConversationID, harnessId: AgentHarnessID) -> AgentContextWindowSnapshot? {
        snapshots[ContextKey(conversationId, harnessId)]
    }

    /// Removes the latest snapshot.
    public func remove(conversationId: AgentConversationID, harnessId: AgentHarnessID) {
        snapshots[ContextKey(conversationId, harnessId)] = nil
    }
}

/// Cached harness model context-window size.
public struct AgentModelContextWindowEntry: Codable, Equatable, Sendable {
    /// Model context window size.
    public let contextWindowSize: Int
    /// Last update date.
    public let updatedAt: Date

    /// Creates a model context-window cache entry.
    public init(contextWindowSize: Int, updatedAt: Date = Date()) {
        self.contextWindowSize = contextWindowSize
        self.updatedAt = updatedAt
    }
}

/// JSON-backed cache for context-window sizes keyed by harness and model.
public actor JSONAgentModelContextWindowCache {
    private let fileURL: URL
    private let fileManager: FileManager
    private var entries: [String: AgentModelContextWindowEntry]?

    /// Creates a JSON-backed model context-window cache.
    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Loads a cached context-window size for a harness model.
    public func contextWindowSize(harnessId: AgentHarnessID, model: String) -> Int? {
        guard let key = Self.cacheKey(harnessId: harnessId, model: model) else {
            return nil
        }
        return loadEntries()[key]?.contextWindowSize
    }

    /// Updates cache entries for selected and harness-reported model IDs.
    public func update(
        harnessId: AgentHarnessID,
        selectedModel: String,
        reportedModelId: String? = nil,
        contextWindowSize: Int
    ) throws {
        guard contextWindowSize > 0 else {
            return
        }
        var keys = Set<String>()
        if let selectedKey = Self.cacheKey(harnessId: harnessId, model: selectedModel) {
            keys.insert(selectedKey)
        }
        if let reportedModelId,
           let reportedKey = Self.cacheKey(harnessId: harnessId, model: reportedModelId) {
            keys.insert(reportedKey)
        }
        guard !keys.isEmpty else {
            return
        }

        var currentEntries = loadEntries()
        let entry = AgentModelContextWindowEntry(contextWindowSize: contextWindowSize)
        var didChange = false
        for key in keys where currentEntries[key]?.contextWindowSize != contextWindowSize {
            currentEntries[key] = entry
            didChange = true
        }
        guard didChange else {
            return
        }

        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(currentEntries).write(to: fileURL, options: .atomic)
        entries = currentEntries
    }

    /// Builds a stable cache key for harness and model values.
    public static func cacheKey(harnessId: AgentHarnessID, model: String) -> String? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else {
            return nil
        }
        return "\(harnessId.rawValue):\(model)"
    }

    private func loadEntries() -> [String: AgentModelContextWindowEntry] {
        if let entries {
            return entries
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = [:]
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([String: AgentModelContextWindowEntry].self, from: data)) ?? [:]
        entries = decoded
        return decoded
    }
}

/// Helpers for harness-neutral context handoff prompts.
public enum AgentContextHandoffPrompt {
    /// Builds a prompt asking an agent to summarize state for a fresh session.
    public static func makeSummaryPrompt(task: String, recentTranscript: String, constraints: [String] = []) -> String {
        var sections = [
            "Summarize the current agent session so another agent can continue it.",
            "Task:\n\(task)",
            "Recent transcript:\n\(recentTranscript)"
        ]
        if !constraints.isEmpty {
            sections.append("Constraints:\n\(constraints.map { "- \($0)" }.joined(separator: "\n"))")
        }
        sections.append("Include decisions made, files changed, validation run, and remaining work.")
        return sections.joined(separator: "\n\n")
    }
}

private struct ContextKey: Hashable {
    let conversationId: AgentConversationID
    let harnessId: AgentHarnessID

    init(_ conversationId: AgentConversationID, _ harnessId: AgentHarnessID) {
        self.conversationId = conversationId
        self.harnessId = harnessId
    }
}

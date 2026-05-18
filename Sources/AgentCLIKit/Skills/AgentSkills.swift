import Foundation

/// Installed or catalog skill metadata.
public struct AgentSkill: Codable, Equatable, Identifiable, Sendable {
    /// Skill name, matching its directory name.
    public let id: String
    /// Absolute skill directory URL when installed locally.
    public let directoryURL: URL?
    /// Short skill description.
    public let description: String

    /// Creates skill metadata.
    public init(id: String, directoryURL: URL? = nil, description: String = "") {
        self.id = id
        self.directoryURL = directoryURL
        self.description = description
    }
}

/// Error thrown by skill services.
public enum AgentSkillError: Error, Equatable, Sendable, LocalizedError {
    /// Skill name contains unsupported characters.
    case invalidName(String)
    /// A catalog backend could not find a requested skill.
    case notFound(String)

    /// Human-readable error description.
    public var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            "Invalid skill name '\(name)'."
        case let .notFound(name):
            "Skill '\(name)' was not found."
        }
    }
}

/// Scanner for installed skill directories.
public struct AgentSkillScanner {
    private let fileManager: FileManager

    /// Creates a skill scanner.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Scans direct child directories that contain a `SKILL.md` file.
    public func scan(directoryURL: URL) throws -> [AgentSkill] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.compactMap { url in
            guard try isDirectory(url), fileManager.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else {
                return nil
            }
            let name = url.lastPathComponent
            try AgentSkillValidator.validateName(name)
            return AgentSkill(id: name, directoryURL: url, description: try readDescription(skillFileURL: url.appendingPathComponent("SKILL.md")))
        }.sorted { $0.id < $1.id }
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }

    private func readDescription(skillFileURL: URL) throws -> String {
        let contents = try String(contentsOf: skillFileURL, encoding: .utf8)
        return contents
            .split(separator: "\n")
            .first { $0.hasPrefix("description:") }
            .map { String($0.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// Validator for portable skill names.
public enum AgentSkillValidator {
    /// Validates a skill directory name.
    public static func validateName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AgentSkillError.invalidName(name)
        }
    }
}

/// Catalog backend that can search for installable skills.
public protocol AgentSkillCatalogBackend: Sendable {
    /// Searches for skills matching a query.
    func search(query: String) async throws -> [AgentSkill]
    /// Loads one skill by name.
    func skill(named name: String) async throws -> AgentSkill?
}

/// In-memory catalog backend useful for tests and static catalogs.
public struct InMemoryAgentSkillCatalogBackend: AgentSkillCatalogBackend {
    private let skills: [AgentSkill]

    /// Creates an in-memory catalog backend.
    public init(skills: [AgentSkill]) {
        self.skills = skills
    }

    /// Searches skill names and descriptions case-insensitively.
    public func search(query: String) async throws -> [AgentSkill] {
        let lowercasedQuery = query.lowercased()
        return skills.filter {
            $0.id.lowercased().contains(lowercasedQuery) || $0.description.lowercased().contains(lowercasedQuery)
        }
    }

    /// Loads one skill by name.
    public func skill(named name: String) async throws -> AgentSkill? {
        skills.first { $0.id == name }
    }
}

/// Service for installed skill scanning and catalog-backed sync.
public struct AgentSkillService {
    private let scanner: AgentSkillScanner
    private let catalog: any AgentSkillCatalogBackend
    private let fileManager: FileManager

    /// Creates a skill service.
    public init(
        scanner: AgentSkillScanner = AgentSkillScanner(),
        catalog: any AgentSkillCatalogBackend,
        fileManager: FileManager = .default
    ) {
        self.scanner = scanner
        self.catalog = catalog
        self.fileManager = fileManager
    }

    /// Lists installed skills.
    public func installedSkills(directoryURL: URL) throws -> [AgentSkill] {
        try scanner.scan(directoryURL: directoryURL)
    }

    /// Searches the configured catalog backend.
    public func searchCatalog(query: String) async throws -> [AgentSkill] {
        try await catalog.search(query: query)
    }

    /// Installs or updates a catalog skill into a local skills directory.
    public func syncSkill(named name: String, into directoryURL: URL) async throws -> AgentSkill {
        try AgentSkillValidator.validateName(name)
        guard let catalogSkill = try await catalog.skill(named: name) else {
            throw AgentSkillError.notFound(name)
        }
        // Catalog backends are pluggable, so keep the install target tied to the validated requested name.
        try AgentSkillValidator.validateName(catalogSkill.id)
        guard catalogSkill.id == name else {
            throw AgentSkillError.notFound(name)
        }
        let target = directoryURL.appendingPathComponent(name, isDirectory: true)
        if let source = catalogSkill.directoryURL {
            let standardizedSource = source.standardizedFileURL
            let standardizedTarget = target.standardizedFileURL
            if standardizedSource.path == standardizedTarget.path {
                return AgentSkill(id: catalogSkill.id, directoryURL: target, description: catalogSkill.description)
            }
            // A catalog can point at an already-installed skill; only remove the target after proving it is distinct.
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
            return AgentSkill(id: catalogSkill.id, directoryURL: target, description: catalogSkill.description)
        }

        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let skillFile = target.appendingPathComponent("SKILL.md")
        let contents = """
        ---
        name: \(catalogSkill.id)
        description: \(catalogSkill.description)
        ---

        # \(catalogSkill.id)
        """
        try contents.write(to: skillFile, atomically: true, encoding: .utf8)
        return AgentSkill(id: catalogSkill.id, directoryURL: target, description: catalogSkill.description)
    }
}

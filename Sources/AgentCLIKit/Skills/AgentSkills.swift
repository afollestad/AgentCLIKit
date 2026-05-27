import Foundation

/// Installed or catalog skill metadata.
public struct AgentSkill: Codable, Equatable, Identifiable, Sendable {
    /// Skill name, matching its directory name.
    public let id: String
    /// Display name from skill frontmatter, defaulting to `id`.
    public let name: String
    /// Absolute skill directory URL when installed locally.
    public let directoryURL: URL?
    /// Short skill description.
    public let description: String
    /// Optional argument hint advertised by the skill.
    public let argumentHint: String?
    /// Optional skill version.
    public let version: String?

    /// Creates skill metadata.
    public init(
        id: String,
        name: String? = nil,
        directoryURL: URL? = nil,
        description: String = "",
        argumentHint: String? = nil,
        version: String? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.directoryURL = directoryURL
        self.description = description
        self.argumentHint = argumentHint
        self.version = version
    }

    /// Decodes skill metadata, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        self.directoryURL = try container.decodeIfPresent(URL.self, forKey: .directoryURL)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.argumentHint = try container.decodeIfPresent(String.self, forKey: .argumentHint)
        self.version = try container.decodeIfPresent(String.self, forKey: .version)
    }
}

/// Parsed metadata from a skill markdown file.
public struct AgentSkillFrontmatter: Codable, Equatable, Sendable {
    /// Skill display name.
    public let name: String?
    /// Skill description.
    public let description: String?
    /// Optional argument hint.
    public let argumentHint: String?
    /// Optional skill version.
    public let version: String?

    /// Creates parsed skill metadata.
    public init(name: String? = nil, description: String? = nil, argumentHint: String? = nil, version: String? = nil) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.version = version
    }
}

/// Loaded skill markdown and optional source URLs.
public struct AgentSkillMarkdownDocument: Equatable, Sendable {
    /// Raw markdown content.
    public let markdown: String
    /// Base URL for resolving relative local or remote references.
    public let baseURL: URL?
    /// Browser URL for the source document when known.
    public let browserURL: URL?

    /// Creates a skill markdown document.
    public init(markdown: String, baseURL: URL? = nil, browserURL: URL? = nil) {
        self.markdown = markdown
        self.baseURL = baseURL
        self.browserURL = browserURL
    }
}

/// Parser for portable skill markdown frontmatter.
public enum AgentSkillMarkdownParser {
    /// Parses YAML-style frontmatter from a skill markdown document.
    public static func frontmatter(from content: String) -> AgentSkillFrontmatter {
        guard let sections = frontmatterSections(in: content) else {
            return AgentSkillFrontmatter()
        }
        return AgentSkillFrontmatter(
            name: yamlValue(from: sections.yaml, key: "name"),
            description: yamlValue(from: sections.yaml, key: "description"),
            argumentHint: yamlValue(from: sections.yaml, key: "argument-hint") ?? yamlValue(from: sections.yaml, key: "argumentHint"),
            version: yamlValue(from: sections.yaml, key: "version")
        )
    }

    /// Returns markdown with leading frontmatter removed.
    public static func body(from content: String) -> String {
        guard let sections = frontmatterSections(in: content) else {
            return content
        }
        return String(sections.body.drop(while: \.isNewline))
    }

    private static func frontmatterSections(in content: String) -> (yaml: String, body: Substring)? {
        guard content.hasPrefix("---") else {
            return nil
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return nil
        }
        let yaml = lines[1..<closingIndex].joined(separator: "\n")
        let bodyStart = lines.index(after: closingIndex)
        let body = lines[bodyStart...].joined(separator: "\n")
        return (yaml, Substring(body))
    }

    private static func yamlValue(from yaml: String, key: String) -> String? {
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(key):") else {
                continue
            }
            let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let unquotedValue = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquotedValue.isEmpty ? nil : unquotedValue
        }
        return nil
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
            let frontmatter = try readFrontmatter(skillFileURL: url.appendingPathComponent("SKILL.md"))
            return AgentSkill(
                id: name,
                name: frontmatter.name,
                directoryURL: url,
                description: frontmatter.description ?? "",
                argumentHint: frontmatter.argumentHint,
                version: frontmatter.version
            )
        }.sorted { $0.id < $1.id }
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }

    private func readFrontmatter(skillFileURL: URL) throws -> AgentSkillFrontmatter {
        let contents = try String(contentsOf: skillFileURL, encoding: .utf8)
        return AgentSkillMarkdownParser.frontmatter(from: contents)
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
        name: \(catalogSkill.name)
        description: \(catalogSkill.description)
        ---

        # \(catalogSkill.id)
        """
        try contents.write(to: skillFile, atomically: true, encoding: .utf8)
        return AgentSkill(
            id: catalogSkill.id,
            name: catalogSkill.name,
            directoryURL: target,
            description: catalogSkill.description,
            argumentHint: catalogSkill.argumentHint,
            version: catalogSkill.version
        )
    }
}

import XCTest

@testable import AgentCLIKit

final class AgentSkillTests: XCTestCase {
    func testScannerFindsInstalledSkillsAndDescriptions() throws {
        let directory = try makeTemporaryDirectory()
        let skillDirectory = directory.appendingPathComponent("self-review", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: Self Review
        description: Review current changes
        argument-hint: [focus]
        version: 1.2.3
        ---
        """.write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = try AgentSkillScanner().scan(directoryURL: directory)

        XCTAssertEqual(skills.map(\.id), ["self-review"])
        XCTAssertEqual(skills.map(\.name), ["Self Review"])
        XCTAssertEqual(skills.map(\.description), ["Review current changes"])
        XCTAssertEqual(skills.map(\.argumentHint), ["[focus]"])
        XCTAssertEqual(skills.map(\.version), ["1.2.3"])
        XCTAssertEqual(skills.first?.directoryURL?.lastPathComponent, skillDirectory.lastPathComponent)
    }

    func testSkillMarkdownParserRemovesFrontmatterAndHandlesQuotedValues() {
        let markdown = """
        ---
        name: "Release"
        description: 'Ship a release'
        argumentHint: version
        ---

        # Body
        """

        let frontmatter = AgentSkillMarkdownParser.frontmatter(from: markdown)
        let body = AgentSkillMarkdownParser.body(from: markdown)

        XCTAssertEqual(frontmatter.name, "Release")
        XCTAssertEqual(frontmatter.description, "Ship a release")
        XCTAssertEqual(frontmatter.argumentHint, "version")
        XCTAssertEqual(body, "# Body")
    }

    func testSkillDecodesLegacyMetadataDefaults() throws {
        let data = Data(#"{"id":"self-review","description":"Review changes"}"#.utf8)

        let skill = try JSONDecoder().decode(AgentSkill.self, from: data)

        XCTAssertEqual(skill.id, "self-review")
        XCTAssertEqual(skill.name, "self-review")
        XCTAssertEqual(skill.description, "Review changes")
        XCTAssertNil(skill.argumentHint)
        XCTAssertNil(skill.version)
    }

    func testScannerRejectsInvalidSkillNames() throws {
        let directory = try makeTemporaryDirectory()
        let skillDirectory = directory.appendingPathComponent("bad name", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "# Bad".write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AgentSkillScanner().scan(directoryURL: directory)) { error in
            XCTAssertEqual(error as? AgentSkillError, .invalidName("bad name"))
        }
    }

    func testCatalogSearchAndSyncSkill() async throws {
        let installDirectory = try makeTemporaryDirectory()
        let catalog = InMemoryAgentSkillCatalogBackend(skills: [
            AgentSkill(id: "create-release", name: "Create Release", description: "Create a release")
        ])
        let service = AgentSkillService(catalog: catalog)

        let searchResults = try await service.searchCatalog(query: "release")
        XCTAssertEqual(searchResults.map(\.id), ["create-release"])

        let installed = try await service.syncSkill(named: "create-release", into: installDirectory)
        XCTAssertEqual(installed.id, "create-release")
        XCTAssertEqual(installed.name, "Create Release")

        let installedSkills = try service.installedSkills(directoryURL: installDirectory)
        XCTAssertEqual(installedSkills.map(\.id), ["create-release"])
    }

    func testSyncCopiesCatalogSkillDirectoryWhenAvailable() async throws {
        let catalogDirectory = try makeTemporaryDirectory().appendingPathComponent("source-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: source-skill
        description: Source backed
        ---
        """.write(to: catalogDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "helper".write(to: catalogDirectory.appendingPathComponent("helper.txt"), atomically: true, encoding: .utf8)
        let installDirectory = try makeTemporaryDirectory()
        let catalog = InMemoryAgentSkillCatalogBackend(skills: [
            AgentSkill(id: "source-skill", directoryURL: catalogDirectory, description: "Source backed")
        ])
        let service = AgentSkillService(catalog: catalog)

        let installed = try await service.syncSkill(named: "source-skill", into: installDirectory)

        XCTAssertEqual(installed.id, "source-skill")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.directoryURL?.appendingPathComponent("helper.txt").path ?? ""))
    }

    func testSyncLeavesSourceBackedSkillAloneWhenAlreadyInstalled() async throws {
        let installDirectory = try makeTemporaryDirectory()
        let skillDirectory = installDirectory.appendingPathComponent("source-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: source-skill
        description: Source backed
        ---
        """.write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "helper".write(to: skillDirectory.appendingPathComponent("helper.txt"), atomically: true, encoding: .utf8)
        let catalog = InMemoryAgentSkillCatalogBackend(skills: [
            AgentSkill(id: "source-skill", directoryURL: skillDirectory, description: "Source backed")
        ])
        let service = AgentSkillService(catalog: catalog)

        let installed = try await service.syncSkill(named: "source-skill", into: installDirectory)

        XCTAssertEqual(installed.directoryURL?.path, skillDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillDirectory.appendingPathComponent("helper.txt").path))
    }

    func testSyncRejectsInvalidSkillName() async throws {
        let service = AgentSkillService(catalog: InMemoryAgentSkillCatalogBackend(skills: []))

        do {
            _ = try await service.syncSkill(named: "bad name", into: try makeTemporaryDirectory())
            XCTFail("Expected invalid skill name.")
        } catch {
            XCTAssertEqual(error as? AgentSkillError, .invalidName("bad name"))
        }
    }

    func testSyncRejectsInvalidCatalogSkillName() async throws {
        let service = AgentSkillService(catalog: SingleSkillCatalogBackend(skill: AgentSkill(id: "bad name")))

        do {
            _ = try await service.syncSkill(named: "requested", into: try makeTemporaryDirectory())
            XCTFail("Expected invalid catalog skill name.")
        } catch {
            XCTAssertEqual(error as? AgentSkillError, .invalidName("bad name"))
        }
    }

    func testSyncRejectsMismatchedCatalogSkillName() async throws {
        let service = AgentSkillService(catalog: SingleSkillCatalogBackend(skill: AgentSkill(id: "other-skill")))

        do {
            _ = try await service.syncSkill(named: "requested", into: try makeTemporaryDirectory())
            XCTFail("Expected mismatched catalog skill name.")
        } catch {
            XCTAssertEqual(error as? AgentSkillError, .notFound("requested"))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct SingleSkillCatalogBackend: AgentSkillCatalogBackend {
    let skill: AgentSkill

    func search(query: String) async throws -> [AgentSkill] {
        [skill]
    }

    func skill(named name: String) async throws -> AgentSkill? {
        skill
    }
}

import XCTest

@testable import AgentCLIKit

final class OpenCodeConfigTests: XCTestCase {
    func testReadsJSONCWithoutWritingAndPreservesUnknownSettingsOnMCPChange() async throws {
        let file = try configFile()
        let text = """
        {
          // Model and permission settings belong to the user.
          "model": "alpha/model",
          "permission": { "bash": "ask", },
          "mcp": {
            "remote": {"type":"remote", "url":"https://example.com/mcp", "oauth":false, "futureOption":true},
          },
          "instructions": ["https://example.com/guide//path"],
        }
        """
        try text.write(to: file, atomically: true, encoding: .utf8)
        let store = OpenCodeConfigStore(fileURL: file)
        var servers = try await store.readMCPServers()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        XCTAssertEqual(servers["remote"]?.additionalFields["futureOption"], .bool(true))
        servers["local"] = OpenCodeMCPServerConfig(type: "local", command: ["node", "server.js"], environment: ["MODE": "test"])
        try await store.writeMCPServers(servers)
        let output = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(output.contains("// Model and permission settings belong to the user."))
        XCTAssertTrue(output.contains("\"permission\": { \"bash\": \"ask\", }"))
        XCTAssertTrue(output.contains("\"instructions\": [\"https://example.com/guide//path\"]"))
        let reloaded = try await store.readMCPServers()
        XCTAssertEqual(reloaded["remote"], servers["remote"])
        XCTAssertEqual(reloaded["local"], servers["local"])
    }

    func testAddingMCPMapHandlesExistingTrailingCommaAndComments() async throws {
        let file = try configFile()
        try "{\"model\":\"alpha/model\", // keep this comment\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let store = OpenCodeConfigStore(fileURL: file)
        try await store.setMCPServer(OpenCodeMCPServerConfig(type: "remote", url: "https://example.com/mcp"), id: "remote")
        let servers = try await store.readMCPServers()
        XCTAssertEqual(servers["remote"]?.url, "https://example.com/mcp")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("// keep this comment"))
    }

    func testMCPServiceRetainsOtherServersAndUnknownEntryFields() async throws {
        let file = try configFile()
        let store = OpenCodeConfigStore(fileURL: file)
        let service = OpenCodeMCPService(store: store)
        try await store.writeMCPServers([
            "first": OpenCodeMCPServerConfig(type: "local", command: ["old"], additionalFields: ["future": .number(4)]),
            "second": OpenCodeMCPServerConfig(type: "remote", url: "https://example.com", oauth: .object(["clientId": .string("id")]))
        ])
        try await service.setServer(OpenCodeMCPServerConfig(type: "local", command: ["new"]), id: "first")
        let changed = try await service.listServers()
        XCTAssertEqual(changed["first"]?.additionalFields["future"], .number(4))
        XCTAssertEqual(changed["second"]?.oauth, .object(["clientId": .string("id")]))
        try await service.removeServer(id: "first")
        let remaining = try await service.listServers()
        XCTAssertEqual(Array(remaining.keys), ["second"])
    }

    func testMissingConfigReadDoesNotCreateFileAndInvalidConfigIsNotOverwritten() async throws {
        let file = try configFile()
        let store = OpenCodeConfigStore(fileURL: file)
        let initial = try await store.readMCPServers()
        XCTAssertTrue(initial.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let invalid = "{ \"model\": \"unfinished\""
        try invalid.write(to: file, atomically: true, encoding: .utf8)
        do {
            try await store.writeMCPServers([:])
            XCTFail("Invalid user configuration must not be overwritten")
        } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), invalid)
    }

    func testNativeConfigSelectionPrefersJSONCButFindsLegacyGlobalConfig() throws {
        let file = try configFile()
        let xdg = file.deletingLastPathComponent()
        let directory = xdg.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ["XDG_CONFIG_HOME": xdg.path]
        XCTAssertEqual(OpenCodeConfigStore.configFileURL(environment: environment), directory.appendingPathComponent("opencode.jsonc"))
        for name in ["config.json", "opencode.json", "opencode.jsonc"] {
            let expected = directory.appendingPathComponent(name)
            try "{}".write(to: expected, atomically: true, encoding: .utf8)
            XCTAssertEqual(OpenCodeConfigStore.configFileURL(environment: environment), expected)
        }
    }

    private func configFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("opencode.jsonc")
    }
}

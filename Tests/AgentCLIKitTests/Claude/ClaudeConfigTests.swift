import XCTest

@testable import AgentCLIKit

final class ClaudeConfigTests: XCTestCase {
    func testConfigStoreTrustsProjectAndPersistsMCP() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        let store = ClaudeConfigStore(fileURL: fileURL)
        let projectURL = URL(fileURLWithPath: "/tmp/project")
        let server = AgentMCPServer(id: "server", name: "Server", command: "server")

        try await store.trustProject(projectURL)
        try await store.saveMCPConfig(AgentMCPConfig(servers: [server]))

        let config = try await store.load()
        XCTAssertEqual(config.trustedProjects, ["/tmp/project"])
        XCTAssertEqual(config.mcpServers, [server])

        let root = try readJSONObject(fileURL: fileURL)
        let projects = root["projects"] as? [String: Any]
        let trustedProject = projects?["/tmp/project"] as? [String: Any]
        let mcpServers = root["mcpServers"] as? [String: Any]
        let persistedServer = mcpServers?["server"] as? [String: Any]
        XCTAssertEqual(trustedProject?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(trustedProject?["hasCompletedProjectOnboarding"] as? Bool, true)
        XCTAssertEqual(persistedServer?["command"] as? String, "server")
    }

    func testConfigStorePreservesUnrelatedClaudeSettings() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "projects": {
            "/tmp/project": {
              "customSetting": "keep"
            }
          },
          "theme": "dark"
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ClaudeConfigStore(fileURL: fileURL)

        try await store.trustProject(URL(fileURLWithPath: "/tmp/project"))

        let root = try readJSONObject(fileURL: fileURL)
        let project = (root["projects"] as? [String: Any])?["/tmp/project"] as? [String: Any]
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual(project?["customSetting"] as? String, "keep")
        XCTAssertEqual(project?["hasTrustDialogAccepted"] as? Bool, true)
    }

    func testConfigStorePublishesTrustedProjectSnapshots() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        let store = ClaudeConfigStore(fileURL: fileURL)
        let stream = await store.snapshots()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        try await store.trustProject(URL(fileURLWithPath: "/tmp/project"))
        let updated = await iterator.next()
        let isTrusted = try await store.isTrustedProject(URL(fileURLWithPath: "/tmp/project"))

        XCTAssertEqual(initial?.revision, 0)
        XCTAssertEqual(initial?.trustedProjectPaths, [])
        XCTAssertEqual(updated?.revision, 1)
        XCTAssertTrue(isTrusted)
        XCTAssertEqual(store.cachedSnapshot(), updated)
    }

    func testConfigStoreRefreshesSnapshotFromExternalFileChanges() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "projects": {
            "/tmp/project": {
              "hasTrustDialogAccepted": true,
              "hasCompletedProjectOnboarding": true
            }
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ClaudeConfigStore(fileURL: fileURL)

        try """
        {
          "projects": {
            "/tmp/other": {
              "hasTrustDialogAccepted": true,
              "hasCompletedProjectOnboarding": true
            }
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let snapshot = try await store.currentSnapshot()

        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertFalse(snapshot.isTrustedProject(path: "/tmp/project"))
        XCTAssertTrue(snapshot.isTrustedProject(path: "/tmp/other"))
    }

    func testConfigStorePublishesSnapshotForObservedExternalFileChanges() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = ClaudeConfigStore(fileURL: fileURL)
        let stream = await store.snapshots()
        let didReceiveUpdate = expectation(description: "Received observed Claude config update")

        Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            let updated = await iterator.next()
            XCTAssertEqual(updated?.revision, 1)
            XCTAssertTrue(updated?.isTrustedProject(path: "/tmp/observed") == true)
            didReceiveUpdate.fulfill()
        }

        try """
        {
          "projects": {
            "/tmp/observed": {
              "hasTrustDialogAccepted": true,
              "hasCompletedProjectOnboarding": true
            }
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [didReceiveUpdate], timeout: 2)
    }

    func testProviderSetupTrustsClaudeProject() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        let setup: any AgentProviderSetup = ClaudeProviderSetup(configFileURL: fileURL)
        let projectURL = URL(fileURLWithPath: "/tmp/project")

        XCTAssertEqual(setup.cachedProjectTrustStatus(for: projectURL), .notTrusted)
        let statusBeforeTrust = try await setup.projectTrustStatus(for: projectURL)
        XCTAssertEqual(statusBeforeTrust, .notTrusted)

        try await setup.trustProject(at: projectURL)

        let root = try readJSONObject(fileURL: fileURL)
        let project = (root["projects"] as? [String: Any])?["/tmp/project"] as? [String: Any]
        XCTAssertEqual(setup.providerId, .claude)
        XCTAssertEqual(project?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(project?["hasCompletedProjectOnboarding"] as? Bool, true)
        XCTAssertEqual(setup.cachedProjectTrustStatus(for: projectURL), .trusted)
        let statusAfterTrust = try await setup.projectTrustStatus(for: projectURL)
        XCTAssertEqual(statusAfterTrust, .trusted)
    }

    func testConfigStoreHomeDirectoryInitializerUsesGlobalClaudeConfigPath() async throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClaudeConfigStore(homeDirectoryURL: homeDirectory)
        let projectURL = URL(fileURLWithPath: "/tmp/project")

        try await store.trustProject(projectURL)

        let root = try readJSONObject(fileURL: homeDirectory.appendingPathComponent(".claude.json"))
        let project = (root["projects"] as? [String: Any])?["/tmp/project"] as? [String: Any]
        XCTAssertEqual(project?["hasTrustDialogAccepted"] as? Bool, true)
    }

    func testConfigStoreSavePreservesExistingProjectEntries() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "projects": {
            "/tmp/managed": {
              "customSetting": "keep-managed"
            },
            "/tmp/other": {
              "customSetting": "keep-other"
            }
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ClaudeConfigStore(fileURL: fileURL)

        try await store.save(ClaudeConfig(trustedProjects: ["/tmp/managed"]))

        let root = try readJSONObject(fileURL: fileURL)
        let projects = root["projects"] as? [String: Any]
        let managedProject = projects?["/tmp/managed"] as? [String: Any]
        let otherProject = projects?["/tmp/other"] as? [String: Any]
        XCTAssertEqual(managedProject?["customSetting"] as? String, "keep-managed")
        XCTAssertEqual(managedProject?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(managedProject?["hasCompletedProjectOnboarding"] as? Bool, true)
        XCTAssertEqual(otherProject?["customSetting"] as? String, "keep-other")
    }

    func testConfigStoreReadsAndWritesClaudeNativeMCPServerMap() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        let store = ClaudeConfigStore(fileURL: fileURL)
        let servers = [
            "http": ClaudeMCPServerConfig(url: "https://example.com/mcp", headers: ["Authorization": "Bearer token"]),
            "stdio": ClaudeMCPServerConfig(command: "node", args: ["server.js"], env: ["A": "B"])
        ]

        try await store.writeMCPServers(servers)
        let reloaded = try await store.readMCPServers()
        let root = try readJSONObject(fileURL: fileURL)
        let mcpServers = root["mcpServers"] as? [String: Any]
        let httpServer = mcpServers?["http"] as? [String: Any]

        XCTAssertEqual(reloaded, servers)
        XCTAssertEqual(httpServer?["url"] as? String, "https://example.com/mcp")
        XCTAssertEqual((httpServer?["headers"] as? [String: String])?["Authorization"], "Bearer token")
    }

    func testConfigStoreRejectsNonObjectRoot() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[]".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ClaudeConfigStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected invalid Claude config root.")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .invalidInput("Claude config root must be a JSON object."))
        }
    }

    func testMCPBridgeRoundTripsClaudeConfigShape() throws {
        let bridge = ClaudeMCPBridge()
        let config = AgentMCPConfig(servers: [
            AgentMCPServer(id: "server", name: "Server", command: "node", arguments: ["server.js"], environment: ["A": "B"])
        ])

        let data = try bridge.encode(config)
        let decoded = try bridge.decode(data)

        XCTAssertEqual(decoded, config)
    }

    func testMCPBridgeHandlesDuplicateServerIDsWithoutCrashing() throws {
        let bridge = ClaudeMCPBridge()
        let config = AgentMCPConfig(servers: [
            AgentMCPServer(id: "server", name: "Old", command: "old"),
            AgentMCPServer(id: "server", name: "New", command: "new")
        ])

        let data = try bridge.encode(config)
        let decoded = try bridge.decode(data)

        XCTAssertEqual(decoded.servers, [
            AgentMCPServer(id: "server", name: "New", command: "new")
        ])
    }

    private func readJSONObject(fileURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

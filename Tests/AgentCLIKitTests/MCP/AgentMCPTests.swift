import XCTest

@testable import AgentCLIKit

final class AgentMCPTests: XCTestCase {
    func testJSONConfigStoreRoundTripsMCPServers() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("mcp.json")
        let store = JSONFileAgentMCPConfigStore(fileURL: fileURL)
        let server = AgentMCPServer(
            id: "filesystem",
            name: "Filesystem",
            command: "npx",
            arguments: ["@modelcontextprotocol/server-filesystem"],
            environment: ["ROOT": "/tmp"]
        )

        try await store.save(AgentMCPConfig(servers: [server]))

        let reloaded = try await JSONFileAgentMCPConfigStore(fileURL: fileURL).load()
        XCTAssertEqual(reloaded.servers, [server])
    }

    func testMCPServiceAddsRemovesAndListsServers() async throws {
        let store = InMemoryMCPConfigStore()
        let service = AgentMCPService(store: store)
        let server = AgentMCPServer(id: "a", name: "A", command: "server")

        try await service.addServer(server)
        let added = try await service.listServers()
        XCTAssertEqual(added, [server])

        try await service.removeServer(id: "a")
        let removed = try await service.listServers()
        XCTAssertEqual(removed, [])
    }

    func testJSONAdapterRoundTripsGenericConfig() throws {
        let adapter = JSONAgentMCPConfigAdapter(providerId: "provider")
        let config = AgentMCPConfig(servers: [
            AgentMCPServer(id: "server", name: "Server", command: "server")
        ])

        let data = try adapter.encode(config)
        let decoded = try adapter.decode(data)

        XCTAssertEqual(decoded, config)
    }
}

private actor InMemoryMCPConfigStore: AgentMCPConfigStore {
    private var config = AgentMCPConfig()

    func load() async throws -> AgentMCPConfig {
        config
    }

    func save(_ config: AgentMCPConfig) async throws {
        self.config = config
    }
}

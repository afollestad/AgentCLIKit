import XCTest

@testable import AgentCLIKit

extension DefaultAgentRuntimeTests {
    func testDefaultRuntimeRegistersBuiltInAdapters() async {
        let runtime = DefaultAgentRuntime()

        let adapters = await runtime.adapters

        XCTAssertEqual(adapters[.claude]?.definition.displayName, "Claude")
        XCTAssertEqual(adapters[.codex]?.definition.displayName, "Codex")
    }

    func testRuntimeAdapterSetKeepsExplicitAdapterOverride() async {
        let runtime = DefaultAgentRuntime(adapterSet: AgentProviderAdapterSet(overriding: [
            FakeProviderAdapter(command: shell("printf 'message:override\\n'"))
        ]))

        let adapters = await runtime.adapters

        XCTAssertEqual(adapters[.claude]?.definition.displayName, "Fake")
        XCTAssertEqual(adapters[.codex]?.definition.displayName, "Codex")
    }

    func testEmptyAdapterSetReportsProviderNotRegistered() async throws {
        let runtime = DefaultAgentRuntime(adapterSet: AgentProviderAdapterSet(adapters: []))

        do {
            try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
            XCTFail("Expected missing provider to fail before launch.")
        } catch let error as AgentCLIError {
            guard case let .providerNotRegistered(providerId) = error else {
                XCTFail("Expected providerNotRegistered, got \(error).")
                return
            }
            XCTAssertEqual(providerId, .claude)
        }
    }
}

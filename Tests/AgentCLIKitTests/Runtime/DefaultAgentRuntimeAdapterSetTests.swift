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
        let runtime = DefaultAgentRuntime(adapterSet: AgentHarnessAdapterSet(overriding: [
            FakeHarnessAdapter(command: shell("printf 'message:override\\n'"))
        ]))

        let adapters = await runtime.adapters

        XCTAssertEqual(adapters[.claude]?.definition.displayName, "Fake")
        XCTAssertEqual(adapters[.codex]?.definition.displayName, "Codex")
    }

    func testEmptyAdapterSetReportsHarnessNotRegistered() async throws {
        let runtime = DefaultAgentRuntime(adapterSet: AgentHarnessAdapterSet(adapters: []))

        do {
            try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
            XCTFail("Expected missing harness to fail before launch.")
        } catch let error as AgentCLIError {
            guard case let .harnessNotRegistered(harnessId) = error else {
                XCTFail("Expected harnessNotRegistered, got \(error).")
                return
            }
            XCTAssertEqual(harnessId, .claude)
        }
    }
}

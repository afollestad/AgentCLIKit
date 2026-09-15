import XCTest

@testable import AgentCLIKit

final class AgentHarnessRegistryReadinessTests: XCTestCase {
    func testReadinessUpdatesPublishInitialAndRegistrationSnapshots() async {
        let registry = AgentHarnessRegistry()
        let stream = await registry.readinessUpdates()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        await registry.register(AgentHarnessDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"]))
        let registered = await iterator.next()

        XCTAssertEqual(initial, [])
        XCTAssertEqual(registered, [
            AgentHarnessReadiness(harnessId: .claude, availability: nil, setup: .unknown, trust: .unknown)
        ])
    }
}

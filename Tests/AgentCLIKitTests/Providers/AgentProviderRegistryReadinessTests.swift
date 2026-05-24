import XCTest

@testable import AgentCLIKit

final class AgentProviderRegistryReadinessTests: XCTestCase {
    func testReadinessUpdatesPublishInitialAndRegistrationSnapshots() async {
        let registry = AgentProviderRegistry()
        let stream = await registry.readinessUpdates()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        await registry.register(AgentProviderDefinition(id: "fake", displayName: "Fake", executableNames: ["fake"]))
        let registered = await iterator.next()

        XCTAssertEqual(initial, [])
        XCTAssertEqual(registered, [
            AgentProviderReadiness(providerId: "fake", availability: nil, setup: .unknown, trust: .unknown)
        ])
    }
}

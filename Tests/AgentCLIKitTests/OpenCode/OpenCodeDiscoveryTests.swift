import XCTest

@testable import AgentCLIKit

final class OpenCodeDiscoveryTests: XCTestCase {
    func testSetupAndModelsShareReadOnlyProbeAndStopTransport() async throws {
        let transport = OpenCodeDiscoveryTestTransport(providers: openCodeProviderFixture())
        let probe = makeProbe(transport)
        let setup = OpenCodeHarnessSetup(probe: probe)
        let source = OpenCodeModelOptionSource(probe: probe)
        XCTAssertEqual(setup.cachedSetupReadiness(), .unknown)
        let readiness = await setup.setupReadiness()
        let options = await source.modelOptions(for: .opencode)
        let diagnostics = await setup.setupDiagnostics()
        let calls = await transport.calls
        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(setup.cachedSetupReadiness(), .ready)
        XCTAssertEqual(options.map(\.id), ["default", "alpha/family/model", "beta/family/model"])
        XCTAssertEqual(diagnostics, [])
        XCTAssertEqual(calls, ["start", "GET /global/health", "GET /provider", "stop"])
        XCTAssertEqual(setup.cachedProjectTrustStatus(for: URL(fileURLWithPath: "/tmp")), .notRequired)
    }

    func testUnsupportedVersionStopsBeforeProviderDiscovery() async {
        let transport = OpenCodeDiscoveryTestTransport(version: "2.0.0", providers: openCodeProviderFixture())
        let snapshot = await makeProbe(transport).refresh()
        let calls = await transport.calls
        XCTAssertEqual(snapshot.readiness, .failed)
        XCTAssertEqual(snapshot.models, [])
        XCTAssertEqual(calls, ["start", "GET /global/health", "stop"])
        XCTAssertTrue(snapshot.diagnostics.first?.contains("1.18.31") == true)
    }

    func testSetupRetryReplacesCachedUnsupportedVersionAfterUpgrade() async {
        let transport = OpenCodeDiscoveryTestTransport(version: "1.18.21", providers: openCodeProviderFixture())
        let probe = makeProbe(transport)
        let setup = OpenCodeHarnessSetup(probe: probe)
        let source = OpenCodeModelOptionSource(probe: probe)
        let initialOptions = await source.modelOptions(for: .opencode)
        XCTAssertEqual(initialOptions.map(\.id), ["default"])
        XCTAssertEqual(setup.cachedSetupReadiness(), .failed)

        await transport.setVersion("1.18.31")
        let readiness = await setup.setupReadiness()
        let refreshedOptions = await source.modelOptions(for: .opencode)
        let diagnostics = await setup.setupDiagnostics()
        let calls = await transport.calls

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(probe.cachedSnapshot().version, "1.18.31")
        XCTAssertEqual(refreshedOptions.map(\.id), ["default", "alpha/family/model", "beta/family/model"])
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(calls, ["start", "GET /global/health", "stop", "start", "GET /global/health", "GET /provider", "stop"])
    }

    func testConnectedProviderWithoutModelsRequiresSetup() async {
        let response: JSONValue = .object(["all": .array([]), "connected": .array([]), "default": .object([:])])
        let snapshot = await makeProbe(OpenCodeDiscoveryTestTransport(providers: response)).refresh()
        XCTAssertEqual(snapshot.readiness, .needsSetup)
        XCTAssertEqual(snapshot.version, "1.18.31")
        XCTAssertFalse(snapshot.diagnostics.isEmpty)
    }

    func testMalformedProviderResponseStopsTransportAndSurfacesFailure() async {
        let transport = OpenCodeDiscoveryTestTransport(providers: .object([:]))
        let snapshot = await makeProbe(transport).refresh()
        let calls = await transport.calls
        XCTAssertEqual(snapshot.readiness, .failed)
        XCTAssertEqual(calls.last, "stop")
    }

    private func makeProbe(_ transport: OpenCodeDiscoveryTestTransport) -> OpenCodeDiscoveryProbe {
        OpenCodeDiscoveryProbe(
            configuration: OpenCodeServerConfiguration(executablePath: "/test/opencode", workingDirectory: URL(fileURLWithPath: "/tmp")),
            makeTransport: { _ in transport }
        )
    }
}

private actor OpenCodeDiscoveryTestTransport: OpenCodeServerTransport {
    private var version: String
    let providers: JSONValue
    private(set) var calls: [String] = []

    init(version: String = "1.18.31", providers: JSONValue) {
        self.version = version
        self.providers = providers
    }

    func start() async throws { calls.append("start") }

    func setVersion(_ version: String) { self.version = version }

    func request(method: String, path: String, body: JSONValue?) async throws -> JSONValue {
        calls.append("\(method) \(path)")
        return path == "/global/health" ? .object(["healthy": .bool(true), "version": .string(version)]) : providers
    }

    func events() async throws -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stop() async { calls.append("stop") }
}

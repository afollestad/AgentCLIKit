import XCTest

@testable import AgentCLIKit

final class AgentHarnessDiscoveryConcurrencyTests: XCTestCase {
    func testExecutableProbesOverlapAndPreserveRegistryOrdering() async {
        let started = expectation(description: "Every version probe starts before any is released")
        started.expectedFulfillmentCount = definitions.count
        let gate = DiscoveryConcurrencyGate(started: started)
        let detector = AgentHarnessDetector(shellRunner: ConcurrentDiscoveryShell(gate: gate))
        let definitions = definitions
        let result = Task { await detector.availability(for: definitions) }

        await fulfillment(of: [started], timeout: 2)
        await gate.release()
        let availability = await result.value

        XCTAssertEqual(availability.map(\.harnessId), definitions.map(\.id))
        XCTAssertTrue(availability.allSatisfy(\.isAvailable))
        XCTAssertTrue(availability.allSatisfy { $0.versionDescription == "1.18.31" })
    }

    func testHarnessReadinessProbesOverlapWithoutMixingResults() async {
        let started = expectation(description: "Every readiness probe starts before any is released")
        started.expectedFulfillmentCount = definitions.count
        let gate = DiscoveryConcurrencyGate(started: started)
        let service = DefaultAgentHarnessDiscoveryService(
            harnessRegistry: AgentHarnessRegistry(definitions: definitions),
            executableDetector: ConcurrentDiscoveryDetector(),
            harnessSetups: definitions.map { ConcurrentDiscoverySetup(harnessId: $0.id, gate: gate) }
        )
        let result = Task { await service.harnessStatuses(projectURL: nil) }

        await fulfillment(of: [started], timeout: 2)
        await gate.release()
        let statuses = await result.value

        XCTAssertEqual(Set(statuses.keys), Set(definitions.map(\.id)))
        for definition in definitions {
            XCTAssertEqual(statuses[definition.id]?.setup, definition.id == .opencode ? .needsSetup : .ready)
            XCTAssertEqual(statuses[definition.id]?.diagnostics, [definition.id.rawValue])
        }
    }

    private var definitions: [AgentHarnessDefinition] {
        [ClaudeHarnessDefinition.definition, CodexHarnessDefinition.definition, OpenCodeHarnessDefinition.definition]
    }
}

private actor DiscoveryConcurrencyGate {
    let started: XCTestExpectation
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        started.fulfill()
        guard !isReleased else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        isReleased = true
        for continuation in continuations.reversed() { continuation.resume() }
        continuations.removeAll()
    }
}

private struct ConcurrentDiscoveryShell: ShellRunning {
    let gate: DiscoveryConcurrencyGate

    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        if command.arguments.first == "which" {
            return ShellCommandResult(exitCode: 0, stdout: "/probe/\(command.arguments.last ?? "cli")", stderr: "")
        }
        await gate.wait()
        return ShellCommandResult(exitCode: 0, stdout: "1.18.31", stderr: "")
    }
}

private struct ConcurrentDiscoveryDetector: AgentHarnessExecutableDetecting {
    func availability(for definitions: [AgentHarnessDefinition]) async -> [AgentHarnessAvailability] {
        definitions.map { AgentHarnessAvailability(harnessId: $0.id, executablePath: "/probe/\($0.id.rawValue)") }
    }
}

private struct ConcurrentDiscoverySetup: AgentHarnessSetup {
    let harnessId: AgentHarnessID
    let gate: DiscoveryConcurrencyGate

    func cachedSetupReadiness() -> AgentHarnessReadinessState { .unknown }

    func setupReadiness() async -> AgentHarnessReadinessState {
        await gate.wait()
        return harnessId == .opencode ? .needsSetup : .ready
    }

    func setupDiagnostics() async -> [String] { [harnessId.rawValue] }
    func trustProject(at projectURL: URL) async throws {}
}

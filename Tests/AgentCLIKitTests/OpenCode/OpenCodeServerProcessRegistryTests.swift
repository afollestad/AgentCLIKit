import Darwin
import Foundation
import XCTest

@testable import AgentCLIKit

final class OpenCodeServerProcessRegistryTests: XCTestCase {
    func testShutdownReapsOnlyOwnedServersAndRejectsLaterLaunches() throws {
        let registry = OpenCodeServerProcessRegistry()
        defer { registry.shutdown(grace: 0.05) }
        let foreign = Process()
        foreign.executableURL = URL(fileURLWithPath: "/bin/sleep")
        foreign.arguments = ["30"]
        let foreignExit = DispatchSemaphore(value: 0)
        foreign.terminationHandler = { _ in foreignExit.signal() }
        try foreign.run()
        defer {
            if foreign.isRunning { foreign.terminate() }
            _ = foreignExit.wait(timeout: .now() + 3)
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 30"]
        let ready = Pipe()
        child.standardOutput = ready
        let owned = try registry.launch(child)
        // The shell acknowledges its TERM handler before shutdown so this always exercises escalation.
        XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 5), Data("ready".utf8))
        let started = Date()
        registry.shutdown(grace: 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(owned.wait(until: .now()), .success)
        XCTAssertFalse(child.isRunning)
        XCTAssertTrue(foreign.isRunning)

        let late = Process()
        late.executableURL = URL(fileURLWithPath: "/bin/sleep")
        late.arguments = ["30"]
        XCTAssertThrowsError(try registry.launch(late)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(late.isRunning)
    }

    func testLaunchFailureReleasesExitObservationAndShutdownRemainsBounded() {
        let registry = OpenCodeServerProcessRegistry()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/missing-opencode-test-\(UUID().uuidString)")
        XCTAssertThrowsError(try registry.launch(child))
        let started = Date()
        registry.shutdown(grace: 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testImmediateExitIsObservedBeforeAnotherExecutorJoins() async throws {
        let registry = OpenCodeServerProcessRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let owned = try await Task.detached { try registry.launch(process) }.value
        XCTAssertEqual(owned.wait(until: .now() + 3), .success)
        await owned.stop(grace: 0.05)
        XCTAssertFalse(process.isRunning)
        registry.shutdown(grace: 0.05)
    }

    func testShutdownIncludesLaunchAlreadyInsideRegistrationGate() async throws {
        let launchStarted = expectation(description: "Launch entered registry gate")
        let shutdownStarted = expectation(description: "Shutdown competes with admitted launch")
        let releaseLaunch = DispatchSemaphore(value: 0)
        let registry = OpenCodeServerProcessRegistry { process in
            launchStarted.fulfill()
            guard releaseLaunch.wait(timeout: .now() + 3) == .success else { throw CancellationError() }
            try process.run()
        }
        defer { registry.shutdown(grace: 0.05) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let launch = Task.detached { try registry.launch(process) }
        await fulfillment(of: [launchStarted], timeout: 2)
        let shutdown = Task.detached {
            shutdownStarted.fulfill()
            registry.shutdown(grace: 0.05)
        }
        await fulfillment(of: [shutdownStarted], timeout: 2)
        releaseLaunch.signal()
        let owned = try await launch.value
        await shutdown.value
        XCTAssertEqual(owned.wait(until: .now()), .success)
        XCTAssertFalse(process.isRunning)
    }
}

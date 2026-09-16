import XCTest

@testable import AgentCLIKit

final class OpenCodeRuntimeCompatibilityTests: XCTestCase {
    func testFreshBootstrapUsesAskAndNativeSessionMetadata() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        let launch = try await fixture.launch()
        let stream = await fixture.stream()
        await fixture.stop()
        var events: [AgentEvent] = []
        for await item in stream { events.append(item.event) }
        let calls = await fixture.transport.requests
        XCTAssertEqual(launch.harnessSessionId, "ses_current")
        XCTAssertEqual(launch.sessionContinuity, .fresh)
        XCTAssertTrue(launch.sendsInitialPromptOverStdin)
        let create = try XCTUnwrap(calls.first { $0.path == "/session" && $0.method == "POST" })
        XCTAssertEqual(create.body?[oc: "permission"]?.ocArray?.first?[oc: "action"], .string("ask"))
        XCTAssertTrue(events.contains { if case let .sessionMetadata(value) = $0 { return value.harnessSessionId == "ses_current" }; return false })
        XCTAssertTrue(events.contains { if case let .sessionMetadata(value) = $0 { return value.name == "Native session" }; return false })
        XCTAssertFalse(calls.contains { $0.path.hasSuffix("/prompt_async") })
    }

    func testBootstrapKeepsSessionIdentityWithoutTimestampPlaceholderTitle() async throws {
        for prefix in ["New session", "Child session"] {
            let fixture = OpenCodeCompatibilityFixture()
            await fixture.transport.respondToNextRequest(path: "/session", response: .object([
                "id": .string("ses_current"), "title": .string("\(prefix) - 2026-09-16T00:07:08.123Z")
            ]))
            let launch = try await fixture.launch()
            let stream = await fixture.stream()
            await fixture.stop()
            var metadata: [AgentSessionMetadataEvent] = []
            for await item in stream {
                if case let .sessionMetadata(value) = item.event { metadata.append(value) }
            }

            XCTAssertEqual(launch.harnessSessionId, "ses_current")
            let title = try XCTUnwrap(metadata.first)
            XCTAssertEqual(title.harnessSessionId, "ses_current")
            XCTAssertNil(title.name)
            XCTAssertEqual(title.metadata["opencode_session_id"], .string("ses_current"))
        }
    }

    func testResumeDoesNotCreateSessionOrReplayHistoryAndResetsConfiguredPermissions() async throws {
        let config = AgentSpawnConfig(harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory, permissionMode: "configured")
        let fixture = OpenCodeCompatibilityFixture(config: config, resumed: OpenCodeCompatibilityFixture.record(id: "ses_saved"))
        let launch = try await fixture.launch()
        await fixture.stop()
        let requests = await fixture.transport.requests
        XCTAssertEqual(launch.harnessSessionId, "ses_saved")
        XCTAssertEqual(launch.sessionContinuity, .resumed)
        XCTAssertTrue(requests.contains { $0.method == "GET" && $0.path == "/session/ses_saved" })
        XCTAssertFalse(requests.contains { $0.method == "POST" })
        XCTAssertEqual(requests.first { $0.method == "PATCH" }?.body, .object(["permission": .array([])]))
    }

    func testCrossDirectoryForkMovesOnlyNewSessionWithoutCopyingWorkspaceChanges() async throws {
        let transport = OpenCodeCompatibilityTransport(directory: "/different/source")
        let config = AgentSpawnConfig(
            harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory,
            sessionFork: AgentSessionForkRequest(sourceSessionId: "ses_source", sourceWorkingDirectory: URL(fileURLWithPath: "/different/source"))
        )
        let fixture = OpenCodeCompatibilityFixture(transport: transport, config: config)
        let launch = try await fixture.launch()
        await fixture.stop()
        let requests = await transport.requests
        XCTAssertEqual(launch.sessionContinuity, .forked)
        XCTAssertEqual(launch.harnessSessionId, "ses_fork")
        let mutations = requests.filter { $0.method == "POST" }
        XCTAssertEqual(mutations.map(\.path), ["/session/ses_source/fork", "/experimental/control-plane/move-session"])
        XCTAssertEqual(mutations.last?.body, .object([
            "sessionID": .string("ses_fork"), "destination": .object(["directory": .string(OpenCodeCompatibilityFixture.directory.path)]),
            "moveChanges": .bool(false)
        ]))
    }

    func testSessionRetirementArchivesLineageAndDeletesCurrentOnly() async throws {
        let fixture = OpenCodeCompatibilityFixture()
        let record = OpenCodeCompatibilityFixture.record(superseded: ["ses_old"])
        try await fixture.adapter.deleteSession(record)
        let requests = await fixture.transport.requests
        let mutations = requests.filter { $0.method == "PATCH" || $0.method == "DELETE" }
        XCTAssertEqual(mutations.map(\.method), ["PATCH", "DELETE"])
        XCTAssertEqual(mutations.map(\.path), ["/session/ses_old", "/session/ses_current"])
        XCTAssertNotNil(mutations.first?.body?[oc: "time"]?[oc: "archived"]?.ocInt)
        let stops = await fixture.transport.stopCount
        XCTAssertEqual(stops, 2)
        do {
            try await fixture.adapter.unarchiveSession(record)
            XCTFail("V1 unarchive must not report a successful no-op")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .unsupportedCapability(harnessId: .opencode, capability: "native session unarchiving"))
        }
        let after = await fixture.transport.requests
        XCTAssertEqual(after, requests)
    }

    func testExcludedModesFailBeforeStartingServer() async {
        let configs = [
            AgentSpawnConfig(harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory, speedMode: .fast),
            AgentSpawnConfig(harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory, initialGoal: "Finish the task"),
            AgentSpawnConfig(harnessId: .opencode, workingDirectory: OpenCodeCompatibilityFixture.directory, arguments: ["--runtime-v2"])
        ]
        for config in configs {
            let fixture = OpenCodeCompatibilityFixture(config: config)
            do {
                _ = try await fixture.launch()
                XCTFail("Unsupported mode must fail")
            } catch let AgentCLIError.unsupportedCapability(harnessId, _) {
                XCTAssertEqual(harnessId, .opencode)
            } catch { XCTFail("Expected typed unsupported capability, got \(error)") }
            let starts = await fixture.transport.startCount
            XCTAssertEqual(starts, 0)
        }
    }

    func testLostPromptResponseUsesHistoryWithoutSecondPost() async throws {
        let fixture = OpenCodeCompatibilityFixture(transport: OpenCodeCompatibilityTransport(promptBehavior: .acceptedWithoutResponse))
        _ = try await fixture.launch()
        try await fixture.send(.userMessage(AgentMessageInput(text: "Make the change")))
        await fixture.stop()
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/prompt_async") }.count, 1)
        XCTAssertGreaterThan(requests.filter { $0.path.hasSuffix("/message") }.count, 1)
    }

    func testUnknownPromptAcceptanceBlocksRetryUntilResume() async throws {
        let fixture = OpenCodeCompatibilityFixture(transport: OpenCodeCompatibilityTransport(promptBehavior: .unknownAcceptance))
        _ = try await fixture.launch()
        for _ in 0..<2 {
            do {
                try await fixture.send(.userMessage(AgentMessageInput(text: "Make the change")))
                XCTFail("Ambiguous input must fail and require explicit resume")
            } catch { XCTAssertTrue(error is OpenCodeTransportError) }
        }
        await fixture.stop()
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/prompt_async") }.count, 1)
    }

    func testTerminationWhileStartingCannotResurrectSession() async throws {
        let transport = OpenCodeCompatibilityTransport(suspendStart: true)
        let fixture = OpenCodeCompatibilityFixture(transport: transport)
        let launch = Task { try await fixture.launch() }
        let started = await openCodeWaitUntil { await transport.startCount == 1 }
        XCTAssertTrue(started)
        await fixture.adapter.processDidTerminate(processToken: fixture.context.processToken)
        await transport.releaseStart()
        do {
            _ = try await launch.value
            XCTFail("A stopped generation must not create a native session")
        } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertEqual(requests, [])
        let stopped = await transport.stopCount
        XCTAssertEqual(stopped, 1)
    }

    func testTerminatedTokenCannotBootstrapLater() async {
        let fixture = OpenCodeCompatibilityFixture()
        await fixture.adapter.processDidTerminate(processToken: fixture.context.processToken)
        do {
            _ = try await fixture.launch()
            XCTFail("Tombstones must also cover termination before bootstrap")
        } catch { XCTAssertTrue(error is CancellationError) }
        let starts = await fixture.transport.startCount
        XCTAssertEqual(starts, 0)
    }
}

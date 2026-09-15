import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeSessionTests: XCTestCase {
    func testRuntimePersistsHarnessSessionDiscoveredFromEvents() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("printf 'session:harness-session\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig(workingDirectory: workingDirectory))
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "harness-session")
        XCTAssertEqual(persisted?.harnessSessionId, "harness-session")
        XCTAssertEqual(persisted?.workingDirectory?.path, AgentPathHelpers.canonicalPath(workingDirectory))
        XCTAssertEqual(persisted?.generation, status?.generation)
    }

    func testRuntimePersistsHarnessSessionNameDiscoveredFromMetadataEvents() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("printf 'metadata:harness-session:Generated Name\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "harness-session")
        XCTAssertEqual(status?.harnessSessionName, "Generated Name")
        XCTAssertEqual(persisted?.harnessSessionId, "harness-session")
        XCTAssertEqual(persisted?.harnessSessionName, "Generated Name")
        XCTAssertEqual(persisted?.metadata, ["source": .string("runtime")])
    }

    func testRuntimePersistsHarnessSessionPreviewDiscoveredFromMetadataEvents() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("printf 'metadata:harness-session::Generated Preview\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "harness-session")
        XCTAssertNil(status?.harnessSessionName)
        XCTAssertEqual(status?.harnessSessionPreview, "Generated Preview")
        XCTAssertEqual(persisted?.harnessSessionId, "harness-session")
        XCTAssertNil(persisted?.harnessSessionName)
        XCTAssertEqual(persisted?.harnessSessionPreview, "Generated Preview")
        XCTAssertEqual(persisted?.metadata, ["source": .string("runtime")])
    }

    func testRuntimeUsesInitialPromptPreviewAndPersistsWhenHarnessSessionIdIsDiscovered() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("printf 'session:harness-session\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(
            conversationId: conversationId,
            config: spawnConfig(initialPrompt: "Implement the harness session preview bridge")
        )
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)
        let metadata = events.compactMap(\.event.runtimeSessionMetadataEvent)

        XCTAssertEqual(metadata.first?.harnessSessionId, nil)
        XCTAssertEqual(metadata.first?.preview, "Implement the harness session preview bridge")
        XCTAssertEqual(metadata.last?.harnessSessionId, "harness-session")
        XCTAssertEqual(metadata.last?.preview, "Implement the harness session preview bridge")
        XCTAssertEqual(status?.harnessSessionId, "harness-session")
        XCTAssertEqual(status?.harnessSessionPreview, "Implement the harness session preview bridge")
        XCTAssertEqual(persisted?.harnessSessionId, "harness-session")
        XCTAssertEqual(persisted?.harnessSessionPreview, "Implement the harness session preview bridge")
    }

    func testRuntimeSessionMetadataSnapshotsKeepNameAuthoritativeOverPreview() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("""
            printf 'metadata:harness-session::Generated Preview\\n'
            printf 'metadata:harness-session:Generated Name:\\n'
            printf 'metadata:harness-session::Updated Preview\\n'
            """))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let metadata = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)
            .compactMap(\.event.runtimeSessionMetadataEvent)

        XCTAssertEqual(metadata.map(\.name), [nil, "Generated Name", "Generated Name"])
        XCTAssertEqual(metadata.map(\.preview), ["Generated Preview", "Generated Preview", "Updated Preview"])
        XCTAssertEqual(status?.harnessSessionName, "Generated Name")
        XCTAssertEqual(status?.harnessSessionPreview, "Updated Preview")
        XCTAssertEqual(persisted?.harnessSessionName, "Generated Name")
        XCTAssertEqual(persisted?.harnessSessionPreview, "Updated Preview")
    }

    func testRuntimeDoesNotClearHarnessSessionNameFromNilMetadata() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("""
            printf 'metadata:harness-session:Generated Name\\n'
            printf 'metadata:harness-session:\\n'
            printf 'metadata:harness-session:   \\n'
            """))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionName, "Generated Name")
        XCTAssertEqual(persisted?.harnessSessionName, "Generated Name")
    }

    func testRuntimeDoesNotClearHarnessSessionPreviewFromNilMetadata() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("""
            printf 'metadata:harness-session::Generated Preview\\n'
            printf 'metadata:harness-session:\\n'
            printf 'metadata:harness-session:   :   \\n'
            """))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionPreview, "Generated Preview")
        XCTAssertEqual(persisted?.harnessSessionPreview, "Generated Preview")
    }

    func testRuntimeDoesNotCarryHarnessSessionNameAcrossSessionChangeWithoutName() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("printf 'metadata:first-session:Old Name\\nmetadata:second-session:\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "second-session")
        XCTAssertNil(status?.harnessSessionName)
        XCTAssertEqual(persisted?.harnessSessionId, "second-session")
        XCTAssertNil(persisted?.harnessSessionName)
    }

    func testRuntimeDoesNotCarryHarnessSessionPreviewAcrossConcreteSessionChangeWithoutPreview() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingHarnessAdapter(command: shell("printf 'metadata:first-session::Old Preview\\nmetadata:second-session:\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "second-session")
        XCTAssertNil(status?.harnessSessionPreview)
        XCTAssertEqual(persisted?.harnessSessionId, "second-session")
        XCTAssertNil(persisted?.harnessSessionPreview)
    }

    func testRuntimeSeedsHarnessSessionNameFromResumedRecord() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                harnessId: .claude,
                harnessSessionId: "harness-session",
                harnessSessionName: "Saved Name",
                generation: 1
            )
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedHarnessAdapter(launchSequence: LaunchSequence([
                shell("printf 'message:ready\\n'")
            ]))],
            sessionStore: sessionStore
        )

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "harness-session")
        XCTAssertEqual(status?.harnessSessionName, "Saved Name")
        XCTAssertEqual(persisted?.harnessSessionName, "Saved Name")
    }

    func testRuntimeSeedsHarnessSessionPreviewFromResumedRecord() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                harnessId: .claude,
                harnessSessionId: "harness-session",
                harnessSessionPreview: "Saved Preview",
                generation: 1
            )
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedHarnessAdapter(launchSequence: LaunchSequence([
                shell("printf 'message:ready\\n'")
            ]))],
            sessionStore: sessionStore
        )

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "harness-session")
        XCTAssertEqual(status?.harnessSessionPreview, "Saved Preview")
        XCTAssertEqual(persisted?.harnessSessionPreview, "Saved Preview")
    }

    func testRuntimePersistsLaunchSeededHarnessSessionOnFirstEvent() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedHarnessAdapter(launchSequence: LaunchSequence([
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'message:ready\\n'"],
                    harnessSessionId: "seeded-session"
                )
            ]))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "seeded-session")
        XCTAssertEqual(persisted?.harnessSessionId, "seeded-session")
        XCTAssertEqual(persisted?.metadata, ["source": .string("runtime")])
    }

    func testReconfigureIgnoresSessionEventAfterSlowPersistence() async throws {
        let sessionStore = SlowSessionStore(saveDelay: 200_000_000)
        let launchSequence = LaunchSequence([
            shell("printf 'session:old-session\\n'"),
            shell("printf 'message:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingHarnessAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 250_000_000)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)

        XCTAssertFalse(events.contains { $0.event == .diagnostic(AgentDiagnosticEvent(severity: .info, message: "session")) })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testReconfigureIgnoresSessionPersistenceFailureFromReplacedProcess() async throws {
        let sessionStore = FailingSlowSessionStore(saveDelay: 200_000_000)
        let launchSequence = LaunchSequence([
            shell("printf 'session:old-session\\n'; sleep 1"),
            shell("printf 'message:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingHarnessAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 250_000_000)
        let status = await runtime.status(conversationId: conversationId)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)

        let diagnostics = events.compactMap { envelope -> AgentDiagnosticEvent? in
            guard case let .diagnostic(diagnostic) = envelope.event else {
                return nil
            }
            return diagnostic
        }
        XCTAssertFalse(diagnostics.contains { $0.message.contains("Could not persist harness session") })
        XCTAssertFalse(diagnostics.contains { $0.code == .sessionStoreSaveFailed })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testReconfigurePreservesCurrentHarnessSessionWhenOlderSaveFinishesLast() async throws {
        let sessionStore = OutOfOrderSessionStore(delays: [
            "old-session": 250_000_000,
            "new-session": 20_000_000
        ])
        let launchSequence = LaunchSequence([
            shell("printf 'session:old-session\\n'"),
            shell("printf 'session:new-session\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingHarnessAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 350_000_000)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "new-session")
        XCTAssertEqual(persisted?.harnessSessionId, "new-session")
    }

    func testRuntimePreservesCurrentHarnessSessionNameWhenOlderSaveFinishesLast() async throws {
        let sessionStore = OutOfOrderSessionStore(delays: [
            "Old Name": 250_000_000,
            "New Name": 20_000_000
        ])
        let launchSequence = LaunchSequence([
            shell("printf 'metadata:same-session:Old Name\\n'"),
            shell("printf 'metadata:same-session:New Name\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingHarnessAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 350_000_000)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "same-session")
        XCTAssertEqual(status?.harnessSessionName, "New Name")
        XCTAssertEqual(persisted?.harnessSessionId, "same-session")
        XCTAssertEqual(persisted?.harnessSessionName, "New Name")
    }

    func testRuntimePreservesCurrentHarnessSessionPreviewWhenOlderSaveFinishesLast() async throws {
        let sessionStore = OutOfOrderSessionStore(delays: [
            "Old Preview": 250_000_000,
            "New Preview": 20_000_000
        ])
        let launchSequence = LaunchSequence([
            shell("printf 'metadata:same-session::Old Preview\\n'"),
            shell("printf 'metadata:same-session::New Preview\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingHarnessAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 350_000_000)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)

        XCTAssertEqual(status?.harnessSessionId, "same-session")
        XCTAssertEqual(status?.harnessSessionPreview, "New Preview")
        XCTAssertEqual(persisted?.harnessSessionId, "same-session")
        XCTAssertEqual(persisted?.harnessSessionPreview, "New Preview")
    }

    func testRuntimeIgnoresStaleHarnessSessionNamePersistenceFailureAfterNewNameSucceeds() async throws {
        let sessionStore = SelectiveFailureOutOfOrderSessionStore(
            delays: [
                "Old Name": 250_000_000,
                "New Name": 20_000_000
            ],
            failingKeys: ["Old Name"]
        )
        let launchSequence = LaunchSequence([
            shell("printf 'metadata:same-session:Old Name\\n'"),
            shell("printf 'metadata:same-session:New Name\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingHarnessAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 350_000_000)
        let persisted = try await sessionStore.record(conversationId: conversationId, harnessId: .claude)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)
        let diagnostics = events.compactMap { envelope -> AgentDiagnosticEvent? in
            guard case let .diagnostic(diagnostic) = envelope.event else {
                return nil
            }
            return diagnostic
        }

        XCTAssertEqual(status?.harnessSessionId, "same-session")
        XCTAssertEqual(status?.harnessSessionName, "New Name")
        XCTAssertEqual(persisted?.harnessSessionId, "same-session")
        XCTAssertEqual(persisted?.harnessSessionName, "New Name")
        XCTAssertFalse(diagnostics.contains { $0.code == .sessionStoreSaveFailed })
    }
}

import XCTest

@testable import AgentCLIKit

/// A launch may return a provider session that is not the one it resumed, because the provider replaced it —
/// Codex forks a thread whenever a resumed runtime needs a fresh host-tool route. These cover the replacement
/// becoming the bound session and the sessions it displaced staying reachable for cleanup.
final class RuntimeSupersededSessionTests: XCTestCase {
    func testLaunchReplacingResumedSessionPersistsReplacementAndItsLineage() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                providerId: .claude,
                providerSessionId: "resumed-session",
                generation: 1
            )
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedProviderAdapter(launchSequence: LaunchSequence([
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'message:ready\\n'"],
                    providerSessionId: "replacement-session"
                )
            ]))],
            sessionStore: sessionStore
        )

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionId, "replacement-session")
        XCTAssertEqual(persisted?.providerSessionId, "replacement-session")
        XCTAssertEqual(persisted?.supersededProviderSessionIds, ["resumed-session"])
    }

    func testLaunchResumingSameSessionRecordsNoLineage() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                providerId: .claude,
                providerSessionId: "resumed-session",
                generation: 1
            )
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedProviderAdapter(launchSequence: LaunchSequence([
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'message:ready\\n'"],
                    providerSessionId: "resumed-session"
                )
            ]))],
            sessionStore: sessionStore
        )

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(persisted?.providerSessionId, "resumed-session")
        XCTAssertEqual(persisted?.supersededProviderSessionIds, [])
    }

    func testRepeatedReplacementsAccumulateLineageAcrossLaunches() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                providerId: .claude,
                providerSessionId: "session-one",
                generation: 1
            )
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedProviderAdapter(launchSequence: LaunchSequence([
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'message:ready\\n'"],
                    providerSessionId: "session-two"
                ),
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'message:ready\\n'"],
                    providerSessionId: "session-three"
                )
            ]))],
            sessionStore: sessionStore
        )

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(persisted?.providerSessionId, "session-three")
        XCTAssertEqual(persisted?.supersededProviderSessionIds, ["session-one", "session-two"])
    }

    func testSessionChangeDiscoveredFromEventsRecordsLineage() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingProviderAdapter(command: shell("printf 'session:first-session\\nsession:second-session\\n'"))],
            sessionStore: sessionStore
        )

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(persisted?.providerSessionId, "second-session")
        XCTAssertEqual(persisted?.supersededProviderSessionIds, ["first-session"])
    }

    func testRuntimeArchivesSupersededSessionExactlyOnce() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                providerId: .claude,
                providerSessionId: "resumed-session",
                generation: 1
            )
        ])
        let recorder = SessionActionRecorder()
        let adapter = ArchivingSequencedProviderAdapter(
            launchSequence: LaunchSequence([
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'metadata:replacement-session:First Name\\nmetadata:replacement-session:Second Name\\n'"],
                    providerSessionId: "replacement-session"
                )
            ]),
            recorder: recorder,
            supportsSessionArchiving: true
        )
        let runtime = DefaultAgentRuntime(adapters: [adapter], sessionStore: sessionStore)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        let archived = await recorder.archivedSessionIds

        XCTAssertEqual(archived, ["resumed-session"])
    }

    func testRuntimeSkipsArchivingForProvidersWithoutNativeArchiving() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                providerId: .claude,
                providerSessionId: "resumed-session",
                generation: 1
            )
        ])
        let recorder = SessionActionRecorder()
        let adapter = ArchivingSequencedProviderAdapter(
            launchSequence: LaunchSequence([
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'message:ready\\n'"],
                    providerSessionId: "replacement-session"
                )
            ]),
            recorder: recorder,
            supportsSessionArchiving: false
        )
        let runtime = DefaultAgentRuntime(adapters: [adapter], sessionStore: sessionStore)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        let archived = await recorder.archivedSessionIds
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(archived, [])
        XCTAssertEqual(persisted?.supersededProviderSessionIds, ["resumed-session"])
    }

    func testFailedArchiveKeepsLineageAndReportsDiagnostic() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                providerId: .claude,
                providerSessionId: "resumed-session",
                generation: 1
            )
        ])
        let recorder = SessionActionRecorder()
        let adapter = ArchivingSequencedProviderAdapter(
            launchSequence: LaunchSequence([
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'message:ready\\n'"],
                    providerSessionId: "replacement-session"
                )
            ]),
            recorder: recorder,
            supportsSessionArchiving: true,
            archiveFails: true
        )
        let runtime = DefaultAgentRuntime(adapters: [adapter], sessionStore: sessionStore)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)
        let diagnostics = events.compactMap { envelope -> AgentDiagnosticEvent? in
            guard case let .diagnostic(diagnostic) = envelope.event else {
                return nil
            }
            return diagnostic
        }

        XCTAssertEqual(persisted?.providerSessionId, "replacement-session")
        XCTAssertEqual(persisted?.supersededProviderSessionIds, ["resumed-session"])
        XCTAssertTrue(diagnostics.contains { $0.message.contains("Could not archive superseded provider session") })
    }
}

/// Records the provider session identifiers a runtime asked the adapter to retire.
actor SessionActionRecorder {
    private(set) var archivedSessionIds: [AgentSessionID] = []

    func recordArchive(_ providerSessionId: AgentSessionID) {
        archivedSessionIds.append(providerSessionId)
    }
}

struct ArchivingSequencedProviderAdapter: AgentProviderAdapter {
    let definition: AgentProviderDefinition
    let launchSequence: LaunchSequence
    let recorder: SessionActionRecorder
    let archiveFails: Bool

    init(
        launchSequence: LaunchSequence,
        recorder: SessionActionRecorder,
        supportsSessionArchiving: Bool,
        archiveFails: Bool = false
    ) {
        self.definition = AgentProviderDefinition(
            id: .claude,
            displayName: "Fake",
            executableNames: ["fake"],
            capabilities: AgentProviderCapabilities(supportsSessionArchiving: supportsSessionArchiving)
        )
        self.launchSequence = launchSequence
        self.recorder = recorder
        self.archiveFails = archiveFails
    }

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await launchSequence.next()
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line.hasPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: String(line.dropFirst("message:".count))))]
        }
        if line.hasPrefix("metadata:") {
            let fields = String(line.dropFirst("metadata:".count)).components(separatedBy: ":")
            return [.sessionMetadata(AgentSessionMetadataEvent(
                providerSessionId: fields.first.map(AgentSessionID.init(rawValue:)),
                name: fields.count > 1 ? fields[1] : nil
            ))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func archiveSession(_ record: AgentSessionRecord) async throws {
        await recorder.recordArchive(record.providerSessionId)
        if archiveFails {
            throw AgentCLIError.invalidInput("archive failed")
        }
    }
}

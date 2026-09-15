import XCTest

@testable import AgentCLIKit

final class AgentCLIKitCompatibilityTests: XCTestCase {
    func testEventEnvelopeMapsToHostPersistedRecordShape() {
        let envelope = AgentEventEnvelope(
            generation: 2,
            index: 7,
            harnessId: .claude,
            conversationId: "conversation",
            harnessSessionId: "session",
            source: .stdout,
            event: .message(AgentMessageEvent(role: .assistant, text: "Done")),
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let record = HostEventRecord(envelope: envelope)

        XCTAssertEqual(record.harnessId, "claude")
        XCTAssertEqual(record.conversationId, "conversation")
        XCTAssertEqual(record.harnessSessionId, "session")
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(record.index, 7)
        XCTAssertEqual(record.source, "stdout")
    }

    func testApprovalResultMappingUsesGenericResolutionAndClaudeHookDecision() {
        let resolution = AgentInteractionResolution(id: "approval", outcome: .approved, responseText: "yes")
        let response = AgentHookResponse(statusCode: 200, body: .object(["decision": .string("allow")]))

        XCTAssertEqual(resolution.outcome, .approved)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .allow)
    }

    func testSubscriptionCursorPersistenceUsesEnvelopeGenerationAndIndex() {
        let first = AgentEventEnvelope(
            generation: 3,
            index: 10,
            harnessId: .claude,
            conversationId: "conversation",
            harnessSessionId: "session",
            source: .stdout,
            event: .message(AgentMessageEvent(role: .assistant, text: "First"))
        )
        let second = AgentEventEnvelope(
            generation: 3,
            index: 11,
            harnessId: .claude,
            conversationId: "conversation",
            harnessSessionId: "session",
            source: .stdout,
            event: .message(AgentMessageEvent(role: .assistant, text: "Second"))
        )

        var cursor = HostSubscriptionCursor()
        cursor.markPersisted(first)
        let replayed = [first, second].filter { cursor.shouldReplay($0) }

        XCTAssertEqual(cursor.generation, 3)
        XCTAssertEqual(cursor.afterIndex, 10)
        XCTAssertEqual(replayed.map(\.index), [11])
    }

    func testClaudeLaunchCoversResumeAndFreshSessionSemantics() async throws {
        let adapter = ClaudeHarnessAdapter(
            executablePath: "/opt/homebrew/bin/claude",
            sessionFileExists: { _ in true }
        )
        let session = AgentSessionRecord(
            conversationId: "conversation",
            harnessId: .claude,
            harnessSessionId: "session",
            generation: 1
        )
        let config = AgentSpawnConfig(harnessId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp"))

        let resumed = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: session)
        let fresh = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)

        XCTAssertTrue(resumed.arguments.contains("--resume"))
        XCTAssertTrue(resumed.arguments.contains("session"))
        XCTAssertFalse(fresh.arguments.contains("--resume"))
    }

    func testRuntimeStatusSnapshotRemainsHostMappable() {
        let status = AgentRuntimeStatus(
            conversationId: "conversation",
            harnessId: .claude,
            generation: 3,
            state: .running,
            lastEventIndex: 12,
            harnessSessionId: "harness-session",
            isTurnActive: true
        )

        let snapshot = HostStatusSnapshot(status: status)

        XCTAssertEqual(snapshot.harnessId, "claude")
        XCTAssertEqual(snapshot.state, "running")
        XCTAssertEqual(snapshot.lastEventIndex, 12)
        XCTAssertEqual(snapshot.harnessSessionId, "harness-session")
        XCTAssertNil(snapshot.harnessSessionName)
        XCTAssertNil(snapshot.harnessSessionPreview)
        XCTAssertTrue(snapshot.isTurnActive)
    }

    func testHarnessIdDecodesKnownPersistedValue() throws {
        for expectedHarnessId in AgentHarnessID.allCases {
            let data = Data("\"\(expectedHarnessId.rawValue)\"".utf8)

            let harnessId = try JSONDecoder().decode(AgentHarnessID.self, from: data)
            let encoded = try JSONEncoder().encode(harnessId)

            XCTAssertEqual(harnessId, expectedHarnessId)
            XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"\(expectedHarnessId.rawValue)\"")
        }
    }

    func testHarnessIdRejectsUnknownPersistedValue() {
        let data = Data(#""future-harness""#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(AgentHarnessID.self, from: data))
    }

    func testOlderUsageEventPayloadDefaultsNewTypedFields() throws {
        let data = Data(
            #"{"model":"sonnet","inputTokens":1,"outputTokens":2,"metadata":{"stop_reason":"end_turn","duration_ms":50,"total_cost_usd":0.02}}"#.utf8
        )

        let usage = try JSONDecoder().decode(AgentUsageEvent.self, from: data)

        XCTAssertEqual(usage.model, "sonnet")
        XCTAssertEqual(usage.inputTokens, 1)
        XCTAssertEqual(usage.outputTokens, 2)
        XCTAssertEqual(usage.stopReason, "end_turn")
        XCTAssertEqual(usage.durationMs, 50)
        XCTAssertEqual(usage.costUSD, 0.02)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertTrue(usage.isTerminal)
        XCTAssertFalse(usage.isError)
        XCTAssertEqual(usage.permissionDenials, [])
    }

    func testUsageEventPayloadDecodesCachedInputTokensFromMetadata() throws {
        let data = Data(
            """
            {
              "model": "gpt-5.3-codex-spark",
              "inputTokens": 10,
              "outputTokens": 2,
              "metadata": {
                "stop_reason": "usage_update",
                "cached_input_tokens": 4
              }
            }
            """.utf8
        )

        let usage = try JSONDecoder().decode(AgentUsageEvent.self, from: data)
        let encoded = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(AgentUsageEvent.self, from: encoded)

        XCTAssertEqual(decoded.cachedInputTokens, 4)
        XCTAssertNil(decoded.cacheReadInputTokens)
        XCTAssertFalse(decoded.isTerminal)
    }

    func testOlderLaunchConfigurationPayloadDefaultsSessionContinuity() throws {
        let data = Data(#"{"executable":"/usr/bin/env","arguments":["claude"],"environment":{}}"#.utf8)

        let launch = try JSONDecoder().decode(AgentLaunchConfiguration.self, from: data)

        XCTAssertEqual(launch.executable, "/usr/bin/env")
        XCTAssertNil(launch.sessionContinuity)
        XCTAssertFalse(launch.includesSpawnArguments)
    }

    func testOlderSpawnConfigPayloadDefaultsForkSession() throws {
        let data = Data(
            #"{"providerId":"claude","workingDirectory":"file:///tmp/project","arguments":[],"environment":{}}"#.utf8
        )

        let config = try JSONDecoder().decode(AgentSpawnConfig.self, from: data)

        XCTAssertFalse(config.forkSession)
        XCTAssertNil(config.sessionFork)
        XCTAssertNil(config.speedMode)
        XCTAssertNil(config.initialGoal)
        XCTAssertEqual(config.additionalWorkspaceRoots, [])
        XCTAssertEqual(config.hostToolServer, AgentHostToolServerMetadata())
        XCTAssertEqual(config.hostTools, [])
    }

    func testOlderRuntimeStatusPayloadDefaultsLifecycleSnapshotFields() throws {
        let data = Data(
            #"{"conversationId":"conversation","providerId":"claude","generation":1,"state":"running","lastEventIndex":2}"#.utf8
        )

        let status = try JSONDecoder().decode(AgentRuntimeStatus.self, from: data)

        XCTAssertNil(status.processIdentifier)
        XCTAssertFalse(status.isProcessRunning)
        XCTAssertFalse(status.canCancel)
        XCTAssertFalse(status.isTurnActive)
        XCTAssertNil(status.collaborationMode)
        XCTAssertNil(status.goal)
        XCTAssertNil(status.harnessSessionName)
        XCTAssertNil(status.harnessSessionPreview)
    }

    func testOlderHarnessCapabilitiesPayloadDefaultsGoalFields() throws {
        let data = Data(#"{"supportsPlanMode":true,"supportsSpeedMode":true}"#.utf8)

        let capabilities = try JSONDecoder().decode(AgentHarnessCapabilities.self, from: data)

        XCTAssertTrue(capabilities.supportsPlanMode)
        XCTAssertTrue(capabilities.supportsSpeedMode)
        XCTAssertFalse(capabilities.supportsGoalMode)
        XCTAssertFalse(capabilities.supportsExistingSessionGoalStart)
        XCTAssertEqual(capabilities.supportedGoalActions, [])
    }

    func testGoalSnapshotAndEventRoundTrip() throws {
        let event = AgentEvent.goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
            objective: "Ship goal mode",
            status: .active,
            availableActions: [.pause, .delete],
            elapsedSeconds: 12,
            turnCount: 2,
            tokenCount: 300,
            metadata: ["source": .string("test")]
        )))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }

    func testOlderSessionRecordPayloadDefaultsHarnessSessionMetadata() throws {
        let data = Data(
            """
            {
              "conversationId":"conversation",
              "providerId":"claude",
              "providerSessionId":"session",
              "generation":1,
              "createdAt":"2026-01-01T00:00:00Z",
              "updatedAt":"2026-01-01T00:00:00Z"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(AgentSessionRecord.self, from: data)

        XCTAssertEqual(record.harnessSessionId, "session")
        XCTAssertNil(record.harnessSessionName)
        XCTAssertNil(record.harnessSessionPreview)
        XCTAssertEqual(record.metadata, [:])
    }
}

private struct HostSubscriptionCursor {
    private(set) var generation: Int?
    private(set) var afterIndex: Int?

    mutating func markPersisted(_ envelope: AgentEventEnvelope) {
        self.generation = envelope.generation
        self.afterIndex = envelope.index
    }

    func shouldReplay(_ envelope: AgentEventEnvelope) -> Bool {
        guard envelope.generation == generation else {
            return false
        }
        return envelope.index > (afterIndex ?? -1)
    }
}

private struct HostEventRecord {
    let harnessId: String
    let conversationId: String
    let harnessSessionId: String?
    let generation: Int
    let index: Int
    let source: String

    init(envelope: AgentEventEnvelope) {
        self.harnessId = envelope.harnessId.rawValue
        self.conversationId = envelope.conversationId.rawValue
        self.harnessSessionId = envelope.harnessSessionId?.rawValue
        self.generation = envelope.generation
        self.index = envelope.index
        self.source = envelope.source.rawValue
    }
}

private struct HostStatusSnapshot {
    let harnessId: String
    let state: String
    let lastEventIndex: Int
    let harnessSessionId: String?
    let harnessSessionName: String?
    let harnessSessionPreview: String?
    let isTurnActive: Bool

    init(status: AgentRuntimeStatus) {
        self.harnessId = status.harnessId.rawValue
        self.state = status.state.rawValue
        self.lastEventIndex = status.lastEventIndex
        self.harnessSessionId = status.harnessSessionId?.rawValue
        self.harnessSessionName = status.harnessSessionName
        self.harnessSessionPreview = status.harnessSessionPreview
        self.isTurnActive = status.isTurnActive
    }
}

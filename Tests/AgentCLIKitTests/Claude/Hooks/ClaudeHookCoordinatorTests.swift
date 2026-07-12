import Foundation
import XCTest

@testable import AgentCLIKit

final class ClaudeHookCoordinatorTests: XCTestCase {
    func testCoordinatorPreparesPerLaunchSettingsAndInvalidatesToken() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )
        let processToken = UUID()

        let launch = try await coordinator.prepareLaunch(conversationId: "conversation", processToken: processToken)
        let settingsData = try Data(contentsOf: launch.settingsFileURL)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])

        XCTAssertEqual(launch.arguments, ["--settings", launch.settingsFileURL.path])
        XCTAssertEqual(launch.environment["AGENTCLIKIT_CLAUDE_HOOK_TOKEN"], launch.token)
        let issuedToken = await tokenStore.token(for: launch.token)
        XCTAssertEqual(issuedToken?.expiresAt, .distantFuture)
        let isValid = await tokenStore.validate(launch.token)
        XCTAssertTrue(isValid)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["PreCompact"])
        XCTAssertNotNil(hooks["PostCompact"])

        await coordinator.invalidate(processToken: processToken)

        let isInvalidated = await tokenStore.validate(launch.token)
        XCTAssertFalse(isInvalidated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.settingsFileURL.path))
    }

    func testCoordinatorShutdownRemovesActiveLaunchSettingsAndInvalidatesTokens() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )

        let first = try await coordinator.prepareLaunch(conversationId: "first", processToken: UUID())
        let second = try await coordinator.prepareLaunch(conversationId: "second", processToken: UUID())

        await coordinator.shutdown()

        let isFirstTokenValid = await tokenStore.validate(first.token)
        let isSecondTokenValid = await tokenStore.validate(second.token)

        XCTAssertFalse(isFirstTokenValid)
        XCTAssertFalse(isSecondTokenValid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.settingsFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.settingsFileURL.path))
    }

    func testConcurrentLaunchesShareOneListenerStart() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: InMemoryAgentInteractionStore())
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let probe = HookListenerStartProbe()
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in DelayedHookTransport(probe: probe) }
        )

        async let first = coordinator.prepareLaunch(conversationId: "first", processToken: UUID())
        async let second = coordinator.prepareLaunch(conversationId: "second", processToken: UUID())
        await probe.waitUntilStarted()
        let startCount = await probe.startCount
        XCTAssertEqual(startCount, 1)
        await probe.resumeStart()
        _ = try await (first, second)

        await coordinator.shutdown()
    }

    func testInvalidationDuringServerRegistrationRejectsDeletedLaunch() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: InMemoryAgentInteractionStore())
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let registrationGate = HookRegistrationGate()
        let processToken = UUID()
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) },
            beforeLaunchServerRegistration: { await registrationGate.suspend() }
        )
        let launchTask = Task {
            try await coordinator.prepareLaunch(conversationId: "conversation", processToken: processToken)
        }
        await registrationGate.waitUntilSuspended()

        await coordinator.invalidate(processToken: processToken)
        await registrationGate.resume()

        do {
            _ = try await launchTask.value
            XCTFail("Expected the invalidated launch to fail.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("launch registration was invalidated"))
        }
        let settingsURL = supportDirectory.appendingPathComponent("claude-hooks-\(processToken.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        await coordinator.shutdown()
    }

    func testShutdownCancelsPendingListenerStartAndRejectsLateLaunch() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: InMemoryAgentInteractionStore())
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let probe = HookListenerStartProbe()
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in DelayedHookTransport(probe: probe) }
        )
        let launchTask = Task {
            try await coordinator.prepareLaunch(conversationId: "conversation", processToken: UUID())
        }
        await probe.waitUntilStarted()

        let shutdownTask = Task {
            await coordinator.shutdown()
        }
        await probe.waitUntilStopped()
        await shutdownTask.value

        do {
            _ = try await launchTask.value
            XCTFail("Expected the pending launch to fail after shutdown.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("coordinator has shut down") || error is CancellationError)
        }
        do {
            _ = try await coordinator.prepareLaunch(conversationId: "late", processToken: UUID())
            XCTFail("Expected future launches to fail after shutdown.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("coordinator has shut down"))
        }
        let startCount = await probe.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testCoordinatorSeedsLaunchPermissionModeForHookDecisions() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )

        let launch = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: UUID(),
            permissionMode: "acceptEdits"
        )
        let edit = await server.handle(preToolUse(token: launch.token, toolName: "Edit"))
        let bash = await server.handle(preToolUse(token: launch.token, toolName: "Bash"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(edit, .noDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: bash), .deferDecision)
        XCTAssertEqual(pending.first?.approvalRequest?.operation, "Bash")
    }

    func testCoordinatorSeedsLaunchPathContextForReadOnlyToolDecisions() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )
        let processToken = UUID()

        let launch = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: processToken,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )
        let safeRead = await server.handle(preToolUse(
            token: launch.token,
            toolName: "Read",
            toolInput: .object(["file_path": .string("Sources/App.swift")]),
            processToken: processToken
        ))

        XCTAssertEqual(safeRead, .noDecision)
    }

    func testCoordinatorClearsStaleLaunchPermissionMode() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )

        _ = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: UUID(),
            permissionMode: "plan"
        )
        let launch = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: UUID(),
            permissionMode: nil
        )
        let response = await server.handle(preToolUse(token: launch.token, toolName: "ExitPlanMode"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response, .noDecision)
        XCTAssertEqual(pending, [])
    }

    func testCoordinatorRegistersCompactHooksWhenApprovalHooksAreDisabled() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )
        let processToken = UUID()

        let launch = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: processToken,
            permissionMode: "auto"
        )
        let settingsData = try Data(contentsOf: launch.settingsFileURL)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let preCompact = try XCTUnwrap((hooks["PreCompact"] as? [[String: Any]])?.first)
        let preCompactTransport = try XCTUnwrap((preCompact["hooks"] as? [[String: Any]])?.first)
        let preCompactURLString = try XCTUnwrap(preCompactTransport["url"] as? String)
        let preCompactURL = try XCTUnwrap(URLComponents(string: preCompactURLString))
        let query = Dictionary(uniqueKeysWithValues: (preCompactURL.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else {
                return nil
            }
            return (item.name, value)
        })

        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["PostCompact"])
        XCTAssertEqual(preCompact["matcher"] as? String, ClaudeHookPolicy.compactMatcher)
        XCTAssertEqual(preCompactURL.path, "/claude/hooks/pre-compact")
        XCTAssertEqual(query["conversation_id"], "conversation")
        XCTAssertEqual(query["process_token"], processToken.uuidString)
    }
}

private func preToolUse(
    token: String?,
    toolName: String,
    toolUseId: String = "tool-1",
    sessionId: String = "session-123",
    toolInput: JSONValue = .object([:]),
    processToken: UUID? = nil
) -> ClaudeHookRequest {
    ClaudeHookRequest(
        bearerToken: token,
        hookName: "PreToolUse",
        conversationId: "conversation",
        payload: .object([
            "hook_event_name": .string("PreToolUse"),
            "session_id": .string(sessionId),
            "tool_name": .string(toolName),
            "tool_input": toolInput,
            "tool_use_id": .string(toolUseId)
        ]),
        processToken: processToken
    )
}

private struct StubHookTransport: ClaudeHookListeningTransport {
    let port: Int

    func start() async throws -> Int {
        port
    }

    func stop() async {}
}

private actor HookListenerStartProbe {
    private(set) var startCount = 0
    private var didStart = false
    private var didStop = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var startContinuation: CheckedContinuation<Int, Error>?

    func start() async throws -> Int {
        startCount += 1
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    func stop() {
        didStop = true
        stopWaiters.forEach { $0.resume() }
        stopWaiters.removeAll()
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
    }

    func waitUntilStarted() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilStopped() async {
        guard !didStop else {
            return
        }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func resumeStart() {
        startContinuation?.resume(returning: 4567)
        startContinuation = nil
    }
}

private struct DelayedHookTransport: ClaudeHookListeningTransport {
    let probe: HookListenerStartProbe

    func start() async throws -> Int {
        try await probe.start()
    }

    func stop() async {
        await probe.stop()
    }
}

private actor HookRegistrationGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        suspensionWaiters.forEach { $0.resume() }
        suspensionWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else {
            return
        }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

import XCTest

@testable import AgentCLIKit

final class ClaudeHookInvalidationTests: XCTestCase {
    func testInvalidatingTokenReleasesPendingLiveDecision() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issueProcessScoped()
        let decisionProvider = HangingDecisionProvider()
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: decisionProvider,
            decisionTimeout: nil
        )
        let request = preToolUse(token: token.value)
        let responseTask = Task {
            await server.handle(request)
        }

        try await ClaudeHookTestTask.value(of: Task { await decisionProvider.waitUntilStarted() }, timeoutNanoseconds: 500_000_000)
        await server.invalidateToken(token.value)
        let response = try await ClaudeHookTestTask.value(of: responseTask, timeoutNanoseconds: 500_000_000)
        let record = await interactionStore.record(id: "tool-1")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertNil(record?.resolution)
    }

    func testTokenInvalidatedBeforeLiveDecisionDoesNotWaitForProvider() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = BlockingInteractionStore()
        let token = await tokenStore.issueProcessScoped()
        let decisionProvider = HangingDecisionProvider()
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: decisionProvider,
            decisionTimeout: nil
        )
        let request = preToolUse(token: token.value)
        let responseTask = Task {
            await server.handle(request)
        }

        try await ClaudeHookTestTask.value(of: Task { await interactionStore.waitUntilSaveStarted() }, timeoutNanoseconds: 500_000_000)
        await server.invalidateToken(token.value)
        await interactionStore.releaseSave()
        let response = try await ClaudeHookTestTask.value(of: responseTask, timeoutNanoseconds: 500_000_000)
        let hasStarted = await decisionProvider.hasStarted()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertFalse(hasStarted)
    }

    private func preToolUse(token: String?) -> ClaudeHookRequest {
        ClaudeHookRequest(
            bearerToken: token,
            hookName: "PreToolUse",
            conversationId: "conversation",
            payload: .object([
                "hook_event_name": .string("PreToolUse"),
                "session_id": .string("session-123"),
                "tool_use_id": .string("tool-1"),
                "tool_name": .string("Edit"),
                "tool_input": .object([:])
            ])
        )
    }
}

private actor HangingDecisionProvider: ClaudeHookDecisionProviding {
    private var isStarted = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        isStarted = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return .allow()
    }

    func waitUntilStarted() async {
        guard !isStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func hasStarted() -> Bool {
        isStarted
    }
}

private actor BlockingInteractionStore: AgentInteractionStore {
    private var records: [AgentInteractionID: AgentInteractionRecord] = [:]
    private var saveStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var saveReleaseContinuation: CheckedContinuation<Void, Never>?

    func save(_ record: AgentInteractionRecord) async {
        records[record.id] = record
        await withCheckedContinuation { continuation in
            saveReleaseContinuation = continuation
            saveStartedContinuations.forEach { $0.resume() }
            saveStartedContinuations.removeAll()
        }
    }

    func resolve(_ resolution: AgentInteractionResolution, updatedAt: Date) async {
        guard let existing = records[resolution.id] else {
            return
        }
        records[resolution.id] = AgentInteractionRecord(
            id: existing.id,
            conversationId: existing.conversationId,
            kind: existing.kind,
            approvalRequest: existing.approvalRequest,
            promptRequest: existing.promptRequest,
            resolution: resolution,
            updatedAt: updatedAt
        )
    }

    func record(id: AgentInteractionID) async -> AgentInteractionRecord? {
        records[id]
    }

    func pending(conversationId: AgentConversationID) async -> [AgentInteractionRecord] {
        records.values.filter { $0.conversationId == conversationId && $0.resolution == nil }
    }

    func waitUntilSaveStarted() async {
        guard saveReleaseContinuation == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            saveStartedContinuations.append(continuation)
        }
    }

    func releaseSave() {
        saveReleaseContinuation?.resume()
        saveReleaseContinuation = nil
    }
}

import Foundation
import Testing

@testable import AgentCLIKit

@Suite(.timeLimit(.minutes(1)))
struct DefaultAgentRuntimeResumingTurnTests {
    @Test func `promptless approval continuation starts active before fresh output`() async throws {
        try await withRuntime { fixture in
            try await fixture.runtime.spawn(conversationId: fixture.id, config: fixture.config, resumingTurn: true)
            let initialStatus = try #require(await fixture.runtime.status(conversationId: fixture.id))
            #expect(initialStatus.isTurnActive)

            let outputStatus = try await fixture.emit(.message(AgentMessageEvent(role: .assistant, text: "Resumed work")))
            #expect(outputStatus.isTurnActive)

            let completedStatus = try await fixture.emit(.usage(.completedTurn))
            #expect(!completedStatus.isTurnActive)
            #expect(completedStatus.isProcessRunning)
        }
    }

    @Test(arguments: [false, true])
    func `ordinary spawn preserves prompt based activity`(hasPrompt: Bool) async throws {
        try await withRuntime { fixture in
            let config = AgentSpawnConfig(
                harnessId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                initialPrompt: hasPrompt ? "Start work" : nil
            )
            let runtime: any AgentRuntime = fixture.runtime
            try await runtime.spawn(conversationId: fixture.id, config: config)
            let status = try #require(await runtime.status(conversationId: fixture.id))
            #expect(status.isTurnActive == hasPrompt)
        }
    }

    @Test(arguments: SubsequentStart.allCases)
    private func `resume activity does not survive a later launch`(start: SubsequentStart) async throws {
        try await withRuntime { fixture in
            try await fixture.runtime.spawn(conversationId: fixture.id, config: fixture.config, resumingTurn: true)
            let completedStatus = try await fixture.emit(.usage(.completedTurn))
            #expect(!completedStatus.isTurnActive)

            switch start {
            case .spawn:
                try await fixture.runtime.spawn(conversationId: fixture.id, config: fixture.config)
            case .reconfigure:
                let result = try await fixture.runtime.reconfigure(conversationId: fixture.id, config: fixture.config)
                #expect(result == .restarted)
            case .freshSession:
                try await fixture.runtime.freshSession(conversationId: fixture.id, config: fixture.config)
            }
            let status = try #require(await fixture.runtime.status(conversationId: fixture.id))
            #expect(!status.isTurnActive)
            #expect(status.isProcessRunning)
        }
    }

    @Test func `failure ends a resumed turn`() async throws {
        try await withRuntime { fixture in
            try await fixture.runtime.spawn(conversationId: fixture.id, config: fixture.config, resumingTurn: true)
            let status = try await fixture.emit(.lifecycle(AgentLifecycleEvent(state: .failed, message: "Harness failed")))
            #expect(!status.isTurnActive)
        }
    }

    @Test func `cancellation ends a resumed turn`() async throws {
        try await withRuntime { fixture in
            try await fixture.runtime.spawn(conversationId: fixture.id, config: fixture.config, resumingTurn: true)
            await fixture.runtime.cancel(conversationId: fixture.id)
            let status = try #require(await fixture.runtime.status(conversationId: fixture.id))
            #expect(!status.isTurnActive)
            #expect(status.state == .cancelled)
        }
    }
}

private enum SubsequentStart: CaseIterable {
    case spawn
    case reconfigure
    case freshSession
}

private struct ResumingTurnFixture {
    let source: HarnessActivitySource
    let runtime: DefaultAgentRuntime
    let id: AgentConversationID = "conversation"
    let config = AgentSpawnConfig(harnessId: .claude, workingDirectory: FileManager.default.temporaryDirectory)

    init() {
        let source = HarnessActivitySource()
        self.source = source
        runtime = DefaultAgentRuntime(adapters: [
            ActivityReportingHarnessAdapter(
                command: AgentLaunchConfiguration(executable: "/bin/cat"),
                activitySource: source
            )
        ])
    }

    func emit(_ event: AgentEvent) async throws -> AgentRuntimeStatus {
        let previousStatus = try #require(await runtime.status(conversationId: id))
        let statuses = await runtime.statusUpdates(conversationId: id)
        await source.emit(AgentHarnessRuntimeEvent(event: event))
        for await status in statuses where status.lastEventIndex > previousStatus.lastEventIndex {
            return status
        }
        throw RuntimeStatusStreamEnded()
    }
}

private func withRuntime(_ operation: (ResumingTurnFixture) async throws -> Void) async throws {
    let fixture = ResumingTurnFixture()
    do {
        try await operation(fixture)
        await fixture.runtime.shutdown()
    } catch {
        await fixture.runtime.shutdown()
        throw error
    }
}

private struct RuntimeStatusStreamEnded: Error {}

private extension AgentUsageEvent {
    static var completedTurn: AgentUsageEvent {
        AgentUsageEvent(model: nil, inputTokens: 1, outputTokens: 1, stopReason: "end_turn", isTerminal: true)
    }
}

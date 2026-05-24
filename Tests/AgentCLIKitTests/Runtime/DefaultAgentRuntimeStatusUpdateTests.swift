import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeStatusUpdateTests: XCTestCase {
    func testStatusUpdatesPublishPermissionModeAndWaitingState() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("printf 'permission:plan\\ninteraction:prompt\\n'; sleep 1"))
        ])
        let stream = await runtime.statusUpdates(conversationId: "conversation")
        var iterator = stream.makeAsyncIterator()

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())

        let statuses = await Self.collect(&iterator, until: { statuses in
            statuses.contains { $0.permissionMode == "plan" && $0.waitingState == .prompt }
        })
        XCTAssertTrue(statuses.contains { $0.permissionMode == "plan" })
        XCTAssertTrue(statuses.contains { $0.waitingState == .prompt && $0.inputAvailability == .blocked(reason: "Waiting for a prompt answer.") })
        await runtime.shutdown()
    }

    private static func collect(
        _ iterator: inout AsyncStream<AgentRuntimeStatus>.Iterator,
        until isComplete: @escaping @Sendable ([AgentRuntimeStatus]) -> Bool
    ) async -> [AgentRuntimeStatus] {
        var statuses: [AgentRuntimeStatus] = []
        for _ in 0..<20 {
            guard let status = await iterator.next() else {
                break
            }
            statuses.append(status)
            if isComplete(statuses) {
                break
            }
        }
        return statuses
    }
}

private struct StatusReportingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line.hasPrefix("permission:") {
            let mode = String(line.dropFirst("permission:".count))
            return [.permissionMode(AgentPermissionModeEvent(mode: mode))]
        }
        if line == "interaction:prompt" {
            return [.interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?"))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

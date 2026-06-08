import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexProviderAdapterThreadMetadataTests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testRuntimeEventsMapThreadMetadataNotifications() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        async let collectedEvents = Self.collect(stream, count: 3)

        await transport.emitNotification(method: "thread/started", params: .object([
            "thread": .object([
                "id": .string("thread-123"),
                "name": .string("Initial Name"),
                "preview": .string("Initial Preview")
            ])
        ]))
        await transport.emitNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("thread-123"),
            "threadName": .string("Renamed Thread"),
            "threadPreview": .string("Renamed Preview")
        ]))
        await transport.emitNotification(method: "thread/name/updated", params: .object([
            "thread": .object([
                "id": .string("thread-123"),
                "name": .string("Nested Rename"),
                "preview": .string("Nested Preview")
            ])
        ]))

        let events = await collectedEvents.map(\.event)

        XCTAssertEqual(events, [
            .sessionMetadata(AgentSessionMetadataEvent(
                providerSessionId: "thread-123",
                name: "Initial Name",
                preview: "Initial Preview",
                metadata: [
                    "codex_method": .string("thread/started"),
                    "codex_thread_id": .string("thread-123")
                ]
            )),
            .sessionMetadata(AgentSessionMetadataEvent(
                providerSessionId: "thread-123",
                name: "Renamed Thread",
                preview: "Renamed Preview",
                metadata: [
                    "codex_method": .string("thread/name/updated"),
                    "codex_thread_id": .string("thread-123")
                ]
            )),
            .sessionMetadata(AgentSessionMetadataEvent(
                providerSessionId: "thread-123",
                name: "Nested Rename",
                preview: "Nested Preview",
                metadata: [
                    "codex_method": .string("thread/name/updated"),
                    "codex_thread_id": .string("thread-123")
                ]
            ))
        ])
    }

    private func configuration(transport: FakeCodexAppServerTransport) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }

    private func runtimeContext(threadId: AgentSessionID, spawnConfig: AgentSpawnConfig) -> AgentProviderRuntimeContext {
        AgentProviderRuntimeContext(
            conversationId: "conversation",
            processToken: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            providerSessionId: threadId,
            spawnConfig: spawnConfig
        )
    }

    private func waitForBinding() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private static func collect(_ stream: AsyncStream<AgentProviderRuntimeEvent>, count: Int) async -> [AgentProviderRuntimeEvent] {
        var events: [AgentProviderRuntimeEvent] = []
        for await event in stream {
            events.append(event)
            if events.count >= count {
                break
            }
        }
        return events
    }
}

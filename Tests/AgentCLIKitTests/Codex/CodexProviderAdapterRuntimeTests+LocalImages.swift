import Foundation
import XCTest

@testable import AgentCLIKit

extension CodexProviderAdapterRuntimeTests {
    func testStartsTurnAndSteersWithLocalImageInput() async throws {
        let transport = FakeCodexAppServerTransport(
            threadIds: ["thread-123"],
            configRequirementsResponse: .object(["requirements": .object(["allowAppshots": .bool(true)])])
        )
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            model: "model-a"
        )

        let stream = try await startBoundThread(adapter: adapter, spawnConfig: spawnConfig)
        _ = stream
        try await sendMessage(
            "Describe this window",
            imagePath: "/tmp/screenshot-1.png",
            isAppshot: true,
            adapter: adapter,
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        await transport.emitNotification(method: "thread/status/changed", params: .object([
            "threadId": .string("thread-123"),
            "status": .object(["type": .string("active"), "activeFlags": .array([])])
        ]))
        try await waitForBinding()
        try await sendMessage(
            "Focus on the sidebar",
            imagePath: "/tmp/screenshot-2.png",
            adapter: adapter,
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
        )

        let requestLog = await transport.requestLog
        let turnStartParams = try XCTUnwrap(requestLog.first { $0.method == "turn/start" }?.params?.objectValue)
        let turnSteerParams = try XCTUnwrap(requestLog.first { $0.method == "turn/steer" }?.params?.objectValue)

        XCTAssertEqual(requestLog.map(\.method), [
            "initialize",
            "thread/start",
            "configRequirements/read",
            "turn/start",
            "turn/steer"
        ])
        XCTAssertEqual(turnStartParams["input"], Self.userInput(
            text: "Describe this window",
            imagePath: "/tmp/screenshot-1.png"
        ))
        XCTAssertEqual(turnSteerParams["input"], Self.userInput(
            text: "Focus on the sidebar",
            imagePath: "/tmp/screenshot-2.png"
        ))
    }

    func testLocalImageInputRejectsUnsupportedAttachmentType() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()

        do {
            _ = try await adapter.encodeInput(
                .userMessage(AgentMessageInput(
                    text: "Read this",
                    attachments: [
                        AgentInputAttachment(id: "file-1", fileURL: URL(fileURLWithPath: "/tmp/file.pdf"), type: "file")
                    ]
                )),
                context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
            )
            XCTFail("Expected unsupported attachment to fail.")
        } catch let error as AgentCLIError {
            guard case let .unsupportedInputAttachment(providerId, attachmentId, type, reason) = error else {
                XCTFail("Expected unsupportedInputAttachment, got \(error).")
                return
            }
            XCTAssertEqual(providerId, .codex)
            XCTAssertEqual(attachmentId, "file-1")
            XCTAssertEqual(type, "file")
            XCTAssertEqual(reason, "Codex only supports local image attachments.")
        }

        let requestLog = await transport.requestLog
        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start"])
    }

    func testAppshotInputIsBlockedWhenCodexPolicyDisallowsIt() async throws {
        let transport = FakeCodexAppServerTransport(
            threadIds: ["thread-123"],
            configRequirementsResponse: .object(["requirements": .object(["allowAppshots": .bool(false)])])
        )
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()

        do {
            _ = try await adapter.encodeInput(
                .userMessage(AgentMessageInput(
                    text: "Use this app shot",
                    metadata: [CodexInputMetadata.isAppshot: .bool(true)]
                )),
                context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
            )
            XCTFail("Expected disallowed app shot to fail.")
        } catch let error as AgentCLIError {
            guard case let .unsupportedCapability(providerId, capability) = error else {
                XCTFail("Expected unsupportedCapability, got \(error).")
                return
            }
            XCTAssertEqual(providerId, .codex)
            XCTAssertEqual(capability, "app shots")
        }

        let requestLog = await transport.requestLog
        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "configRequirements/read"])
    }

    private static func userInput(text: String, imagePath: String) -> JSONValue {
        .array([
            .object([
                "type": .string("text"),
                "text": .string(text),
                "text_elements": .array([])
            ]),
            .object([
                "type": .string("localImage"),
                "path": .string(imagePath)
            ])
        ])
    }

    private func startBoundThread(
        adapter: CodexProviderAdapter,
        spawnConfig: AgentSpawnConfig
    ) async throws -> AsyncStream<AgentProviderRuntimeEvent> {
        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        return stream
    }

    private func sendMessage(
        _ text: String,
        imagePath: String,
        isAppshot: Bool = false,
        adapter: CodexProviderAdapter,
        context: AgentProviderInputContext
    ) async throws {
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(
                text: text,
                attachments: [
                    .localImage(id: UUID().uuidString, fileURL: URL(fileURLWithPath: imagePath))
                ],
                metadata: isAppshot ? [CodexInputMetadata.isAppshot: .bool(true)] : [:]
            )),
            context: context
        )
    }
}

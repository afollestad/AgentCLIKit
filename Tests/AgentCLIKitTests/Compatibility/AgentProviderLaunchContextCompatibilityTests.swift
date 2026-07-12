import XCTest

@testable import AgentCLIKit

final class ProviderLaunchContextCompatibilityTests: XCTestCase {
    func testLegacyAdapterBridgesContextWithoutRuntimeOwnedCapabilities() async throws {
        let recorder = LegacyLaunchRecorder()
        let adapter = LegacyOnlyProviderAdapter(recorder: recorder)
        let config = AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        let session = AgentSessionRecord(
            conversationId: "conversation",
            providerId: .claude,
            providerSessionId: "provider-session",
            generation: 3
        )

        let launch = try await adapter.makeLaunchConfiguration(context: AgentProviderLaunchContext(
            conversationId: "conversation",
            processToken: UUID(),
            spawnConfig: config,
            resumedSession: session
        ))
        let calls = await recorder.calls

        XCTAssertEqual(launch.executable, "/usr/bin/true")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.spawnConfig, config)
        XCTAssertEqual(calls.first?.resumedSession, session)
    }

    func testLegacyAdapterRejectsHostToolsInsteadOfSilentlyDroppingThem() async {
        let adapter = LegacyOnlyProviderAdapter(recorder: LegacyLaunchRecorder())
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            hostTools: [hostToolDefinition]
        )

        await assertUnsupportedRuntimeOwnedCapabilities(adapter: adapter, config: config)
    }

    func testLegacyAdapterRejectsAdditionalWorkspaceRootsInsteadOfSilentlyDroppingThem() async {
        let adapter = LegacyOnlyProviderAdapter(recorder: LegacyLaunchRecorder())
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/grant")]
        )

        await assertUnsupportedRuntimeOwnedCapabilities(adapter: adapter, config: config)
    }

    func testLegacyAdapterRejectsRegisteredEndpointInsteadOfSilentlyDroppingIt() async throws {
        let adapter = LegacyOnlyProviderAdapter(recorder: LegacyLaunchRecorder())
        let config = AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        let endpointURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/mcp/test"))
        let endpoint = AgentHostToolEndpoint(
            serverName: "agentclikit_host",
            url: endpointURL,
            bearerToken: "secret",
            enabledToolNames: [hostToolDefinition.name]
        )

        do {
            _ = try await adapter.makeLaunchConfiguration(context: AgentProviderLaunchContext(
                conversationId: "conversation",
                processToken: UUID(),
                spawnConfig: config,
                resumedSession: nil,
                hostToolEndpoint: endpoint
            ))
            XCTFail("Expected the legacy adapter bridge to reject a host tool endpoint.")
        } catch {
            XCTAssertEqual(
                error as? AgentCLIError,
                .unsupportedCapability(providerId: .claude, capability: "host tools or additional workspace roots")
            )
        }
    }

    private func assertUnsupportedRuntimeOwnedCapabilities(
        adapter: LegacyOnlyProviderAdapter,
        config: AgentSpawnConfig
    ) async {
        do {
            _ = try await adapter.makeLaunchConfiguration(context: AgentProviderLaunchContext(
                conversationId: "conversation",
                processToken: UUID(),
                spawnConfig: config,
                resumedSession: nil
            ))
            XCTFail("Expected the legacy adapter bridge to reject runtime-owned capabilities.")
        } catch {
            XCTAssertEqual(
                error as? AgentCLIError,
                .unsupportedCapability(providerId: .claude, capability: "host tools or additional workspace roots")
            )
        }
    }
}

private let hostToolDefinition = AgentHostToolDefinition(
    name: "list_scheduled_tasks",
    description: "Lists scheduled tasks.",
    inputSchema: .object(["type": .string("object")])
)

private actor LegacyLaunchRecorder {
    struct Call: Sendable {
        let spawnConfig: AgentSpawnConfig
        let resumedSession: AgentSessionRecord?
    }

    private(set) var calls: [Call] = []

    func record(spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?) {
        calls.append(Call(spawnConfig: spawnConfig, resumedSession: resumedSession))
    }
}

private struct LegacyOnlyProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Legacy", executableNames: ["legacy"])
    let recorder: LegacyLaunchRecorder

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await recorder.record(spawnConfig: spawnConfig, resumedSession: resumedSession)
        return AgentLaunchConfiguration(executable: "/usr/bin/true")
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

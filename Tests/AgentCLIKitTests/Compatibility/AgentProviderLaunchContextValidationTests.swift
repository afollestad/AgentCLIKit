import XCTest

@testable import AgentCLIKit

final class LaunchContextValidationTests: XCTestCase {
    func testRejectsDottedHostServerName() {
        let context = Self.context(
            serverName: "company.host",
            tools: [Self.tool]
        )

        XCTAssertThrowsError(try context.validatedHostToolEndpoint()) { error in
            XCTAssertEqual(
                error as? AgentCLIError,
                .invalidInput("Host tool server names must be 1 to 128 ASCII letters, numbers, underscores, or hyphens.")
            )
        }
    }

    func testRejectsDuplicateToolNames() {
        let context = Self.context(
            serverName: "alveary_host",
            tools: [Self.tool, Self.tool]
        )

        XCTAssertThrowsError(try context.validatedHostToolEndpoint()) { error in
            XCTAssertEqual(error as? AgentCLIError, .invalidInput("Host tool names must be unique within one endpoint."))
        }
    }

    private static let tool = AgentHostToolDefinition(
        name: "list_scheduled_tasks",
        description: "Lists scheduled tasks.",
        inputSchema: .object(["type": .string("object")])
    )

    private static func context(
        serverName: String,
        tools: [AgentHostToolDefinition]
    ) -> AgentProviderLaunchContext {
        AgentProviderLaunchContext(
            conversationId: "conversation",
            processToken: UUID(),
            spawnConfig: AgentSpawnConfig(
                providerId: .codex,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                hostToolServer: AgentHostToolServerMetadata(name: serverName),
                hostTools: tools
            ),
            resumedSession: nil,
            hostToolEndpoint: AgentHostToolEndpoint(
                serverName: serverName,
                url: URL(string: "http://127.0.0.1:43123/opaque") ?? URL(fileURLWithPath: "/invalid"),
                bearerToken: "secret-token",
                enabledToolNames: tools.map(\.name)
            )
        )
    }
}

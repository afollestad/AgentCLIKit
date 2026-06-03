import XCTest

@testable import AgentCLIKit

final class CodexModelOptionSourceTests: XCTestCase {
    func testAppServerModelOptionSourceParsesPaginatedModelList() async {
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            modelListResponses: Self.paginatedModelListResponses()
        )
        let source = CodexAppServerModelOptionSource(configuration: configuration(transport: transport))

        let options = await source.modelOptions(for: .codex)
        let requestLog = await transport.requestLog
        let notificationMethods = await transport.notificationMethods
        let shutdownCount = await transport.shutdownCount

        XCTAssertEqual(requestLog.map(\.method), ["initialize", "model/list", "model/list"])
        XCTAssertEqual(requestLog[1].params, .object([:]))
        XCTAssertEqual(requestLog[2].params, .object(["cursor": .string("page-2")]))
        XCTAssertEqual(notificationMethods, ["initialized"])
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(options.map(\.id), ["model-a", "model-b"])
        XCTAssertEqual(options.first?.model, "model-a-wire")
        XCTAssertEqual(options.first?.contextWindowSize, 100_000)
        XCTAssertEqual(options.last?.description, "B model")
    }

    func testAppServerModelOptionSourceFallsBackToStaticOptionsAfterFailure() async {
        let transport = FakeCodexAppServerTransport(threadIds: [], failModelListRequests: true)
        let fallback = StaticAgentModelOptionSource(optionsByProvider: [
            .codex: [
                AgentModelOption(providerId: .codex, id: "fallback", model: "fallback", label: "Fallback")
            ]
        ])
        let source = CodexAppServerModelOptionSource(
            configuration: configuration(transport: transport),
            fallbackSource: fallback
        )

        let options = await source.modelOptions(for: .codex)
        let shutdownCount = await transport.shutdownCount

        XCTAssertEqual(options.map(\.id), ["fallback"])
        XCTAssertEqual(shutdownCount, 1)
    }

    private func configuration(transport: FakeCodexAppServerTransport) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            executablePath: "/usr/bin/env",
            makeTransport: { _ in transport }
        )
    }

    private static func paginatedModelListResponses() -> [JSONValue] {
        [
            .object([
                "data": .array([
                    .object([
                        "id": .string("model-b"),
                        "displayName": .string("Model B"),
                        "description": .string("B model"),
                        "contextWindow": .number(200_000),
                        "isDefault": .bool(false)
                    ]),
                    .object([
                        "id": .string("hidden"),
                        "displayName": .string("Hidden"),
                        "hidden": .bool(true)
                    ])
                ]),
                "nextCursor": .string("page-2")
            ]),
            .object([
                "data": .array([
                    .object([
                        "id": .string("model-a"),
                        "model": .string("model-a-wire"),
                        "displayName": .string("Model A"),
                        "modelContextWindow": .number(100_000),
                        "isDefault": .bool(true)
                    ]),
                    .object([
                        "id": .string("model-b"),
                        "displayName": .string("Duplicate B")
                    ])
                ])
            ])
        ]
    }
}

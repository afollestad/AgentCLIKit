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
        XCTAssertEqual(options.map(\.id), ["model-b", "model-a"])
        XCTAssertEqual(options.last?.model, "model-a-wire")
        XCTAssertEqual(options.last?.contextWindowSize, 100_000)
        XCTAssertEqual(options.first?.description, "B model")
        XCTAssertEqual(options.first?.supportedEffortOptions.map(\.value), ["low", "medium", "high"])
        XCTAssertEqual(options.first?.defaultEffortOption?.value, "medium")
        XCTAssertEqual(options.last?.supportedEffortOptions.map(\.value), ["minimal", "xhigh"])
        XCTAssertEqual(options.last?.defaultEffortOption?.value, "xhigh")
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

    func testAppServerModelOptionSourceUsesResolvedCodexExecutable() async {
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            modelListResponses: Self.singleModelListResponse(id: "resolved")
        )
        let resolver = RecordingExecutableResolver(path: "/Users/test/.local/bin/codex")
        let recorder = CodexTransportConfigurationRecorder()
        let source = CodexAppServerModelOptionSource(configuration: configuration(
            transport: transport,
            executableResolver: resolver,
            recorder: recorder
        ))

        let options = await source.modelOptions(for: .codex)
        let requestedDefinitions = await resolver.requestedDefinitions

        XCTAssertEqual(options.map(\.id), ["resolved"])
        XCTAssertEqual(requestedDefinitions.map(\.id), [.codex])
        XCTAssertEqual(recorder.executablePaths, ["/Users/test/.local/bin/codex"])
    }

    func testAppServerModelOptionSourceKeepsEnvFallbackWhenResolverMisses() async {
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            modelListResponses: Self.singleModelListResponse(id: "fallback-env")
        )
        let resolver = RecordingExecutableResolver(path: nil)
        let recorder = CodexTransportConfigurationRecorder()
        let source = CodexAppServerModelOptionSource(configuration: configuration(
            transport: transport,
            executableResolver: resolver,
            recorder: recorder
        ))

        let options = await source.modelOptions(for: .codex)
        let requestedDefinitions = await resolver.requestedDefinitions

        XCTAssertEqual(options.map(\.id), ["fallback-env"])
        XCTAssertEqual(requestedDefinitions.map(\.id), [.codex])
        XCTAssertEqual(recorder.executablePaths, ["/usr/bin/env"])
    }

    func testAppServerModelOptionSourceExactExecutableBypassesResolver() async {
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            modelListResponses: Self.singleModelListResponse(id: "exact")
        )
        let resolver = RecordingExecutableResolver(path: "/Users/test/.local/bin/codex")
        let recorder = CodexTransportConfigurationRecorder()
        let source = CodexAppServerModelOptionSource(configuration: configuration(
            transport: transport,
            executablePath: "/opt/homebrew/bin/codex",
            executableResolver: resolver,
            recorder: recorder
        ))

        let options = await source.modelOptions(for: .codex)
        let requestedDefinitions = await resolver.requestedDefinitions

        XCTAssertEqual(options.map(\.id), ["exact"])
        XCTAssertEqual(requestedDefinitions.map(\.id), [])
        XCTAssertEqual(recorder.executablePaths, ["/opt/homebrew/bin/codex"])
    }

    func testAppServerModelOptionSourceUsesFreshCacheWithoutRestartingTransport() async {
        let clock = ModelOptionTestClock(now: Date(timeIntervalSince1970: 100))
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            modelListResponses: Self.singleModelListResponse(id: "cached")
        )
        let source = CodexAppServerModelOptionSource(
            configuration: configuration(transport: transport),
            cacheTimeToLive: 300,
            now: clock.now
        )

        let first = await source.modelOptions(for: .codex)
        clock.set(Date(timeIntervalSince1970: 200))
        let second = await source.modelOptions(for: .codex)
        let requestLog = await transport.requestLog
        let startCount = await transport.startCount

        XCTAssertEqual(first.map(\.id), ["cached"])
        XCTAssertEqual(second.map(\.id), ["cached"])
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(requestLog.map(\.method), ["initialize", "model/list"])
    }

    func testAppServerModelOptionSourceFallsBackToStaleCacheAfterExpiredLiveFailure() async {
        let clock = ModelOptionTestClock(now: Date(timeIntervalSince1970: 100))
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            modelListResponses: Self.singleModelListResponse(id: "stale"),
            failModelListRequestsAfterSuccessCount: 1
        )
        let fallback = StaticAgentModelOptionSource(optionsByProvider: [
            .codex: [
                AgentModelOption(providerId: .codex, id: "fallback", model: "fallback", label: "Fallback")
            ]
        ])
        let source = CodexAppServerModelOptionSource(
            configuration: configuration(transport: transport),
            fallbackSource: fallback,
            cacheTimeToLive: 10,
            now: clock.now
        )

        let first = await source.modelOptions(for: .codex)
        clock.set(Date(timeIntervalSince1970: 120))
        let second = await source.modelOptions(for: .codex)
        let startCount = await transport.startCount
        let shutdownCount = await transport.shutdownCount

        XCTAssertEqual(first.map(\.id), ["stale"])
        XCTAssertEqual(second.map(\.id), ["stale"])
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(shutdownCount, 2)
    }

    private func configuration(
        transport: FakeCodexAppServerTransport,
        executablePath: String = "/usr/bin/env",
        executableResolver: any AgentProviderExecutableResolving = RecordingExecutableResolver(path: nil),
        recorder: CodexTransportConfigurationRecorder? = nil
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            executablePath: executablePath,
            makeTransport: { configuration in
                recorder?.record(configuration)
                return transport
            },
            executableResolver: executableResolver
        )
    }

    private static func paginatedModelListResponses() -> [JSONValue] {
        [
            .object([
                "data": .array([
                    modelBFixture(),
                    hiddenModelFixture()
                ]),
                "nextCursor": .string("page-2")
            ]),
            .object([
                "data": .array([
                    modelAFixture(),
                    duplicateModelBFixture()
                ])
            ])
        ]
    }

    private static func modelBFixture() -> JSONValue {
        .object([
            "id": .string("model-b"),
            "displayName": .string("Model B"),
            "description": .string("B model"),
            "contextWindow": .number(200_000),
            "isDefault": .bool(false),
            "defaultReasoningEffort": .string("medium"),
            "supportedReasoningEfforts": .array([
                effortOption("low", description: "Faster reasoning."),
                effortOption("medium", description: "Balanced reasoning."),
                effortOption("high", description: "Deeper reasoning.")
            ])
        ])
    }

    private static func modelAFixture() -> JSONValue {
        .object([
            "id": .string("model-a"),
            "model": .string("model-a-wire"),
            "displayName": .string("Model A"),
            "modelContextWindow": .number(100_000),
            "isDefault": .bool(true),
            "defaultReasoningEffort": .string("xhigh"),
            "supportedReasoningEfforts": .array([
                .string("minimal")
            ])
        ])
    }

    private static func hiddenModelFixture() -> JSONValue {
        .object([
            "id": .string("hidden"),
            "displayName": .string("Hidden"),
            "hidden": .bool(true)
        ])
    }

    private static func duplicateModelBFixture() -> JSONValue {
        .object([
            "id": .string("model-b"),
            "displayName": .string("Duplicate B")
        ])
    }

    private static func singleModelListResponse(id: String) -> [JSONValue] {
        [
            .object([
                "data": .array([
                    .object([
                        "id": .string(id),
                        "model": .string(id),
                        "displayName": .string(id.capitalized),
                        "description": .string("\(id) model"),
                        "hidden": .bool(false),
                        "isDefault": .bool(true),
                        "defaultReasoningEffort": .string("medium"),
                        "supportedReasoningEfforts": .array([
                            effortOption("medium", description: "Balanced reasoning.")
                        ])
                    ])
                ])
            ])
        ]
    }

    private static func effortOption(_ value: String, description: String) -> JSONValue {
        .object([
            "reasoningEffort": .string(value),
            "description": .string(description)
        ])
    }
}

private final class ModelOptionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) {
        self.current = now
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func set(_ date: Date) {
        lock.withLock {
            current = date
        }
    }
}

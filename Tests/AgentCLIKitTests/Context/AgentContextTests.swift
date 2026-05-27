import XCTest

@testable import AgentCLIKit

final class AgentContextTests: XCTestCase {
    func testContextWindowCacheStoresAndRemovesSnapshots() async {
        let cache = AgentContextWindowCache()
        let snapshot = AgentContextWindowSnapshot(
            conversationId: "conversation",
            providerId: .claude,
            usedTokens: 50,
            maximumTokens: 100,
            measuredAt: Date(timeIntervalSince1970: 10)
        )

        await cache.save(snapshot)
        let saved = await cache.snapshot(conversationId: "conversation", providerId: .claude)
        XCTAssertEqual(saved, snapshot)
        XCTAssertEqual(snapshot.usageFraction, 0.5)

        await cache.remove(conversationId: "conversation", providerId: .claude)
        let removed = await cache.snapshot(conversationId: "conversation", providerId: .claude)
        XCTAssertNil(removed)
    }

    func testHandoffPromptIncludesTaskTranscriptConstraintsAndExpectedSections() {
        let prompt = AgentContextHandoffPrompt.makeSummaryPrompt(
            task: "Implement parser",
            recentTranscript: "Assistant changed files.",
            constraints: ["Keep API generic"]
        )

        XCTAssertTrue(prompt.contains("Implement parser"))
        XCTAssertTrue(prompt.contains("Assistant changed files."))
        XCTAssertTrue(prompt.contains("- Keep API generic"))
        XCTAssertTrue(prompt.contains("remaining work"))
    }

    func testModelContextWindowCachePersistsSelectedAndReportedModelKeys() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("context-windows.json")
        let cache = JSONAgentModelContextWindowCache(fileURL: fileURL)

        try await cache.update(
            providerId: .claude,
            selectedModel: "Sonnet",
            reportedModelId: "claude-sonnet-4",
            contextWindowSize: 200_000
        )

        let reloaded = JSONAgentModelContextWindowCache(fileURL: fileURL)
        let selectedSize = await reloaded.contextWindowSize(providerId: .claude, model: "sonnet")
        let reportedSize = await reloaded.contextWindowSize(providerId: .claude, model: "CLAUDE-SONNET-4")
        XCTAssertEqual(selectedSize, 200_000)
        XCTAssertEqual(reportedSize, 200_000)
        XCTAssertEqual(JSONAgentModelContextWindowCache.cacheKey(providerId: .claude, model: " "), nil)
    }
}

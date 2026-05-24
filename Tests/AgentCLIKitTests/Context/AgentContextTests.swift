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
}

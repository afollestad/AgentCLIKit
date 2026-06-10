import XCTest

@testable import AgentCLIKit

final class AgentSessionPreviewGeneratorTests: XCTestCase {
    func testRejectsShortPromptsConfirmationsAndSlashCommands() {
        XCTAssertNil(AgentSessionPreviewGenerator.preview(fromInitialPrompt: "Fix it"))
        XCTAssertNil(AgentSessionPreviewGenerator.preview(fromInitialPrompt: " yes "))
        XCTAssertNil(AgentSessionPreviewGenerator.preview(fromInitialPrompt: "/compact this conversation"))
    }

    func testKeepsUsableConfirmationLikePrompt() {
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(fromInitialPrompt: "Yes please implement the parser fix"),
            "Yes please implement the parser fix"
        )
    }

    func testTruncatesLongPromptsAtWordBoundaryWhenPossible() {
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(
                fromInitialPrompt: "Implement provider session preview metadata in AgentCLIKit for all providers"
            ),
            "Implement provider session preview metadata in..."
        )
    }

    func testTruncatesLongSingleWordPromptsAtLimit() {
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(
                fromInitialPrompt: "SupercalifragilisticexpialidociousSupercalifragilisticexpialidocious"
            ),
            "SupercalifragilisticexpialidociousSupercalifragili..."
        )
    }

    func testCompactsHTMLImagesAndStripsHTMLTagsOutsideCode() {
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(
                fromInitialPrompt: #"<p>Describe this</p><img src="file.png" alt="image"><strong>now</strong>"#
            ),
            "Describe this(Image)now"
        )
    }

    func testRejectsShortPromptAfterStrippingHTMLTags() {
        XCTAssertNil(AgentSessionPreviewGenerator.preview(fromInitialPrompt: "<p>Fix it</p>"))
    }

    func testCompactsMarkdownImagesAndFlattensMarkdownLinks() {
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(
                fromInitialPrompt: "Review ![diagram](file:///tmp/diagram.png) and [PLAN.md](file:///Users/me/PLAN.md) today"
            ),
            "Review (Image) and PLAN.md today"
        )
    }

    func testFlattensLeadingMarkdownLinkInsteadOfTruncatingMidURL() {
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(
                fromInitialPrompt: "[PLAN.md](file:///Users/me/Development/project/PLAN.md) implement the next phase"
            ),
            "PLAN.md implement the next phase"
        )
    }

    func testRejectsShortPromptAfterFlatteningMarkdownLink() {
        XCTAssertNil(
            AgentSessionPreviewGenerator.preview(
                fromInitialPrompt: "[PLAN.md](file:///Users/me/Development/project/PLAN.md)"
            )
        )
    }

    func testPreservesMarkdownLinkSyntaxInsideCode() {
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(fromInitialPrompt: "Fix `[label](url)` parsing in markdown links"),
            "Fix `[label](url)` parsing in markdown links"
        )
    }

    func testPreservesHTMLLikeTextInsideInlineAndFencedCode() {
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(fromInitialPrompt: "Fix `<img>` handling in parser now"),
            "Fix `<img>` handling in parser now"
        )
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(fromInitialPrompt: "Explain:\n```html\n<img src=\"a.png\">\n```\nThen update docs"),
            "Explain:\n```html\n<img src=\"a.png\">\n```\nThen..."
        )
        XCTAssertEqual(
            AgentSessionPreviewGenerator.preview(fromInitialPrompt: "Explain:\n~~~html\n<img src=\"a.png\">\n~~~\nThen update docs"),
            "Explain:\n~~~html\n<img src=\"a.png\">\n~~~\nThen..."
        )
    }
}

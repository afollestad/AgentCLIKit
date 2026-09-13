import Foundation
import XCTest

final class CodexAppServerProtocolFixtureTests: XCTestCase {
    func testProtocolValidationFixtureHasNoRawLiveSecretsOrPrompts() throws {
        let fixtureText = try Self.fixtureText()

        XCTAssertFalse(fixtureText.contains("/Users/"))
        XCTAssertFalse(fixtureText.contains("sk-"))
        XCTAssertFalse(fixtureText.contains("Bearer "))
        XCTAssertFalse(fixtureText.contains("acct_"))
        XCTAssertFalse(fixtureText.contains("ws_"))
        XCTAssertFalse(fixtureText.contains("env_"))
        XCTAssertFalse(fixtureText.contains("Run exactly this command"))
        XCTAssertFalse(fixtureText.contains("Protocol validation only"))
    }

    private static func fixtureText() throws -> String {
        try String(contentsOf: fixtureURL(), encoding: .utf8)
    }

    private static func fixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: "codex_app_server_protocol_validation",
                withExtension: "json"
            )
        )
    }
}

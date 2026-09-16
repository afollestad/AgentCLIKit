import XCTest

@testable import AgentCLIKit

final class OpenCodeOneShotAuthenticationTests: XCTestCase {
    func testOpenAICopyHasNoRotatingRefreshAuthorityAndMustRemainFreshThroughTheDeadline() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let auth: JSONValue = .object(["openai": .object([
            "type": .string("oauth"), "access": .string("access"), "refresh": .string("rotating-secret"),
            "expires": .number(1_200_000), "accountId": .string("account")
        ])])
        XCTAssertNoThrow(try OpenCodeOneShotAuthentication.validate(auth, minimumValidity: 199, now: now))
        XCTAssertThrowsError(try OpenCodeOneShotAuthentication.validate(auth, minimumValidity: 200, now: now))
        let copy = OpenCodeOneShotAuthentication.isolatedCopy(auth)
        XCTAssertEqual(copy[oc: "openai"]?[oc: "refresh"], .string(""))
        XCTAssertEqual(copy[oc: "openai"]?[oc: "access"], .string("access"))
        XCTAssertEqual(copy[oc: "openai"]?[oc: "accountId"], .string("account"))
        XCTAssertEqual(auth[oc: "openai"]?[oc: "refresh"], .string("rotating-secret"))
    }

    func testCopilotBearerUsesItsNativeZeroExpiryAndKeepsEnterpriseMetadata() throws {
        let auth: JSONValue = .object(["github-copilot": .object([
            "type": .string("oauth"), "refresh": .string("bearer"), "access": .string("bearer"),
            "expires": .number(0), "enterpriseUrl": .string("github.example")
        ])])
        XCTAssertNoThrow(try OpenCodeOneShotAuthentication.validate(auth, minimumValidity: 1_300))
        XCTAssertEqual(OpenCodeOneShotAuthentication.isolatedCopy(auth), auth)
    }

    func testOAuthProvidersWithExecutableOrReactiveRefreshHooksFailClosed() {
        for provider in ["azure", "anthropic", "snowflake-cortex", "xai", "unknown"] {
            let auth: JSONValue = .object([provider: .object([
                "type": .string("oauth"), "access": .string("access"), "refresh": .string("refresh"), "expires": .number(9_999_999_999_999)
            ])])
            XCTAssertThrowsError(try OpenCodeOneShotAuthentication.validate(auth, minimumValidity: 1_300), provider)
        }
    }
}

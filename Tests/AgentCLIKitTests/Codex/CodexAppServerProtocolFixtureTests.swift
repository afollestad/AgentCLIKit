import Foundation
import XCTest

final class CodexAppServerProtocolFixtureTests: XCTestCase {
    func testProtocolValidationFixtureDocumentsRequiredPhaseThreeCoverage() throws {
        let fixture = try Self.fixture()

        XCTAssertEqual(fixture.value(at: ["codexCLI", "version"]) as? String, "codex-cli 0.137.0-alpha.4")
        XCTAssertEqual(fixture.value(at: ["documentation", "transport", "default"]) as? String, "stdio://")
        XCTAssertEqual(fixture.value(at: ["documentation", "jsonRPC", "wireOmitsJsonrpcHeader"]) as? Bool, true)
        XCTAssertEqual(fixture.value(at: ["ciPolicy", "fixturesRequireLiveCodexAuth"]) as? Bool, false)
        XCTAssertEqual(fixture.value(at: ["ciPolicy", "fixturesRequireNetwork"]) as? Bool, false)

        let serverNotifications = try XCTUnwrap(fixture.value(at: ["schema", "serverNotificationsRelevantToV1"]) as? [String])
        XCTAssertTrue(serverNotifications.contains("thread/started"))
        XCTAssertTrue(serverNotifications.contains("thread/name/updated"))
        XCTAssertEqual(fixture.value(at: ["schema", "threadMetadata", "threadObject", "name"]) as? String, "nullable string")
        XCTAssertEqual(
            fixture.value(at: ["schema", "threadMetadata", "nameUpdateNotification", "fields", "threadName"]) as? String,
            "optional string"
        )

        let serverRequests = try XCTUnwrap(fixture.value(at: ["schema", "serverRequests"]) as? [String])
        XCTAssertTrue(serverRequests.contains("item/commandExecution/requestApproval"))
        XCTAssertTrue(serverRequests.contains("item/fileChange/requestApproval"))
        XCTAssertTrue(serverRequests.contains("item/permissions/requestApproval"))
        XCTAssertTrue(serverRequests.contains("mcpServer/elicitation/request"))
        XCTAssertTrue(serverRequests.contains("item/tool/requestUserInput"))
        XCTAssertTrue(serverRequests.contains("item/tool/call"))

        let commandDecisions = try XCTUnwrap(
            fixture.value(at: ["schema", "approvalResponses", "commandExecution", "decisions"]) as? [String]
        )
        XCTAssertTrue(commandDecisions.contains("accept"))
        XCTAssertTrue(commandDecisions.contains("acceptForSession"))
        XCTAssertTrue(commandDecisions.contains("acceptWithExecpolicyAmendment"))
        XCTAssertTrue(commandDecisions.contains("applyNetworkPolicyAmendment"))
        XCTAssertTrue(commandDecisions.contains("decline"))
        XCTAssertTrue(commandDecisions.contains("cancel"))

        let fileDecisions = try XCTUnwrap(
            fixture.value(at: ["schema", "approvalResponses", "fileChange", "decisions"]) as? [String]
        )
        XCTAssertEqual(fileDecisions, ["accept", "acceptForSession", "decline", "cancel"])

        XCTAssertEqual(
            fixture.value(
                at: ["schema", "approvalResponses", "permissionProfile", "denialSemantics", "schemaHasExplicitDenialDecision"]
            ) as? Bool,
            false
        )
        XCTAssertEqual(
            fixture.value(
                at: ["schema", "approvalResponses", "permissionProfile", "denialSemantics", "liveProbeStatus"]
            ) as? String,
            "notTriggeredByPromptedRequest"
        )
    }

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

    private static func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

private extension Dictionary where Key == String, Value == Any {
    func value(at path: [String]) -> Any? {
        var current: Any? = self
        for component in path {
            current = (current as? [String: Any])?[component]
        }
        return current
    }
}

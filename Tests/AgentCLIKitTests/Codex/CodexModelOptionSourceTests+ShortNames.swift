import XCTest

@testable import AgentCLIKit

final class CodexModelOptionSourceShortNameTests: XCTestCase {
    func testDerivesShortNameFromCodenameSuffix() async {
        let options = await modelOptions(fixtures: [
            modelFixture(id: "gpt-5.6-sol"),
            modelFixture(id: "gpt-5.6-luna"),
            modelFixture(id: "gpt-5.6-terra")
        ])

        XCTAssertEqual(options.map(\.id), ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra"])
        XCTAssertEqual(options.map(\.shortName), ["sol", "luna", "terra"])
    }

    func testKeepsFullIDForGenericSuffixesAndVersionOnlyIDs() async {
        let options = await modelOptions(fixtures: [
            modelFixture(id: "gpt-5.5"),
            modelFixture(id: "gpt-5.4-mini"),
            modelFixture(id: "gpt-5.6-codex"),
            modelFixture(id: "gpt-5.6-x")
        ])

        XCTAssertEqual(options.map(\.shortName), ["gpt-5.5", "gpt-5.4-mini", "gpt-5.6-codex", "gpt-5.6-x"])
    }

    func testPrefersServerReportedShortNameOverDerivation() async {
        let options = await modelOptions(fixtures: [
            modelFixture(id: "gpt-5.6-sol", extraFields: ["shortName": .string("solaris")]),
            modelFixture(id: "gpt-5.5", extraFields: ["short_name": .string("classic")]),
            modelFixture(id: "gpt-5.4-mini", extraFields: ["slug": .string("compact")])
        ])

        XCTAssertEqual(options.map(\.shortName), ["solaris", "classic", "compact"])
    }

    func testFallsBackToFullIDWhenDerivedShortNamesCollide() async {
        let options = await modelOptions(fixtures: [
            modelFixture(id: "gpt-5.6-sol"),
            modelFixture(id: "gpt-6-sol")
        ])

        XCTAssertEqual(options.map(\.shortName), ["gpt-5.6-sol", "gpt-6-sol"])
    }

    func testFallsBackToFullIDWhenShortNameShadowsAnotherModelID() async {
        let options = await modelOptions(fixtures: [
            modelFixture(id: "sol"),
            modelFixture(id: "gpt-5.6-sol")
        ])

        XCTAssertEqual(options.map(\.shortName), ["sol", "gpt-5.6-sol"])
    }

    private func modelOptions(fixtures: [JSONValue]) async -> [AgentModelOption] {
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            modelListResponses: [.object(["data": .array(fixtures)])]
        )
        let source = CodexAppServerModelOptionSource(
            configuration: CodexProviderAdapter.Configuration(
                executablePath: "/usr/bin/env",
                makeTransport: { _ in transport },
                executableResolver: RecordingExecutableResolver(path: nil)
            )
        )
        return await source.modelOptions(for: .codex)
    }

    private func modelFixture(id: String, extraFields: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "model": .string(id),
            "displayName": .string(id.uppercased())
        ]
        for (key, value) in extraFields {
            object[key] = value
        }
        return .object(object)
    }
}

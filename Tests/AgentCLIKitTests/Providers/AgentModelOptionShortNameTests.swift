import XCTest

@testable import AgentCLIKit

final class AgentModelOptionShortNameTests: XCTestCase {
    func testClaudeOptionsExposeCLIAliasesAsShortNames() async {
        let options = await ClaudeModelOptionSource().modelOptions(for: .claude)

        XCTAssertEqual(options.map(\.id), ["sonnet", "fable", "opus", "haiku"])
        XCTAssertEqual(options.map(\.shortName), ["sonnet", "fable", "opus", "haiku"])
    }

    func testProviderDefaultOptionUsesItsIDAsShortName() {
        let options = AgentDefaultModelOptions.providerDefault(for: .codex)

        XCTAssertEqual(options.map(\.shortName), ["default"])
    }

    func testOmittedShortNameFallsBackToID() {
        let option = AgentModelOption(providerId: .codex, id: "gpt-5.5", model: "gpt-5.5", label: "GPT-5.5")

        XCTAssertEqual(option.shortName, "gpt-5.5")
    }

    func testDecodingWithoutShortNameFallsBackToID() throws {
        let json = Data(#"{"providerId":"codex","id":"gpt-5.5","model":"gpt-5.5","label":"GPT-5.5"}"#.utf8)

        let option = try JSONDecoder().decode(AgentModelOption.self, from: json)

        XCTAssertEqual(option.shortName, "gpt-5.5")
    }

    func testShortNameSurvivesRoundTripEncoding() throws {
        let option = AgentModelOption(
            providerId: .codex,
            id: "gpt-5.6-sol",
            model: "gpt-5.6-sol",
            label: "GPT-5.6-Sol",
            shortName: "sol"
        )

        let decoded = try JSONDecoder().decode(AgentModelOption.self, from: JSONEncoder().encode(option))

        XCTAssertEqual(decoded.shortName, "sol")
        XCTAssertEqual(decoded, option)
    }
}

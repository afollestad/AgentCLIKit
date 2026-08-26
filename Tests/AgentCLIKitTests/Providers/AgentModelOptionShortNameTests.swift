import XCTest

@testable import AgentCLIKit

final class AgentModelOptionShortNameTests: XCTestCase {
    /// The Claude picker lists pinned versions only, so the family aliases survive solely as short names. Losing one
    /// would silently break `/model opus` and strand every selection a host persisted before versions were selectable.
    func testClaudeFamilyAliasesSurviveAsShortNamesOnTheNewestVersion() async {
        let options = await ClaudeModelOptionSource().modelOptions(for: .claude)

        XCTAssertEqual(options.map(\.id), [
            "claude-fable-5",
            "claude-opus-5",
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-opus-4-6",
            "claude-sonnet-5",
            "claude-sonnet-4-6",
            "claude-haiku-4-5"
        ])
        XCTAssertEqual(options.map(\.shortName), [
            "fable",
            "opus",
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-opus-4-6",
            "sonnet",
            "claude-sonnet-4-6",
            "haiku"
        ])
    }

    func testClaudeShortNamesDoNotShadowAnotherModelsID() async {
        let options = await ClaudeModelOptionSource().modelOptions(for: .claude)

        let ids = Set(options.map(\.id))
        let aliases = options.map(\.shortName).filter { !ids.contains($0) }

        XCTAssertEqual(Set(aliases), ["sonnet", "fable", "opus", "haiku"])
        XCTAssertEqual(Set(options.map(\.shortName)).count, options.count)
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

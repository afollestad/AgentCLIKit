import XCTest

@testable import AgentCLIKit

extension ClaudeProviderAdapterTests {
    func testLaunchConfigurationNormalizesLegacyDefaultModelToSonnet() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")

        let nilModelLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project")
            ),
            resumedSession: nil
        )
        let legacyDefaultLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "default"
            ),
            resumedSession: nil
        )

        XCTAssertEqual(nilModelLaunch.arguments.modelArgumentValue, "sonnet")
        XCTAssertEqual(nilModelLaunch.arguments.effortArgumentValue, "high")
        XCTAssertEqual(legacyDefaultLaunch.arguments.modelArgumentValue, "sonnet")
        XCTAssertEqual(legacyDefaultLaunch.arguments.effortArgumentValue, "high")
    }

    func testLaunchConfigurationUsesModelDefaultEffortWhenEffortIsMissing() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")

        let opusLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "opus"
            ),
            resumedSession: nil
        )
        let fableLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "fable"
            ),
            resumedSession: nil
        )
        let haikuLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "haiku"
            ),
            resumedSession: nil
        )
        let explicitMediumLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "sonnet",
                effort: "medium"
            ),
            resumedSession: nil
        )

        XCTAssertEqual(opusLaunch.arguments.effortArgumentValue, "high")
        XCTAssertEqual(fableLaunch.arguments.modelArgumentValue, "fable")
        XCTAssertEqual(fableLaunch.arguments.effortArgumentValue, "high")
        XCTAssertEqual(haikuLaunch.arguments.effortArgumentValue, "medium")
        XCTAssertEqual(explicitMediumLaunch.arguments.effortArgumentValue, "medium")
    }

    func testLaunchConfigurationCoercesUnsupportedModelEffortToModelDefault() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")

        let haikuLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "haiku",
                effort: "max"
            ),
            resumedSession: nil
        )
        let opusLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "opus",
                effort: "xhigh"
            ),
            resumedSession: nil
        )
        let fableLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "fable",
                effort: "xhigh"
            ),
            resumedSession: nil
        )
        let sonnetLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "sonnet",
                effort: "xhigh"
            ),
            resumedSession: nil
        )

        XCTAssertEqual(haikuLaunch.arguments.effortArgumentValue, "medium")
        XCTAssertEqual(opusLaunch.arguments.effortArgumentValue, "xhigh")
        XCTAssertEqual(fableLaunch.arguments.modelArgumentValue, "fable")
        XCTAssertEqual(fableLaunch.arguments.effortArgumentValue, "xhigh")
        // The alias resolves to Sonnet 5, which supports `xhigh`; only the pre-`xhigh` versions coerce.
        XCTAssertEqual(sonnetLaunch.arguments.effortArgumentValue, "xhigh")
    }

    /// A pinned version reaches `--model` verbatim and still gets the effort metadata a bare alias would have.
    func testLaunchConfigurationAppliesEffortMetadataToPinnedModelVersions() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")

        let opus46Launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "claude-opus-4-6"
            ),
            resumedSession: nil
        )
        let opus46ExtraHighLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "claude-opus-4-6",
                effort: "xhigh"
            ),
            resumedSession: nil
        )
        let opus48ExtraHighLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "claude-opus-4-8",
                effort: "xhigh"
            ),
            resumedSession: nil
        )
        let haikuLaunch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "claude-haiku-4-5"
            ),
            resumedSession: nil
        )

        XCTAssertEqual(opus46Launch.arguments.modelArgumentValue, "claude-opus-4-6")
        XCTAssertEqual(opus46Launch.arguments.effortArgumentValue, "high")
        XCTAssertEqual(opus46ExtraHighLaunch.arguments.effortArgumentValue, "high")
        XCTAssertEqual(opus48ExtraHighLaunch.arguments.modelArgumentValue, "claude-opus-4-8")
        XCTAssertEqual(opus48ExtraHighLaunch.arguments.effortArgumentValue, "xhigh")
        XCTAssertEqual(haikuLaunch.arguments.modelArgumentValue, "claude-haiku-4-5")
        XCTAssertEqual(haikuLaunch.arguments.effortArgumentValue, "medium")
    }
}

private extension [String] {
    var modelArgumentValue: String? {
        argumentValue(after: "--model")
    }

    var effortArgumentValue: String? {
        argumentValue(after: "--effort")
    }

    func argumentValue(after flag: String) -> String? {
        guard let index = firstIndex(of: flag), indices.contains(index + 1) else {
            return nil
        }
        return self[index + 1]
    }
}

import XCTest

@testable import AgentCLIKit

final class AgentHarnessDiscoveryServiceTests: XCTestCase {
    func testHarnessStatusesIncludeInstallationEnablementSetupTrustAndModels() async {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let codexSetup = DiscoverySetup(
            harnessId: .codex,
            setup: .needsSetup,
            diagnostics: ["Codex auth is missing."],
            trustedProjects: []
        )
        let service = DefaultAgentHarnessDiscoveryService(
            harnessRegistry: AgentHarnessRegistry(definitions: definitions),
            executableDetector: DiscoveryDetector(availabilities: [
                .claude: AgentHarnessAvailability(harnessId: .claude, executablePath: "/usr/bin/claude"),
                .codex: AgentHarnessAvailability(harnessId: .codex, executablePath: nil)
            ]),
            harnessSetups: [
                DiscoverySetup(harnessId: .claude, trustedProjects: [projectURL.path]),
                codexSetup
            ],
            enablementSource: DiscoveryEnablement(disabledHarnessIds: [.codex]),
            modelOptionSource: DiscoveryModelOptions(options: [
                .claude: [
                    AgentModelOption(harnessId: .claude, id: "sonnet", model: "sonnet", label: "Sonnet")
                ],
                .codex: [
                    AgentModelOption(harnessId: .codex, id: "default", model: nil, label: "Harness default", isDefault: true)
                ]
            ])
        )

        let statuses = await service.harnessStatuses(projectURL: projectURL)
        let ordering = await service.stableHarnessOrdering()

        XCTAssertEqual(ordering, [.claude, .codex])
        XCTAssertEqual(statuses[.claude]?.installation, .installed)
        XCTAssertEqual(statuses[.claude]?.isEnabled, true)
        XCTAssertEqual(statuses[.claude]?.setup, .ready)
        XCTAssertEqual(statuses[.claude]?.projectTrust, .trusted)
        XCTAssertEqual(statuses[.claude]?.modelOptions.map(\.id), ["sonnet"])
        XCTAssertTrue(statuses[.claude]?.isReadyInProject == true)
        XCTAssertEqual(statuses[.codex]?.installation, .missing)
        XCTAssertEqual(statuses[.codex]?.isEnabled, false)
        XCTAssertEqual(statuses[.codex]?.setup, .needsSetup)
        XCTAssertEqual(statuses[.codex]?.projectTrust, .notTrusted)
        XCTAssertEqual(statuses[.codex]?.diagnostics, [
            "No Codex executable was found. Checked: codex.",
            "Codex auth is missing."
        ])
        XCTAssertFalse(statuses[.codex]?.isReadyInProject == true)
    }

    func testInstalledAndAvailableHarnessFiltersKeepUnknownAvailableCandidates() async {
        let service = DefaultAgentHarnessDiscoveryService(
            harnessRegistry: AgentHarnessRegistry(definitions: definitions),
            executableDetector: DiscoveryDetector(availabilities: [
                .claude: AgentHarnessAvailability(harnessId: .claude, executablePath: "/usr/bin/claude")
            ]),
            enablementSource: DiscoveryEnablement(disabledHarnessIds: [])
        )

        let installed = await service.installedHarnessStatuses(projectURL: nil)
        let available = await service.availableHarnessStatuses(projectURL: nil)

        XCTAssertEqual(installed.keys.sorted { $0.rawValue < $1.rawValue }, [.claude])
        XCTAssertEqual(available.keys.sorted { $0.rawValue < $1.rawValue }, [.claude, .codex])
        XCTAssertEqual(available[.codex]?.installation, .unknown)
    }

    func testModelOptionsFallBackToHarnessDefaultWhenSourceIsEmpty() async {
        let service = DefaultAgentHarnessDiscoveryService(
            harnessRegistry: AgentHarnessRegistry(definitions: definitions),
            executableDetector: DiscoveryDetector(availabilities: [:]),
            modelOptionSource: DiscoveryModelOptions(options: [:])
        )

        let options = await service.modelOptions(for: .codex)

        XCTAssertEqual(options, AgentDefaultModelOptions.harnessDefault(for: .codex))
    }

    func testHarnessStatusesOverlayDynamicCapabilities() async {
        let service = DefaultAgentHarnessDiscoveryService(
            harnessRegistry: AgentHarnessRegistry(definitions: definitions),
            executableDetector: DiscoveryDetector(availabilities: [
                .codex: AgentHarnessAvailability(harnessId: .codex, executablePath: "/usr/bin/codex")
            ]),
            capabilitySource: DiscoveryCapabilities(speedHarnessIds: [.codex])
        )

        let statuses = await service.harnessStatuses(projectURL: nil)

        XCTAssertTrue(statuses[.codex]?.definition?.capabilities.supportsSpeedMode == true)
        XCTAssertFalse(statuses[.claude]?.definition?.capabilities.supportsSpeedMode == true)
    }

    func testDefaultModelOptionSourceRoutesClaudeAndKeepsCodexStaticWithoutInjectedSource() async {
        let source = DefaultAgentModelOptionSource()

        let claudeOptions = await source.modelOptions(for: .claude)
        let codexOptions = await source.modelOptions(for: .codex)

        XCTAssertEqual(claudeOptions.map(\.id), [
            "claude-fable-5-1",
            "claude-fable-5",
            "claude-opus-5-5",
            "claude-opus-5",
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-opus-4-6",
            "claude-sonnet-5",
            "claude-sonnet-4-6",
            "claude-haiku-4-5"
        ])
        XCTAssertEqual(claudeOptions.map(\.label), [
            "Fable 5.1",
            "Fable 5",
            "Opus 5.5",
            "Opus 5",
            "Opus 4.8",
            "Opus 4.7",
            "Opus 4.6",
            "Sonnet 5",
            "Sonnet 4.6",
            "Haiku 4.5"
        ])
        XCTAssertEqual(claudeOptions.filter(\.isDefault).map(\.id), ["claude-sonnet-5"])
        XCTAssertEqual(codexOptions, AgentDefaultModelOptions.harnessDefault(for: .codex, description: "Use the Codex default model."))
    }

    func testStaticOptionsMatchDiscoveredClaudeOptions() async {
        let staticOptions = AgentDefaultModelOptions.staticOptions(for: .claude)
        let discovered = await ClaudeModelOptionSource().modelOptions(for: .claude)

        XCTAssertEqual(staticOptions, discovered)
        XCTAssertEqual(staticOptions.filter(\.isDefault).map(\.id), ["claude-sonnet-5"])
        XCTAssertEqual(staticOptions.first { $0.id == "claude-opus-5-5" }?.label, "Opus 5.5")
    }

    func testStaticOptionsKeepCodexOnHarnessDefault() async {
        let staticOptions = AgentDefaultModelOptions.staticOptions(for: .codex)
        let discovered = await DefaultAgentModelOptionSource().modelOptions(for: .codex)

        XCTAssertEqual(staticOptions, discovered)
        XCTAssertEqual(staticOptions.map(\.id), ["default"])
    }

    func testDefaultModelOptionSourceScopesClaudeEffortLaddersToEachModelVersion() async {
        let source = DefaultAgentModelOptionSource()

        let claudeOptions = await source.modelOptions(for: .claude)

        func efforts(_ id: String) -> [String]? {
            claudeOptions.first(where: { $0.id == id })?.supportedEffortOptions.map(\.value)
        }
        func defaultEffort(_ id: String) -> String? {
            claudeOptions.first(where: { $0.id == id })?.defaultEffortOption?.value
        }

        XCTAssertEqual(efforts("claude-sonnet-5"), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(efforts("claude-opus-5-5"), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(efforts("claude-opus-4-8"), ["low", "medium", "high", "xhigh", "max"])
        // `xhigh` postdates these two, so their ladders stop at `high`.
        XCTAssertEqual(efforts("claude-sonnet-4-6"), ["low", "medium", "high", "max"])
        XCTAssertEqual(efforts("claude-opus-4-6"), ["low", "medium", "high", "max"])
        XCTAssertEqual(efforts("claude-haiku-4-5"), ["low", "medium", "high"])
        XCTAssertEqual(defaultEffort("claude-sonnet-5"), "high")
        XCTAssertEqual(defaultEffort("claude-fable-5-1"), "high")
        XCTAssertEqual(defaultEffort("claude-opus-5-5"), "medium")
        XCTAssertEqual(defaultEffort("claude-opus-5"), "high")
        XCTAssertEqual(defaultEffort("claude-haiku-4-5"), "medium")
        XCTAssertEqual(
            claudeOptions
                .first(where: { $0.id == "claude-fable-5-1" })?
                .supportedEffortOptions
                .first(where: { $0.value == "xhigh" })?
                .label,
            "Extra High"
        )
    }

    private var definitions: [AgentHarnessDefinition] {
        [
            AgentHarnessDefinition(id: .claude, displayName: "Claude", executableNames: ["claude"]),
            AgentHarnessDefinition(id: .codex, displayName: "Codex", executableNames: ["codex"])
        ]
    }
}

private struct DiscoveryDetector: AgentHarnessExecutableDetecting {
    let availabilities: [AgentHarnessID: AgentHarnessAvailability]

    func availability(for definitions: [AgentHarnessDefinition]) async -> [AgentHarnessAvailability] {
        definitions.compactMap { availabilities[$0.id] }
    }
}

private struct DiscoveryEnablement: AgentHarnessEnablementSource {
    let disabledHarnessIds: Set<AgentHarnessID>

    func isHarnessEnabled(_ harnessId: AgentHarnessID) async -> Bool {
        !disabledHarnessIds.contains(harnessId)
    }
}

private struct DiscoveryModelOptions: AgentModelOptionSource {
    let options: [AgentHarnessID: [AgentModelOption]]

    func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption] {
        options[harnessId] ?? []
    }
}

private struct DiscoveryCapabilities: AgentHarnessCapabilitySource {
    let speedHarnessIds: Set<AgentHarnessID>

    func capabilities(
        for definition: AgentHarnessDefinition,
        availability: AgentHarnessAvailability?
    ) async -> AgentHarnessCapabilities {
        definition.capabilities.withSpeedModeSupport(speedHarnessIds.contains(definition.id))
    }
}

private final class DiscoverySetup: AgentHarnessSetup, @unchecked Sendable {
    let harnessId: AgentHarnessID
    private let setup: AgentHarnessReadinessState
    private let diagnostics: [String]
    private let trustedProjects: Set<String>

    init(
        harnessId: AgentHarnessID,
        setup: AgentHarnessReadinessState = .ready,
        diagnostics: [String] = [],
        trustedProjects: Set<String> = []
    ) {
        self.harnessId = harnessId
        self.setup = setup
        self.diagnostics = diagnostics
        self.trustedProjects = trustedProjects
    }

    func cachedSetupReadiness() -> AgentHarnessReadinessState {
        setup
    }

    func setupReadiness() async -> AgentHarnessReadinessState {
        setup
    }

    func setupDiagnostics() async -> [String] {
        diagnostics
    }

    func cachedProjectTrustStatus(for projectURL: URL) -> AgentProjectTrustStatus {
        trustedProjects.contains(projectURL.path) ? .trusted : .notTrusted
    }

    func projectTrustStatus(for projectURL: URL) async throws -> AgentProjectTrustStatus {
        cachedProjectTrustStatus(for: projectURL)
    }

    func trustProject(at projectURL: URL) async throws {}
}

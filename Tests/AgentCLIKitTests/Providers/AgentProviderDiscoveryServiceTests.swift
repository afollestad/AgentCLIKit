import XCTest

@testable import AgentCLIKit

final class AgentProviderDiscoveryServiceTests: XCTestCase {
    func testProviderStatusesIncludeInstallationEnablementSetupTrustAndModels() async {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let codexSetup = DiscoverySetup(
            providerId: .codex,
            setup: .needsSetup,
            diagnostics: ["Codex auth is missing."],
            trustedProjects: []
        )
        let service = DefaultAgentProviderDiscoveryService(
            providerRegistry: AgentProviderRegistry(definitions: definitions),
            executableDetector: DiscoveryDetector(availabilities: [
                .claude: AgentProviderAvailability(providerId: .claude, executablePath: "/usr/bin/claude"),
                .codex: AgentProviderAvailability(providerId: .codex, executablePath: nil)
            ]),
            providerSetups: [
                DiscoverySetup(providerId: .claude, trustedProjects: [projectURL.path]),
                codexSetup
            ],
            enablementSource: DiscoveryEnablement(disabledProviderIds: [.codex]),
            modelOptionSource: DiscoveryModelOptions(options: [
                .claude: [
                    AgentModelOption(providerId: .claude, id: "sonnet", model: "sonnet", label: "Sonnet")
                ],
                .codex: [
                    AgentModelOption(providerId: .codex, id: "default", model: nil, label: "Provider default", isDefault: true)
                ]
            ])
        )

        let statuses = await service.providerStatuses(projectURL: projectURL)
        let ordering = await service.stableProviderOrdering()

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

    func testInstalledAndAvailableProviderFiltersKeepUnknownAvailableCandidates() async {
        let service = DefaultAgentProviderDiscoveryService(
            providerRegistry: AgentProviderRegistry(definitions: definitions),
            executableDetector: DiscoveryDetector(availabilities: [
                .claude: AgentProviderAvailability(providerId: .claude, executablePath: "/usr/bin/claude")
            ]),
            enablementSource: DiscoveryEnablement(disabledProviderIds: [])
        )

        let installed = await service.installedProviderStatuses(projectURL: nil)
        let available = await service.availableProviderStatuses(projectURL: nil)

        XCTAssertEqual(installed.keys.sorted { $0.rawValue < $1.rawValue }, [.claude])
        XCTAssertEqual(available.keys.sorted { $0.rawValue < $1.rawValue }, [.claude, .codex])
        XCTAssertEqual(available[.codex]?.installation, .unknown)
    }

    func testModelOptionsFallBackToProviderDefaultWhenSourceIsEmpty() async {
        let service = DefaultAgentProviderDiscoveryService(
            providerRegistry: AgentProviderRegistry(definitions: definitions),
            executableDetector: DiscoveryDetector(availabilities: [:]),
            modelOptionSource: DiscoveryModelOptions(options: [:])
        )

        let options = await service.modelOptions(for: .codex)

        XCTAssertEqual(options, AgentDefaultModelOptions.providerDefault(for: .codex))
    }

    func testProviderStatusesOverlayDynamicCapabilities() async {
        let service = DefaultAgentProviderDiscoveryService(
            providerRegistry: AgentProviderRegistry(definitions: definitions),
            executableDetector: DiscoveryDetector(availabilities: [
                .codex: AgentProviderAvailability(providerId: .codex, executablePath: "/usr/bin/codex")
            ]),
            capabilitySource: DiscoveryCapabilities(speedProviderIds: [.codex])
        )

        let statuses = await service.providerStatuses(projectURL: nil)

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
            "Opus 5",
            "Opus 4.8",
            "Opus 4.7",
            "Opus 4.6",
            "Sonnet 5",
            "Sonnet 4.6",
            "Haiku 4.5"
        ])
        XCTAssertEqual(claudeOptions.filter(\.isDefault).map(\.id), ["claude-sonnet-5"])
        XCTAssertEqual(codexOptions, AgentDefaultModelOptions.providerDefault(for: .codex, description: "Use the Codex default model."))
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
        XCTAssertEqual(efforts("claude-opus-4-8"), ["low", "medium", "high", "xhigh", "max"])
        // `xhigh` postdates these two, so their ladders stop at `high`.
        XCTAssertEqual(efforts("claude-sonnet-4-6"), ["low", "medium", "high", "max"])
        XCTAssertEqual(efforts("claude-opus-4-6"), ["low", "medium", "high", "max"])
        XCTAssertEqual(efforts("claude-haiku-4-5"), ["low", "medium", "high"])
        XCTAssertEqual(defaultEffort("claude-sonnet-5"), "high")
        XCTAssertEqual(defaultEffort("claude-fable-5-1"), "high")
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

    private var definitions: [AgentProviderDefinition] {
        [
            AgentProviderDefinition(id: .claude, displayName: "Claude", executableNames: ["claude"]),
            AgentProviderDefinition(id: .codex, displayName: "Codex", executableNames: ["codex"])
        ]
    }
}

private struct DiscoveryDetector: AgentProviderExecutableDetecting {
    let availabilities: [AgentProviderID: AgentProviderAvailability]

    func availability(for definitions: [AgentProviderDefinition]) async -> [AgentProviderAvailability] {
        definitions.compactMap { availabilities[$0.id] }
    }
}

private struct DiscoveryEnablement: AgentProviderEnablementSource {
    let disabledProviderIds: Set<AgentProviderID>

    func isProviderEnabled(_ providerId: AgentProviderID) async -> Bool {
        !disabledProviderIds.contains(providerId)
    }
}

private struct DiscoveryModelOptions: AgentModelOptionSource {
    let options: [AgentProviderID: [AgentModelOption]]

    func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption] {
        options[providerId] ?? []
    }
}

private struct DiscoveryCapabilities: AgentProviderCapabilitySource {
    let speedProviderIds: Set<AgentProviderID>

    func capabilities(
        for definition: AgentProviderDefinition,
        availability: AgentProviderAvailability?
    ) async -> AgentProviderCapabilities {
        definition.capabilities.withSpeedModeSupport(speedProviderIds.contains(definition.id))
    }
}

private final class DiscoverySetup: AgentProviderSetup, @unchecked Sendable {
    let providerId: AgentProviderID
    private let setup: AgentProviderReadinessState
    private let diagnostics: [String]
    private let trustedProjects: Set<String>

    init(
        providerId: AgentProviderID,
        setup: AgentProviderReadinessState = .ready,
        diagnostics: [String] = [],
        trustedProjects: Set<String> = []
    ) {
        self.providerId = providerId
        self.setup = setup
        self.diagnostics = diagnostics
        self.trustedProjects = trustedProjects
    }

    func cachedSetupReadiness() -> AgentProviderReadinessState {
        setup
    }

    func setupReadiness() async -> AgentProviderReadinessState {
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

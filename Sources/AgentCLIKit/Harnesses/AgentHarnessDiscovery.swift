import Foundation

/// Installation state for a harness executable.
public enum AgentHarnessInstallationState: String, Codable, Hashable, Sendable {
    /// Installation has not been checked yet.
    case unknown
    /// A runnable harness executable was found.
    case installed
    /// No runnable harness executable was found.
    case missing
}

/// Selectable model metadata for host settings and thread creation UI.
public struct AgentModelOption: Codable, Equatable, Sendable {
    /// Harness this option belongs to.
    public let harnessId: AgentHarnessID
    /// Stable option identifier for host settings.
    public let id: String
    /// Short harness-defined alias hosts can accept as typed input, falling back to `id` when no alias exists.
    public let shortName: String
    /// Harness model value to pass into `AgentSpawnConfig.model`, or `nil` to use the harness default.
    public let model: String?
    /// User-facing option label.
    public let label: String
    /// Optional user-facing option description.
    public let description: String?
    /// Known context-window size for this model.
    public let contextWindowSize: Int?
    /// Whether this option should be selected by default.
    public let isDefault: Bool
    /// Effort options supported by this model, in harness-defined display order.
    public let supportedEffortOptions: [AgentHarnessOption]
    /// Preferred effort option for this model.
    public let defaultEffortOption: AgentHarnessOption?
    /// Harness-specific metadata for hosts that need richer rendering.
    public let metadata: [String: JSONValue]

    /// Creates a model option.
    public init(
        harnessId: AgentHarnessID,
        id: String,
        model: String?,
        label: String,
        shortName: String? = nil,
        description: String? = nil,
        contextWindowSize: Int? = nil,
        isDefault: Bool = false,
        supportedEffortOptions: [AgentHarnessOption] = [],
        defaultEffortOption: AgentHarnessOption? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.harnessId = harnessId
        self.id = id
        self.shortName = shortName ?? id
        self.model = model
        self.label = label
        self.description = description
        self.contextWindowSize = contextWindowSize
        self.isDefault = isDefault
        self.supportedEffortOptions = supportedEffortOptions
        self.defaultEffortOption = defaultEffortOption
        self.metadata = metadata
    }

    /// Decodes model metadata, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.harnessId = try container.decode(AgentHarnessID.self, forKey: .harnessId)
        let id = try container.decode(String.self, forKey: .id)
        self.id = id
        self.shortName = try container.decodeIfPresent(String.self, forKey: .shortName) ?? id
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.label = try container.decode(String.self, forKey: .label)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.contextWindowSize = try container.decodeIfPresent(Int.self, forKey: .contextWindowSize)
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.supportedEffortOptions = try container.decodeIfPresent([AgentHarnessOption].self, forKey: .supportedEffortOptions) ?? []
        self.defaultEffortOption = try container.decodeIfPresent(AgentHarnessOption.self, forKey: .defaultEffortOption)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    /// Returns a copy carrying a different short name, for sources that resolve alias collisions after building options.
    func withShortName(_ shortName: String) -> AgentModelOption {
        AgentModelOption(
            harnessId: harnessId,
            id: id,
            model: model,
            label: label,
            shortName: shortName,
            description: description,
            contextWindowSize: contextWindowSize,
            isDefault: isDefault,
            supportedEffortOptions: supportedEffortOptions,
            defaultEffortOption: defaultEffortOption,
            metadata: metadata
        )
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case harnessId = "providerId"
        case id
        case shortName
        case model
        case label
        case description
        case contextWindowSize
        case isDefault
        case supportedEffortOptions
        case defaultEffortOption
        case metadata
    }
}

/// Full harness status snapshot for settings, setup, and harness/model selection UI.
public struct AgentHarnessStatus: Codable, Equatable, Sendable {
    /// Harness represented by this status.
    public let harnessId: AgentHarnessID
    /// Static harness definition when registered.
    public let definition: AgentHarnessDefinition?
    /// Installation state derived from harness executable detection.
    public let installation: AgentHarnessInstallationState
    /// Latest executable availability when detection has run.
    public let availability: AgentHarnessAvailability?
    /// Whether the host currently enables this harness.
    public let isEnabled: Bool
    /// Harness setup readiness separate from project trust.
    public let setup: AgentHarnessReadinessState
    /// Project trust status when a project was supplied.
    public let projectTrust: AgentProjectTrustStatus?
    /// Selectable model options for this harness.
    public let modelOptions: [AgentModelOption]
    /// Host-facing diagnostics for installation, setup, model listing, or trust checks.
    public let diagnostics: [String]

    /// Whether a harness executable is installed.
    public var isInstalled: Bool {
        installation == .installed
    }

    /// Whether harness-global setup is ready.
    public var isSetupReady: Bool {
        setup == .ready
    }

    /// Whether harness work can start for the scoped project.
    public var isReadyInProject: Bool {
        isEnabled && isInstalled && isSetupReady && (projectTrust?.allowsHarnessWork ?? true)
    }

    /// Creates a harness status snapshot.
    public init(
        harnessId: AgentHarnessID,
        definition: AgentHarnessDefinition? = nil,
        installation: AgentHarnessInstallationState = .unknown,
        availability: AgentHarnessAvailability? = nil,
        isEnabled: Bool = true,
        setup: AgentHarnessReadinessState = .unknown,
        projectTrust: AgentProjectTrustStatus? = nil,
        modelOptions: [AgentModelOption] = [],
        diagnostics: [String] = []
    ) {
        self.harnessId = harnessId
        self.definition = definition
        self.installation = installation
        self.availability = availability
        self.isEnabled = isEnabled
        self.setup = setup
        self.projectTrust = projectTrust
        self.modelOptions = modelOptions
        self.diagnostics = diagnostics
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case harnessId = "providerId"
        case definition
        case installation
        case availability
        case isEnabled
        case setup
        case projectTrust
        case modelOptions
        case diagnostics
    }
}

/// Contract for harness executable detection.
public protocol AgentHarnessExecutableDetecting: Sendable {
    /// Detects availability for every registered harness.
    func availability(for definitions: [AgentHarnessDefinition]) async -> [AgentHarnessAvailability]
}

extension AgentHarnessDetector: AgentHarnessExecutableDetecting {}

/// Source of host enablement state for harnesses.
public protocol AgentHarnessEnablementSource: Sendable {
    /// Returns whether the harness is enabled by host policy or settings.
    func isHarnessEnabled(_ harnessId: AgentHarnessID) async -> Bool
}

/// Static harness enablement source.
public struct StaticAgentHarnessEnablementSource: AgentHarnessEnablementSource {
    private let enabledHarnessIds: Set<AgentHarnessID>?

    /// Creates a static enablement source.
    /// - Parameter enabledHarnessIds: Enabled harnesses, or `nil` to enable all harnesses.
    public init(enabledHarnessIds: Set<AgentHarnessID>? = nil) {
        self.enabledHarnessIds = enabledHarnessIds
    }

    /// Returns whether the harness is enabled.
    public func isHarnessEnabled(_ harnessId: AgentHarnessID) async -> Bool {
        enabledHarnessIds?.contains(harnessId) ?? true
    }
}

/// Source of harness capabilities that may depend on detected executable state.
public protocol AgentHarnessCapabilitySource: Sendable {
    /// Returns the effective capabilities for a detected harness.
    func capabilities(for definition: AgentHarnessDefinition, availability: AgentHarnessAvailability?) async -> AgentHarnessCapabilities
}

/// Static harness capability source that returns each definition's built-in capabilities.
public struct StaticAgentHarnessCapabilitySource: AgentHarnessCapabilitySource {
    /// Creates a static capability source.
    public init() {}

    /// Returns the definition's static capabilities.
    public func capabilities(
        for definition: AgentHarnessDefinition,
        availability: AgentHarnessAvailability?
    ) async -> AgentHarnessCapabilities {
        definition.capabilities
    }
}

/// Built-in capability source that routes harness-specific dynamic checks.
public struct DefaultAgentHarnessCapabilitySource: AgentHarnessCapabilitySource {
    private let codexSource: any AgentHarnessCapabilitySource

    /// Creates the default capability source.
    /// - Parameter codexSource: Dynamic capability source for Codex.
    public init(codexSource: any AgentHarnessCapabilitySource = CodexHarnessCapabilitySource()) {
        self.codexSource = codexSource
    }

    /// Returns effective capabilities from the matching harness-specific source.
    public func capabilities(
        for definition: AgentHarnessDefinition,
        availability: AgentHarnessAvailability?
    ) async -> AgentHarnessCapabilities {
        switch definition.id {
        case .codex:
            await codexSource.capabilities(for: definition, availability: availability)
        case .claude:
            definition.capabilities
        }
    }
}

/// Source of selectable harness model options.
public protocol AgentModelOptionSource: Sendable {
    /// Returns model options for the harness.
    func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption]
}

/// Static model option source.
public struct StaticAgentModelOptionSource: AgentModelOptionSource {
    private let optionsByHarness: [AgentHarnessID: [AgentModelOption]]

    /// Creates a static model option source.
    public init(optionsByHarness: [AgentHarnessID: [AgentModelOption]] = [:]) {
        self.optionsByHarness = optionsByHarness
    }

    /// Returns static model options for the harness.
    public func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption] {
        optionsByHarness[harnessId] ?? AgentDefaultModelOptions.harnessDefault(for: harnessId)
    }
}

/// Built-in model option source that routes to harness-specific defaults.
public struct DefaultAgentModelOptionSource: AgentModelOptionSource {
    private let claudeSource: any AgentModelOptionSource
    private let codexSource: (any AgentModelOptionSource)?

    /// Creates the default model option source.
    /// - Parameters:
    ///   - claudeSource: Source for Claude model options.
    ///   - codexSource: Optional live or host-provided source for Codex model options.
    public init(
        claudeSource: any AgentModelOptionSource = ClaudeModelOptionSource(),
        codexSource: (any AgentModelOptionSource)? = nil
    ) {
        self.claudeSource = claudeSource
        self.codexSource = codexSource
    }

    /// Returns model options from the matching harness-specific source.
    public func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption] {
        switch harnessId {
        case .claude:
            return await claudeSource.modelOptions(for: harnessId)
        case .codex:
            guard let codexSource else {
                return AgentDefaultModelOptions.staticOptions(for: harnessId)
            }
            return await codexSource.modelOptions(for: harnessId)
        }
    }
}

/// Built-in static model options used as safe discovery fallbacks.
public enum AgentDefaultModelOptions {
    /// Returns the static model options a host can show before harness discovery completes.
    ///
    /// For harnesses whose catalog is authored in the package (Claude), this is exactly the list discovery later
    /// reports, so a cold-start UI and a discovered one render the same labels and effort ladders. Harnesses whose
    /// model list requires a live source (Codex) fall back to the single harness-default option.
    public static func staticOptions(for harnessId: AgentHarnessID) -> [AgentModelOption] {
        switch harnessId {
        case .claude:
            return ClaudeModelOptionSource.staticModelOptions
        case .codex:
            return harnessDefault(for: harnessId, description: "Use the Codex default model.")
        }
    }

    /// Returns a harness-default model option.
    public static func harnessDefault(
        for harnessId: AgentHarnessID,
        label: String = "Harness default",
        description: String? = nil
    ) -> [AgentModelOption] {
        [
            AgentModelOption(
                harnessId: harnessId,
                id: "default",
                model: nil,
                label: label,
                description: description,
                isDefault: true
            )
        ]
    }
}

/// Harness discovery utility for installation, enablement, setup, trust, and model options.
public protocol AgentHarnessDiscoveryService: Sendable {
    /// Returns statuses for all registered harnesses.
    func harnessStatuses(projectURL: URL?) async -> [AgentHarnessID: AgentHarnessStatus]

    /// Returns statuses for installed harnesses only.
    func installedHarnessStatuses(projectURL: URL?) async -> [AgentHarnessID: AgentHarnessStatus]

    /// Returns statuses for enabled harnesses whose installation is installed or unknown.
    func availableHarnessStatuses(projectURL: URL?) async -> [AgentHarnessID: AgentHarnessStatus]

    /// Returns model options for a harness.
    func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption]

    /// Returns stable harness ordering for UI consumers.
    func stableHarnessOrdering() async -> [AgentHarnessID]
}

/// Default harness discovery service backed by registry, detector, setup, trust, enablement, and model-option sources.
public struct DefaultAgentHarnessDiscoveryService: AgentHarnessDiscoveryService {
    private let harnessRegistry: any AgentHarnessLookup
    private let executableDetector: any AgentHarnessExecutableDetecting
    private let projectTrustService: any AgentProjectTrustService
    private let setupMap: [AgentHarnessID: any AgentHarnessSetup]
    private let enablementSource: any AgentHarnessEnablementSource
    private let modelOptionSource: any AgentModelOptionSource
    private let capabilitySource: any AgentHarnessCapabilitySource

    /// Creates a harness discovery service.
    public init(
        harnessRegistry: any AgentHarnessLookup = AgentHarnessRegistry.builtIn(),
        executableDetector: any AgentHarnessExecutableDetecting = AgentHarnessDetector(),
        projectTrustService: (any AgentProjectTrustService)? = nil,
        harnessSetups: [any AgentHarnessSetup] = [],
        enablementSource: any AgentHarnessEnablementSource = StaticAgentHarnessEnablementSource(),
        modelOptionSource: any AgentModelOptionSource = DefaultAgentModelOptionSource(),
        capabilitySource: any AgentHarnessCapabilitySource = DefaultAgentHarnessCapabilitySource()
    ) {
        self.harnessRegistry = harnessRegistry
        self.executableDetector = executableDetector
        self.projectTrustService = projectTrustService ?? DefaultAgentProjectTrustService(setups: harnessSetups)
        self.setupMap = Dictionary(harnessSetups.map { ($0.harnessId, $0) }, uniquingKeysWith: { _, new in new })
        self.enablementSource = enablementSource
        self.modelOptionSource = modelOptionSource
        self.capabilitySource = capabilitySource
    }

    /// Returns statuses for all registered harnesses.
    public func harnessStatuses(projectURL: URL? = nil) async -> [AgentHarnessID: AgentHarnessStatus] {
        let definitions = await harnessRegistry.allDefinitions()
        let availabilityByHarness = Dictionary(
            (await executableDetector.availability(for: definitions)).map { ($0.harnessId, $0) },
            uniquingKeysWith: { _, new in new }
        )
        var statuses: [AgentHarnessID: AgentHarnessStatus] = [:]
        for definition in definitions {
            statuses[definition.id] = await status(
                definition: definition,
                availability: availabilityByHarness[definition.id],
                projectURL: projectURL
            )
        }
        return statuses
    }

    /// Returns statuses for installed harnesses only.
    public func installedHarnessStatuses(projectURL: URL? = nil) async -> [AgentHarnessID: AgentHarnessStatus] {
        await harnessStatuses(projectURL: projectURL).filter { $0.value.isInstalled }
    }

    /// Returns statuses for enabled harnesses whose installation is installed or unknown.
    public func availableHarnessStatuses(projectURL: URL? = nil) async -> [AgentHarnessID: AgentHarnessStatus] {
        await harnessStatuses(projectURL: projectURL).filter { _, status in
            status.isEnabled && status.installation != .missing
        }
    }

    /// Returns model options for a harness.
    public func modelOptions(for harnessId: AgentHarnessID) async -> [AgentModelOption] {
        let options = await modelOptionSource.modelOptions(for: harnessId)
        return options.isEmpty ? AgentDefaultModelOptions.harnessDefault(for: harnessId) : options
    }

    /// Returns stable harness ordering for UI consumers.
    public func stableHarnessOrdering() async -> [AgentHarnessID] {
        await harnessRegistry.allDefinitions().map(\.id)
    }

    private func status(
        definition: AgentHarnessDefinition,
        availability: AgentHarnessAvailability?,
        projectURL: URL?
    ) async -> AgentHarnessStatus {
        let harnessId = definition.id
        let setup = await setupReadiness(harnessId: harnessId)
        let diagnostics = await diagnostics(definition: definition, availability: availability, setup: setup)
        let modelOptions = await modelOptions(for: harnessId)
        let capabilities = await capabilitySource.capabilities(for: definition, availability: availability)
        return AgentHarnessStatus(
            harnessId: harnessId,
            definition: definition.withCapabilities(capabilities),
            installation: installationState(availability),
            availability: availability,
            isEnabled: await enablementSource.isHarnessEnabled(harnessId),
            setup: setup,
            projectTrust: await projectTrustStatus(harnessId: harnessId, projectURL: projectURL),
            modelOptions: modelOptions,
            diagnostics: diagnostics
        )
    }

    private func installationState(_ availability: AgentHarnessAvailability?) -> AgentHarnessInstallationState {
        guard let availability else {
            return .unknown
        }
        return availability.isAvailable ? .installed : .missing
    }

    private func setupReadiness(harnessId: AgentHarnessID) async -> AgentHarnessReadinessState {
        guard let setup = setupMap[harnessId] else {
            return .ready
        }
        return await setup.setupReadiness()
    }

    private func projectTrustStatus(harnessId: AgentHarnessID, projectURL: URL?) async -> AgentProjectTrustStatus? {
        guard let projectURL else {
            return nil
        }
        return await projectTrustService.status(harnessId: harnessId, projectURL: projectURL)
    }

    private func diagnostics(
        definition: AgentHarnessDefinition,
        availability: AgentHarnessAvailability?,
        setup: AgentHarnessReadinessState
    ) async -> [String] {
        var diagnostics: [String] = []
        if availability?.isAvailable == false {
            diagnostics.append("No \(definition.displayName) executable was found. Checked: \(definition.executableNames.joined(separator: ", ")).")
        }
        if setup == .failed {
            diagnostics.append("\(definition.displayName) setup readiness check failed.")
        }
        if let setup = setupMap[definition.id] {
            diagnostics.append(contentsOf: await setup.setupDiagnostics())
        }
        return diagnostics
    }
}

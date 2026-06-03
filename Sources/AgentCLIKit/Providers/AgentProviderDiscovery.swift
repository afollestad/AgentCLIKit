import Foundation

/// Installation state for a provider executable.
public enum AgentProviderInstallationState: String, Codable, Hashable, Sendable {
    /// Installation has not been checked yet.
    case unknown
    /// A runnable provider executable was found.
    case installed
    /// No runnable provider executable was found.
    case missing
}

/// Selectable model metadata for host settings and thread creation UI.
public struct AgentModelOption: Codable, Equatable, Sendable {
    /// Provider this option belongs to.
    public let providerId: AgentProviderID
    /// Stable option identifier for host settings.
    public let id: String
    /// Provider model value to pass into `AgentSpawnConfig.model`, or `nil` to use the provider default.
    public let model: String?
    /// User-facing option label.
    public let label: String
    /// Optional user-facing option description.
    public let description: String?
    /// Known context-window size for this model.
    public let contextWindowSize: Int?
    /// Whether this option should be selected by default.
    public let isDefault: Bool
    /// Provider-specific metadata for hosts that need richer rendering.
    public let metadata: [String: JSONValue]

    /// Creates a model option.
    public init(
        providerId: AgentProviderID,
        id: String,
        model: String?,
        label: String,
        description: String? = nil,
        contextWindowSize: Int? = nil,
        isDefault: Bool = false,
        metadata: [String: JSONValue] = [:]
    ) {
        self.providerId = providerId
        self.id = id
        self.model = model
        self.label = label
        self.description = description
        self.contextWindowSize = contextWindowSize
        self.isDefault = isDefault
        self.metadata = metadata
    }
}

/// Full provider status snapshot for settings, setup, and provider/model selection UI.
public struct AgentProviderStatus: Codable, Equatable, Sendable {
    /// Provider represented by this status.
    public let providerId: AgentProviderID
    /// Static provider definition when registered.
    public let definition: AgentProviderDefinition?
    /// Installation state derived from provider executable detection.
    public let installation: AgentProviderInstallationState
    /// Latest executable availability when detection has run.
    public let availability: AgentProviderAvailability?
    /// Whether the host currently enables this provider.
    public let isEnabled: Bool
    /// Provider setup readiness separate from project trust.
    public let setup: AgentProviderReadinessState
    /// Project trust status when a project was supplied.
    public let projectTrust: AgentProjectTrustStatus?
    /// Selectable model options for this provider.
    public let modelOptions: [AgentModelOption]
    /// Host-facing diagnostics for installation, setup, model listing, or trust checks.
    public let diagnostics: [String]

    /// Whether a provider executable is installed.
    public var isInstalled: Bool {
        installation == .installed
    }

    /// Whether provider-global setup is ready.
    public var isSetupReady: Bool {
        setup == .ready
    }

    /// Whether provider work can start for the scoped project.
    public var isReadyInProject: Bool {
        isEnabled && isInstalled && isSetupReady && (projectTrust?.allowsProviderWork ?? true)
    }

    /// Creates a provider status snapshot.
    public init(
        providerId: AgentProviderID,
        definition: AgentProviderDefinition? = nil,
        installation: AgentProviderInstallationState = .unknown,
        availability: AgentProviderAvailability? = nil,
        isEnabled: Bool = true,
        setup: AgentProviderReadinessState = .unknown,
        projectTrust: AgentProjectTrustStatus? = nil,
        modelOptions: [AgentModelOption] = [],
        diagnostics: [String] = []
    ) {
        self.providerId = providerId
        self.definition = definition
        self.installation = installation
        self.availability = availability
        self.isEnabled = isEnabled
        self.setup = setup
        self.projectTrust = projectTrust
        self.modelOptions = modelOptions
        self.diagnostics = diagnostics
    }
}

/// Contract for provider executable detection.
public protocol AgentProviderExecutableDetecting: Sendable {
    /// Detects availability for every registered provider.
    func availability(for definitions: [AgentProviderDefinition]) async -> [AgentProviderAvailability]
}

extension AgentProviderDetector: AgentProviderExecutableDetecting {}

/// Source of host enablement state for providers.
public protocol AgentProviderEnablementSource: Sendable {
    /// Returns whether the provider is enabled by host policy or settings.
    func isProviderEnabled(_ providerId: AgentProviderID) async -> Bool
}

/// Static provider enablement source.
public struct StaticAgentProviderEnablementSource: AgentProviderEnablementSource {
    private let enabledProviderIds: Set<AgentProviderID>?

    /// Creates a static enablement source.
    /// - Parameter enabledProviderIds: Enabled providers, or `nil` to enable all providers.
    public init(enabledProviderIds: Set<AgentProviderID>? = nil) {
        self.enabledProviderIds = enabledProviderIds
    }

    /// Returns whether the provider is enabled.
    public func isProviderEnabled(_ providerId: AgentProviderID) async -> Bool {
        enabledProviderIds?.contains(providerId) ?? true
    }
}

/// Source of selectable provider model options.
public protocol AgentModelOptionSource: Sendable {
    /// Returns model options for the provider.
    func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption]
}

/// Static model option source.
public struct StaticAgentModelOptionSource: AgentModelOptionSource {
    private let optionsByProvider: [AgentProviderID: [AgentModelOption]]

    /// Creates a static model option source.
    public init(optionsByProvider: [AgentProviderID: [AgentModelOption]] = AgentDefaultModelOptions.optionsByProvider) {
        self.optionsByProvider = optionsByProvider
    }

    /// Returns static model options for the provider.
    public func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption] {
        optionsByProvider[providerId] ?? AgentDefaultModelOptions.providerDefault(for: providerId)
    }
}

/// Built-in static model options used as safe discovery fallbacks.
public enum AgentDefaultModelOptions {
    /// Static options keyed by provider.
    public static let optionsByProvider: [AgentProviderID: [AgentModelOption]] = [
        .claude: [
            AgentModelOption(
                providerId: .claude,
                id: "default",
                model: nil,
                label: "Provider default",
                description: "Use the Claude CLI default model.",
                isDefault: true
            ),
            AgentModelOption(
                providerId: .claude,
                id: "sonnet",
                model: "sonnet",
                label: "Sonnet",
                description: "Use Claude's Sonnet model alias."
            ),
            AgentModelOption(
                providerId: .claude,
                id: "opus",
                model: "opus",
                label: "Opus",
                description: "Use Claude's Opus model alias."
            )
        ],
        .codex: providerDefault(for: .codex, label: "Provider default", description: "Use the Codex default model.")
    ]

    /// Returns a provider-default model option.
    public static func providerDefault(
        for providerId: AgentProviderID,
        label: String = "Provider default",
        description: String? = nil
    ) -> [AgentModelOption] {
        [
            AgentModelOption(
                providerId: providerId,
                id: "default",
                model: nil,
                label: label,
                description: description,
                isDefault: true
            )
        ]
    }
}

/// Provider discovery utility for installation, enablement, setup, trust, and model options.
public protocol AgentProviderDiscoveryService: Sendable {
    /// Returns statuses for all registered providers.
    func providerStatuses(projectURL: URL?) async -> [AgentProviderID: AgentProviderStatus]

    /// Returns statuses for installed providers only.
    func installedProviderStatuses(projectURL: URL?) async -> [AgentProviderID: AgentProviderStatus]

    /// Returns statuses for enabled providers whose installation is installed or unknown.
    func availableProviderStatuses(projectURL: URL?) async -> [AgentProviderID: AgentProviderStatus]

    /// Returns model options for a provider.
    func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption]

    /// Returns stable provider ordering for UI consumers.
    func stableProviderOrdering() async -> [AgentProviderID]
}

/// Default provider discovery service backed by registry, detector, setup, trust, enablement, and model-option sources.
public struct DefaultAgentProviderDiscoveryService: AgentProviderDiscoveryService {
    private let providerRegistry: any AgentProviderLookup
    private let executableDetector: any AgentProviderExecutableDetecting
    private let projectTrustService: any AgentProjectTrustService
    private let setupMap: [AgentProviderID: any AgentProviderSetup]
    private let enablementSource: any AgentProviderEnablementSource
    private let modelOptionSource: any AgentModelOptionSource

    /// Creates a provider discovery service.
    public init(
        providerRegistry: any AgentProviderLookup = AgentProviderRegistry.builtIn(),
        executableDetector: any AgentProviderExecutableDetecting = AgentProviderDetector(),
        projectTrustService: (any AgentProjectTrustService)? = nil,
        providerSetups: [any AgentProviderSetup] = [],
        enablementSource: any AgentProviderEnablementSource = StaticAgentProviderEnablementSource(),
        modelOptionSource: any AgentModelOptionSource = StaticAgentModelOptionSource()
    ) {
        self.providerRegistry = providerRegistry
        self.executableDetector = executableDetector
        self.projectTrustService = projectTrustService ?? DefaultAgentProjectTrustService(setups: providerSetups)
        self.setupMap = Dictionary(providerSetups.map { ($0.providerId, $0) }, uniquingKeysWith: { _, new in new })
        self.enablementSource = enablementSource
        self.modelOptionSource = modelOptionSource
    }

    /// Returns statuses for all registered providers.
    public func providerStatuses(projectURL: URL? = nil) async -> [AgentProviderID: AgentProviderStatus] {
        let definitions = await providerRegistry.allDefinitions()
        let availabilityByProvider = Dictionary(
            (await executableDetector.availability(for: definitions)).map { ($0.providerId, $0) },
            uniquingKeysWith: { _, new in new }
        )
        var statuses: [AgentProviderID: AgentProviderStatus] = [:]
        for definition in definitions {
            statuses[definition.id] = await status(
                definition: definition,
                availability: availabilityByProvider[definition.id],
                projectURL: projectURL
            )
        }
        return statuses
    }

    /// Returns statuses for installed providers only.
    public func installedProviderStatuses(projectURL: URL? = nil) async -> [AgentProviderID: AgentProviderStatus] {
        await providerStatuses(projectURL: projectURL).filter { $0.value.isInstalled }
    }

    /// Returns statuses for enabled providers whose installation is installed or unknown.
    public func availableProviderStatuses(projectURL: URL? = nil) async -> [AgentProviderID: AgentProviderStatus] {
        await providerStatuses(projectURL: projectURL).filter { _, status in
            status.isEnabled && status.installation != .missing
        }
    }

    /// Returns model options for a provider.
    public func modelOptions(for providerId: AgentProviderID) async -> [AgentModelOption] {
        let options = await modelOptionSource.modelOptions(for: providerId)
        return options.isEmpty ? AgentDefaultModelOptions.providerDefault(for: providerId) : options
    }

    /// Returns stable provider ordering for UI consumers.
    public func stableProviderOrdering() async -> [AgentProviderID] {
        await providerRegistry.allDefinitions().map(\.id)
    }

    private func status(
        definition: AgentProviderDefinition,
        availability: AgentProviderAvailability?,
        projectURL: URL?
    ) async -> AgentProviderStatus {
        let providerId = definition.id
        let setup = await setupReadiness(providerId: providerId)
        let diagnostics = await diagnostics(definition: definition, availability: availability, setup: setup)
        let modelOptions = await modelOptions(for: providerId)
        return AgentProviderStatus(
            providerId: providerId,
            definition: definition,
            installation: installationState(availability),
            availability: availability,
            isEnabled: await enablementSource.isProviderEnabled(providerId),
            setup: setup,
            projectTrust: await projectTrustStatus(providerId: providerId, projectURL: projectURL),
            modelOptions: modelOptions,
            diagnostics: diagnostics
        )
    }

    private func installationState(_ availability: AgentProviderAvailability?) -> AgentProviderInstallationState {
        guard let availability else {
            return .unknown
        }
        return availability.isAvailable ? .installed : .missing
    }

    private func setupReadiness(providerId: AgentProviderID) async -> AgentProviderReadinessState {
        guard let setup = setupMap[providerId] else {
            return .ready
        }
        return await setup.setupReadiness()
    }

    private func projectTrustStatus(providerId: AgentProviderID, projectURL: URL?) async -> AgentProjectTrustStatus? {
        guard let projectURL else {
            return nil
        }
        return await projectTrustService.status(providerId: providerId, projectURL: projectURL)
    }

    private func diagnostics(
        definition: AgentProviderDefinition,
        availability: AgentProviderAvailability?,
        setup: AgentProviderReadinessState
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

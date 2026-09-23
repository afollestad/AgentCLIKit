import Foundation

/// Static metadata and capabilities for an agent CLI harness.
public struct AgentHarnessDefinition: Codable, Equatable, Sendable {
    /// Stable harness identifier.
    public let id: AgentHarnessID
    /// Display name for diagnostics and host UI.
    public let displayName: String
    /// Candidate executable names or absolute paths used for harness detection.
    public let executableNames: [String]
    /// Arguments used to query the harness executable version during detection.
    public let versionArguments: [String]
    /// Capabilities supported by the harness adapter.
    public let capabilities: AgentHarnessCapabilities
    /// Permission modes supported by the harness, when the harness exposes named modes.
    public let supportedPermissionModes: [AgentHarnessOption]?

    /// Creates a harness definition.
    public init(
        id: AgentHarnessID,
        displayName: String,
        executableNames: [String],
        versionArguments: [String] = ["--version"],
        capabilities: AgentHarnessCapabilities = AgentHarnessCapabilities(),
        supportedPermissionModes: [AgentHarnessOption]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.executableNames = executableNames
        self.versionArguments = versionArguments
        self.capabilities = capabilities
        self.supportedPermissionModes = supportedPermissionModes
    }

    /// Decodes harness metadata, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(AgentHarnessID.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.executableNames = try container.decode([String].self, forKey: .executableNames)
        self.versionArguments = try container.decodeIfPresent([String].self, forKey: .versionArguments) ?? ["--version"]
        self.capabilities = try container.decodeIfPresent(AgentHarnessCapabilities.self, forKey: .capabilities) ?? AgentHarnessCapabilities()
        self.supportedPermissionModes = try container.decodeIfPresent([AgentHarnessOption].self, forKey: .supportedPermissionModes)
    }
}

/// Harness features that host apps can inspect before enabling workflows.
public struct AgentHarnessCapabilities: Codable, Equatable, Sendable {
    /// Whether the harness supports resuming a previous harness session.
    public let supportsSessionResume: Bool
    /// Whether the harness supports local hook callbacks.
    public let supportsHooks: Bool
    /// Whether the harness can use MCP servers.
    public let supportsMCP: Bool
    /// Whether the harness can request host approval interactions.
    public let supportsApprovals: Bool
    /// Whether the harness exposes token or context-window usage.
    public let supportsUsage: Bool
    /// Whether the harness can accept user input while a turn is active.
    public let supportsMidTurnSteering: Bool
    /// Whether the harness emits harness-neutral tool call and tool result events.
    public let supportsToolEvents: Bool
    /// Whether the harness emits enough metadata to group tool output in transcripts.
    public let supportsGroupedToolOutput: Bool
    /// Whether the harness supports harness-neutral plan/default collaboration mode.
    public let supportsPlanMode: Bool
    /// Whether the harness supports harness-neutral standard/fast speed mode.
    public let supportsSpeedMode: Bool
    /// Whether the harness supports harness-neutral goal mode.
    public let supportsGoalMode: Bool
    /// Whether an already-running harness session can start a new goal without respawning as a first turn.
    public let supportsExistingSessionGoalStart: Bool
    /// Harness-native goal actions supported by this harness/session.
    public let supportedGoalActions: [AgentGoalAction]
    /// Whether the harness emits task-list or todo snapshots.
    public let supportsTaskLists: Bool
    /// Whether the harness emits harness-neutral sub-agent lifecycle events.
    public let supportsSubagents: Bool
    /// Whether the harness can request host-provided prompt answers.
    public let supportsPromptRequests: Bool
    /// Whether the harness reports context-window usage or limits.
    public let supportsContextWindow: Bool
    /// Whether the harness emits context compaction lifecycle events.
    public let supportsContextCompaction: Bool
    /// Whether the harness can fork a native harness thread or session.
    public let supportsNativeThreadFork: Bool
    /// Whether the harness can ask the host to grant permission profiles or modes.
    public let supportsPermissionPrompts: Bool
    /// Whether the harness exposes selectable model options.
    public let supportsModelOptions: Bool
    /// Whether the harness can archive a native harness session.
    public let supportsSessionArchiving: Bool
    /// Whether the harness can unarchive a native harness session.
    public let supportsSessionUnarchiving: Bool
    /// Whether the harness can delete a native harness session.
    public let supportsSessionDeletion: Bool
    /// Whether the harness can receive local image files as structured message attachments.
    public let supportsLocalImageInput: Bool
    /// Whether utility prompts enforce read-only tools without creating a persistent session.
    public let supportsReadOnlyOneShotPrompts: Bool
    /// Integration isolation options this harness honors per conversation.
    public let supportedIntegrationIsolation: AgentIntegrationIsolation

    /// Creates harness capability metadata.
    public init(
        supportsSessionResume: Bool = false,
        supportsHooks: Bool = false,
        supportsMCP: Bool = false,
        supportsApprovals: Bool = false,
        supportsUsage: Bool = false,
        supportsMidTurnSteering: Bool = false,
        supportsToolEvents: Bool = false,
        supportsGroupedToolOutput: Bool = false,
        supportsPlanMode: Bool = false,
        supportsSpeedMode: Bool = false,
        supportsGoalMode: Bool = false,
        supportsExistingSessionGoalStart: Bool = false,
        supportedGoalActions: [AgentGoalAction] = [],
        supportsTaskLists: Bool = false,
        supportsSubagents: Bool = false,
        supportsPromptRequests: Bool = false,
        supportsContextWindow: Bool = false,
        supportsContextCompaction: Bool = false,
        supportsNativeThreadFork: Bool = false,
        supportsPermissionPrompts: Bool = false,
        supportsModelOptions: Bool = false,
        supportsSessionArchiving: Bool = false,
        supportsSessionUnarchiving: Bool = false,
        supportsSessionDeletion: Bool = false,
        supportsLocalImageInput: Bool = false,
        supportsReadOnlyOneShotPrompts: Bool = false,
        supportedIntegrationIsolation: AgentIntegrationIsolation = []
    ) {
        self.supportsSessionResume = supportsSessionResume
        self.supportsHooks = supportsHooks
        self.supportsMCP = supportsMCP
        self.supportsApprovals = supportsApprovals
        self.supportsUsage = supportsUsage
        self.supportsMidTurnSteering = supportsMidTurnSteering
        self.supportsToolEvents = supportsToolEvents
        self.supportsGroupedToolOutput = supportsGroupedToolOutput
        self.supportsPlanMode = supportsPlanMode
        self.supportsSpeedMode = supportsSpeedMode
        self.supportsGoalMode = supportsGoalMode
        self.supportsExistingSessionGoalStart = supportsExistingSessionGoalStart
        self.supportedGoalActions = supportedGoalActions
        self.supportsTaskLists = supportsTaskLists
        self.supportsSubagents = supportsSubagents
        self.supportsPromptRequests = supportsPromptRequests
        self.supportsContextWindow = supportsContextWindow
        self.supportsContextCompaction = supportsContextCompaction
        self.supportsNativeThreadFork = supportsNativeThreadFork
        self.supportsPermissionPrompts = supportsPermissionPrompts
        self.supportsModelOptions = supportsModelOptions
        self.supportsSessionArchiving = supportsSessionArchiving
        self.supportsSessionUnarchiving = supportsSessionUnarchiving
        self.supportsSessionDeletion = supportsSessionDeletion
        self.supportsLocalImageInput = supportsLocalImageInput
        self.supportsReadOnlyOneShotPrompts = supportsReadOnlyOneShotPrompts
        self.supportedIntegrationIsolation = supportedIntegrationIsolation
    }

    /// Decodes capability metadata, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.supportsSessionResume = try container.decodeIfPresent(Bool.self, forKey: .supportsSessionResume) ?? false
        self.supportsHooks = try container.decodeIfPresent(Bool.self, forKey: .supportsHooks) ?? false
        self.supportsMCP = try container.decodeIfPresent(Bool.self, forKey: .supportsMCP) ?? false
        self.supportsApprovals = try container.decodeIfPresent(Bool.self, forKey: .supportsApprovals) ?? false
        self.supportsUsage = try container.decodeIfPresent(Bool.self, forKey: .supportsUsage) ?? false
        self.supportsMidTurnSteering = try container.decodeIfPresent(Bool.self, forKey: .supportsMidTurnSteering) ?? false
        self.supportsToolEvents = try container.decodeIfPresent(Bool.self, forKey: .supportsToolEvents) ?? false
        self.supportsGroupedToolOutput = try container.decodeIfPresent(Bool.self, forKey: .supportsGroupedToolOutput) ?? false
        self.supportsPlanMode = try container.decodeIfPresent(Bool.self, forKey: .supportsPlanMode) ?? false
        self.supportsSpeedMode = try container.decodeIfPresent(Bool.self, forKey: .supportsSpeedMode) ?? false
        self.supportsGoalMode = try container.decodeIfPresent(Bool.self, forKey: .supportsGoalMode) ?? false
        self.supportsExistingSessionGoalStart = try container.decodeIfPresent(
            Bool.self,
            forKey: .supportsExistingSessionGoalStart
        ) ?? false
        self.supportedGoalActions = try container.decodeIfPresent([AgentGoalAction].self, forKey: .supportedGoalActions) ?? []
        self.supportsTaskLists = try container.decodeIfPresent(Bool.self, forKey: .supportsTaskLists) ?? false
        self.supportsSubagents = try container.decodeIfPresent(Bool.self, forKey: .supportsSubagents) ?? false
        self.supportsPromptRequests = try container.decodeIfPresent(Bool.self, forKey: .supportsPromptRequests) ?? false
        self.supportsContextWindow = try container.decodeIfPresent(Bool.self, forKey: .supportsContextWindow) ?? false
        self.supportsContextCompaction = try container.decodeIfPresent(Bool.self, forKey: .supportsContextCompaction) ?? false
        self.supportsNativeThreadFork = try container.decodeIfPresent(Bool.self, forKey: .supportsNativeThreadFork) ?? false
        self.supportsPermissionPrompts = try container.decodeIfPresent(Bool.self, forKey: .supportsPermissionPrompts) ?? false
        self.supportsModelOptions = try container.decodeIfPresent(Bool.self, forKey: .supportsModelOptions)
            ?? (try container.decodeIfPresent(Bool.self, forKey: .supportsModelListing) ?? false)
        self.supportsSessionArchiving = try container.decodeIfPresent(Bool.self, forKey: .supportsSessionArchiving) ?? false
        self.supportsSessionUnarchiving = try container.decodeIfPresent(Bool.self, forKey: .supportsSessionUnarchiving) ?? false
        self.supportsSessionDeletion = try container.decodeIfPresent(Bool.self, forKey: .supportsSessionDeletion) ?? false
        self.supportsLocalImageInput = try container.decodeIfPresent(Bool.self, forKey: .supportsLocalImageInput) ?? false
        self.supportsReadOnlyOneShotPrompts = try container.decodeIfPresent(Bool.self, forKey: .supportsReadOnlyOneShotPrompts) ?? false
        self.supportedIntegrationIsolation = try container.decodeIfPresent(
            AgentIntegrationIsolation.self,
            forKey: .supportedIntegrationIsolation
        ) ?? []
    }

    /// Encodes capability metadata using current public keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(supportsSessionResume, forKey: .supportsSessionResume)
        try container.encode(supportsHooks, forKey: .supportsHooks)
        try container.encode(supportsMCP, forKey: .supportsMCP)
        try container.encode(supportsApprovals, forKey: .supportsApprovals)
        try container.encode(supportsUsage, forKey: .supportsUsage)
        try container.encode(supportsMidTurnSteering, forKey: .supportsMidTurnSteering)
        try container.encode(supportsToolEvents, forKey: .supportsToolEvents)
        try container.encode(supportsGroupedToolOutput, forKey: .supportsGroupedToolOutput)
        try container.encode(supportsPlanMode, forKey: .supportsPlanMode)
        try container.encode(supportsSpeedMode, forKey: .supportsSpeedMode)
        try container.encode(supportsGoalMode, forKey: .supportsGoalMode)
        try container.encode(supportsExistingSessionGoalStart, forKey: .supportsExistingSessionGoalStart)
        try container.encode(supportedGoalActions, forKey: .supportedGoalActions)
        try container.encode(supportsTaskLists, forKey: .supportsTaskLists)
        try container.encode(supportsSubagents, forKey: .supportsSubagents)
        try container.encode(supportsPromptRequests, forKey: .supportsPromptRequests)
        try container.encode(supportsContextWindow, forKey: .supportsContextWindow)
        try container.encode(supportsContextCompaction, forKey: .supportsContextCompaction)
        try container.encode(supportsNativeThreadFork, forKey: .supportsNativeThreadFork)
        try container.encode(supportsPermissionPrompts, forKey: .supportsPermissionPrompts)
        try container.encode(supportsModelOptions, forKey: .supportsModelOptions)
        try container.encode(supportsSessionArchiving, forKey: .supportsSessionArchiving)
        try container.encode(supportsSessionUnarchiving, forKey: .supportsSessionUnarchiving)
        try container.encode(supportsSessionDeletion, forKey: .supportsSessionDeletion)
        try container.encode(supportsLocalImageInput, forKey: .supportsLocalImageInput)
        try container.encode(supportsReadOnlyOneShotPrompts, forKey: .supportsReadOnlyOneShotPrompts)
        try container.encode(supportedIntegrationIsolation, forKey: .supportedIntegrationIsolation)
    }

    private enum CodingKeys: String, CodingKey {
        case supportsSessionResume
        case supportsHooks
        case supportsMCP
        case supportsApprovals
        case supportsUsage
        case supportsMidTurnSteering
        case supportsToolEvents
        case supportsGroupedToolOutput
        case supportsPlanMode
        case supportsSpeedMode
        case supportsGoalMode
        case supportsExistingSessionGoalStart
        case supportedGoalActions
        case supportsTaskLists
        case supportsSubagents
        case supportsPromptRequests
        case supportsContextWindow
        case supportsContextCompaction
        case supportsNativeThreadFork
        case supportsPermissionPrompts
        case supportsModelOptions
        case supportsModelListing
        case supportsSessionArchiving
        case supportsSessionUnarchiving
        case supportsSessionDeletion
        case supportsLocalImageInput
        case supportsReadOnlyOneShotPrompts
        case supportedIntegrationIsolation
    }
}

extension AgentHarnessCapabilities {
    func withSpeedModeSupport(_ supportsSpeedMode: Bool) -> AgentHarnessCapabilities {
        AgentHarnessCapabilities(
            supportsSessionResume: self.supportsSessionResume,
            supportsHooks: self.supportsHooks,
            supportsMCP: self.supportsMCP,
            supportsApprovals: self.supportsApprovals,
            supportsUsage: self.supportsUsage,
            supportsMidTurnSteering: self.supportsMidTurnSteering,
            supportsToolEvents: self.supportsToolEvents,
            supportsGroupedToolOutput: self.supportsGroupedToolOutput,
            supportsPlanMode: self.supportsPlanMode,
            supportsSpeedMode: supportsSpeedMode,
            supportsGoalMode: self.supportsGoalMode,
            supportsExistingSessionGoalStart: self.supportsExistingSessionGoalStart,
            supportedGoalActions: self.supportedGoalActions,
            supportsTaskLists: self.supportsTaskLists,
            supportsSubagents: self.supportsSubagents,
            supportsPromptRequests: self.supportsPromptRequests,
            supportsContextWindow: self.supportsContextWindow,
            supportsContextCompaction: self.supportsContextCompaction,
            supportsNativeThreadFork: self.supportsNativeThreadFork,
            supportsPermissionPrompts: self.supportsPermissionPrompts,
            supportsModelOptions: self.supportsModelOptions,
            supportsSessionArchiving: self.supportsSessionArchiving,
            supportsSessionUnarchiving: self.supportsSessionUnarchiving,
            supportsSessionDeletion: self.supportsSessionDeletion,
            supportsLocalImageInput: self.supportsLocalImageInput,
            supportsReadOnlyOneShotPrompts: self.supportsReadOnlyOneShotPrompts,
            supportedIntegrationIsolation: self.supportedIntegrationIsolation
        )
    }

    func withGoalModeSupport(
        _ supportsGoalMode: Bool,
        supportsExistingSessionGoalStart: Bool? = nil,
        supportedGoalActions: [AgentGoalAction]
    ) -> AgentHarnessCapabilities {
        AgentHarnessCapabilities(
            supportsSessionResume: self.supportsSessionResume,
            supportsHooks: self.supportsHooks,
            supportsMCP: self.supportsMCP,
            supportsApprovals: self.supportsApprovals,
            supportsUsage: self.supportsUsage,
            supportsMidTurnSteering: self.supportsMidTurnSteering,
            supportsToolEvents: self.supportsToolEvents,
            supportsGroupedToolOutput: self.supportsGroupedToolOutput,
            supportsPlanMode: self.supportsPlanMode,
            supportsSpeedMode: self.supportsSpeedMode,
            supportsGoalMode: supportsGoalMode,
            supportsExistingSessionGoalStart: supportsGoalMode
                && (supportsExistingSessionGoalStart ?? self.supportsExistingSessionGoalStart),
            supportedGoalActions: supportsGoalMode ? supportedGoalActions : [],
            supportsTaskLists: self.supportsTaskLists,
            supportsSubagents: self.supportsSubagents,
            supportsPromptRequests: self.supportsPromptRequests,
            supportsContextWindow: self.supportsContextWindow,
            supportsContextCompaction: self.supportsContextCompaction,
            supportsNativeThreadFork: self.supportsNativeThreadFork,
            supportsPermissionPrompts: self.supportsPermissionPrompts,
            supportsModelOptions: self.supportsModelOptions,
            supportsSessionArchiving: self.supportsSessionArchiving,
            supportsSessionUnarchiving: self.supportsSessionUnarchiving,
            supportsSessionDeletion: self.supportsSessionDeletion,
            supportsLocalImageInput: self.supportsLocalImageInput,
            supportsReadOnlyOneShotPrompts: self.supportsReadOnlyOneShotPrompts,
            supportedIntegrationIsolation: self.supportedIntegrationIsolation
        )
    }
}

extension AgentHarnessDefinition {
    func withCapabilities(_ capabilities: AgentHarnessCapabilities) -> AgentHarnessDefinition {
        AgentHarnessDefinition(
            id: id,
            displayName: displayName,
            executableNames: executableNames,
            versionArguments: versionArguments,
            capabilities: capabilities,
            supportedPermissionModes: supportedPermissionModes
        )
    }
}

/// User-facing harness option metadata for host settings and launch controls.
public struct AgentHarnessOption: Codable, Equatable, Sendable {
    /// Harness wire value.
    public let value: String
    /// Short label for host UI.
    public let label: String
    /// Longer host-facing description.
    public let description: String

    /// Creates harness option metadata.
    public init(value: String, label: String, description: String) {
        self.value = value
        self.label = label
        self.description = description
    }
}

/// Harness availability result returned by detection services.
public struct AgentHarnessAvailability: Codable, Equatable, Sendable {
    /// Harness that was checked.
    public let harnessId: AgentHarnessID
    /// Resolved executable path when available.
    public let executablePath: String?
    /// Version output returned by the harness when requested.
    public let versionDescription: String?

    /// Whether an executable was found.
    public var isAvailable: Bool {
        executablePath != nil
    }

    /// Creates a harness availability value.
    public init(harnessId: AgentHarnessID, executablePath: String?, versionDescription: String? = nil) {
        self.harnessId = harnessId
        self.executablePath = executablePath
        self.versionDescription = versionDescription
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case harnessId = "providerId"
        case executablePath
        case versionDescription
    }
}

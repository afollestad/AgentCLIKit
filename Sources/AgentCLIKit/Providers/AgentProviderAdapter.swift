import Foundation

/// Provider adapter used by the generic runtime to launch, decode, and encode a CLI.
public protocol AgentProviderAdapter: Sendable {
    /// Static metadata for this provider.
    var definition: AgentProviderDefinition { get }

    /// Builds the launch configuration for a session.
    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration

    /// Gives the provider a chance to augment a launch before the runtime starts the process.
    /// - Parameters:
    ///   - launch: Base launch configuration returned by `makeLaunchConfiguration(spawnConfig:resumedSession:)`.
    ///   - spawnConfig: Host spawn configuration for the conversation.
    ///   - conversationId: Runtime conversation identifier for the launch.
    ///   - processToken: Runtime-scoped token that identifies this specific process generation.
    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration

    /// Decodes one complete stdout line into provider-neutral events.
    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent]

    /// Extracts a provider session identifier from a decoded event when the provider reports one.
    func sessionID(from event: AgentEvent) -> AgentSessionID?

    /// Encodes host input into provider stdin data.
    func encodeInput(_ input: AgentInput) async throws -> Data

    /// Notifies the provider that runtime-observed permission mode changed for a conversation.
    func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async

    /// Notifies the provider that a process generation has ended or been superseded.
    func processDidTerminate(processToken: UUID) async

    /// Shuts down provider-owned resources retained across process launches.
    func shutdownProviderResources() async
}

/// Default behavior for optional provider adapter capabilities.
public extension AgentProviderAdapter {
    /// Returns the launch unchanged for providers that do not need runtime-managed launch augmentation.
    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        launch
    }

    /// Returns no session identifier for providers that do not expose resumable sessions in events.
    func sessionID(from event: AgentEvent) -> AgentSessionID? {
        nil
    }

    /// Does nothing for providers without permission-mode-sensitive runtime resources.
    func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async {}

    /// Does nothing for providers that do not retain process-scoped resources.
    func processDidTerminate(processToken: UUID) async {}

    /// Does nothing for providers that do not retain shared runtime resources.
    func shutdownProviderResources() async {}
}

/// Process launch configuration produced by a provider adapter.
public struct AgentLaunchConfiguration: Codable, Equatable, Sendable {
    /// Executable path to run.
    public let executable: String
    /// Command-line arguments.
    public let arguments: [String]
    /// Environment overrides.
    public let environment: [String: String]
    /// Working directory for the process.
    public let workingDirectory: URL?
    /// Provider session continuity outcome for this launch when known.
    public let sessionContinuity: AgentSessionContinuity?
    /// Whether `arguments` already include `AgentSpawnConfig.arguments`.
    public let includesSpawnArguments: Bool

    /// Creates a launch configuration.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        sessionContinuity: AgentSessionContinuity? = nil,
        includesSpawnArguments: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.sessionContinuity = sessionContinuity
        self.includesSpawnArguments = includesSpawnArguments
    }

    /// Decodes launch configuration, defaulting newer optional fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.executable = try container.decode(String.self, forKey: .executable)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        self.workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
        self.sessionContinuity = try container.decodeIfPresent(AgentSessionContinuity.self, forKey: .sessionContinuity)
        self.includesSpawnArguments = try container.decodeIfPresent(Bool.self, forKey: .includesSpawnArguments) ?? false
    }
}

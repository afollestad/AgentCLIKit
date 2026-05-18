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

    /// Decodes one complete stdout line into provider-neutral events.
    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent]

    /// Extracts a provider session identifier from a decoded event when the provider reports one.
    func sessionID(from event: AgentEvent) -> AgentSessionID?

    /// Encodes host input into provider stdin data.
    func encodeInput(_ input: AgentInput) async throws -> Data
}

/// Default behavior for optional provider adapter capabilities.
public extension AgentProviderAdapter {
    /// Returns no session identifier for providers that do not expose resumable sessions in events.
    func sessionID(from event: AgentEvent) -> AgentSessionID? {
        nil
    }
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

    /// Creates a launch configuration.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

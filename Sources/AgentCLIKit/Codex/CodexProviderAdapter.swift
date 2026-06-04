import Foundation

/// Codex provider adapter backed by Codex App Server.
public struct CodexProviderAdapter: AgentProviderAdapter {
    /// Codex provider identifier.
    public static let providerId = CodexProviderDefinition.providerId

    /// Configuration used to create a Codex provider adapter.
    public struct Configuration: Sendable {
        /// Codex executable path, or `/usr/bin/env` to resolve `codex` through `PATH`.
        public let executablePath: String
        /// Optional Codex home directory override, primarily for tests.
        public let codexHomeDirectory: URL?
        /// Additional environment values used for the App Server process.
        public let environment: [String: String]
        /// Whether App Server experimental APIs are enabled during initialization.
        public let experimentalAPIEnabled: Bool
        /// Maximum time to wait for App Server requests.
        public let requestTimeout: TimeInterval
        /// Maximum time to wait for App Server startup or probe requests.
        public let probeTimeout: TimeInterval
        /// Maximum time to wait for App Server shutdown.
        public let shutdownTimeout: TimeInterval
        /// Transport family used by this adapter.
        public let transportKind: CodexAppServerTransportKind
        /// Factory used to create the transport lazily.
        public let makeTransport: @Sendable (Configuration) -> any CodexAppServerTransport

        /// Creates a Codex adapter configuration.
        public init(
            executablePath: String = "/usr/bin/env",
            codexHomeDirectory: URL? = nil,
            environment: [String: String] = [:],
            experimentalAPIEnabled: Bool = true,
            requestTimeout: TimeInterval = 30,
            probeTimeout: TimeInterval = 10,
            shutdownTimeout: TimeInterval = 5,
            transportKind: CodexAppServerTransportKind = .stdio,
            makeTransport: (@Sendable (Configuration) -> any CodexAppServerTransport)? = nil
        ) {
            self.executablePath = executablePath
            self.codexHomeDirectory = codexHomeDirectory
            self.environment = environment
            self.experimentalAPIEnabled = experimentalAPIEnabled
            self.requestTimeout = requestTimeout
            self.probeTimeout = probeTimeout
            self.shutdownTimeout = shutdownTimeout
            self.transportKind = transportKind
            self.makeTransport = makeTransport ?? { CodexStdioAppServerTransport(configuration: $0) }
        }
    }

    /// Static Codex provider metadata.
    public let definition = CodexProviderDefinition.definition

    private let client: CodexAppServerClient

    /// Creates a Codex provider adapter.
    public init(configuration: Configuration = Configuration()) {
        self.client = CodexAppServerClient(configuration: configuration)
    }

    /// Bootstraps or resumes a Codex App Server thread and returns a lightweight runtime sentinel process.
    public func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        let bootstrap = try await client.bootstrapThread(spawnConfig: spawnConfig, resumedSession: resumedSession)
        return AgentLaunchConfiguration(
            executable: "/usr/bin/env",
            arguments: [
                "sh",
                "-c",
                "printf '%s\\n' \"$1\"; sleep 2147483647",
                "codex-bootstrap",
                try Self.bootstrapLine(threadId: bootstrap.threadId)
            ],
            workingDirectory: spawnConfig.workingDirectory,
            sessionContinuity: bootstrap.continuity,
            providerSessionId: bootstrap.threadId,
            includesSpawnArguments: true
        )
    }

    /// Decodes Codex bootstrap sentinel output.
    public func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CodexBootstrapPayload.self, from: data),
              payload.codexAppServerBootstrap == true else {
            return [.rawOutput(AgentRawOutputEvent(text: line, isComplete: true))]
        }
        return [.diagnostic(AgentDiagnosticEvent(
            severity: .info,
            message: "Codex App Server thread bootstrapped.",
            metadata: [
                "codex_thread_id": .string(payload.threadId),
                "provider_session_id": .string(payload.threadId)
            ]
        ))]
    }

    /// Extracts Codex's App Server thread identifier from bootstrap diagnostics.
    public func sessionID(from event: AgentEvent) -> AgentSessionID? {
        guard case let .diagnostic(diagnostic) = event,
              case let .string(threadId)? = diagnostic.metadata["codex_thread_id"],
              !threadId.isEmpty else {
            return nil
        }
        return AgentSessionID(rawValue: threadId)
    }

    /// Encodes no process stdin bytes because Codex turns are sent through App Server requests.
    public func encodeInput(_ input: AgentInput) async throws -> Data {
        throw AgentCLIError.invalidInput("Codex App Server input requires runtime context.")
    }

    /// Sends Codex input through App Server `turn/start`, `turn/steer`, or related requests.
    public func encodeInput(_ input: AgentInput, context: AgentProviderInputContext) async throws -> Data {
        try await client.send(input, context: context)
        return Data()
    }

    /// Returns Codex App Server notification events for the bound runtime conversation.
    public func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        await client.runtimeEvents(context: context)
    }

    /// Interrupts the active Codex App Server turn.
    public func interrupt(context: AgentProviderInterruptContext) async throws {
        try await client.interrupt(context: context)
    }

    /// Archives a Codex App Server thread without starting or resuming a runtime session.
    public func archiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
        try await client.archiveThread(record.providerSessionId)
    }

    /// Unarchives a Codex App Server thread without starting or resuming a runtime session.
    public func unarchiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
        try await client.unarchiveThread(record.providerSessionId)
    }

    /// Stops the shared App Server transport.
    public func shutdownProviderResources() async {
        await client.shutdown()
    }

    private static func bootstrapLine(threadId: AgentSessionID) throws -> String {
        let payload = CodexBootstrapPayload(codexAppServerBootstrap: true, threadId: threadId.rawValue)
        let data = try JSONEncoder().encode(payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw AgentCLIError.invalidInput("Could not encode Codex bootstrap line.")
        }
        return line
    }
}

private struct CodexBootstrapPayload: Codable {
    let codexAppServerBootstrap: Bool
    let threadId: String
}

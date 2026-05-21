import Foundation

/// Claude Code provider adapter.
public struct ClaudeProviderAdapter: AgentProviderAdapter {
    /// Claude provider identifier.
    public static let providerId: AgentProviderID = "claude"

    /// Static Claude provider metadata.
    public let definition = AgentProviderDefinition(
        id: ClaudeProviderAdapter.providerId,
        displayName: "Claude",
        executableNames: ["claude"],
        capabilities: AgentProviderCapabilities(
            supportsSessionResume: true,
            supportsHooks: true,
            supportsMCP: true,
            supportsApprovals: true,
            supportsUsage: true
        )
    )

    private let executablePath: String
    private let decoder: ClaudeStreamDecoder
    private let inputEncoder: ClaudeInputEncoder
    private let homeDirectory: URL
    private let sessionFileExists: @Sendable (URL) -> Bool

    /// Creates a Claude provider adapter.
    /// - Parameters:
    ///   - executablePath: Claude executable path, or `/usr/bin/env` to resolve `claude` through PATH.
    ///   - decoder: Stream JSON decoder.
    ///   - inputEncoder: Stream JSON input encoder.
    ///   - homeDirectory: Home directory containing `.claude/projects`.
    ///   - sessionFileExists: Predicate used to decide whether a saved Claude session can be resumed.
    public init(
        executablePath: String = "/usr/bin/env",
        decoder: ClaudeStreamDecoder = ClaudeStreamDecoder(),
        inputEncoder: ClaudeInputEncoder = ClaudeInputEncoder(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sessionFileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.executablePath = executablePath
        self.decoder = decoder
        self.inputEncoder = inputEncoder
        self.homeDirectory = homeDirectory
        self.sessionFileExists = sessionFileExists
    }

    /// Builds the Claude launch configuration for stream JSON mode.
    public func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        var arguments: [String] = executablePath == "/usr/bin/env" ? ["claude"] : []
        arguments.append(contentsOf: [
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages"
        ])
        if let model = spawnConfig.model {
            arguments.append(contentsOf: ["--model", model])
        }
        if let effort = spawnConfig.effort {
            arguments.append(contentsOf: ["--effort", effort])
        }
        var sessionContinuity: AgentSessionContinuity = resumedSession == nil ? .fresh : .resumed
        if let sessionId = resumedSession?.providerSessionId {
            let sessionFileURL = ClaudePathEncoder.sessionFileURL(
                sessionId: sessionId,
                workingDirectory: spawnConfig.workingDirectory,
                homeDirectory: homeDirectory
            )
            let canResume = sessionFileExists(sessionFileURL)
            sessionContinuity = canResume ? .resumed : .restartedFresh
            let sessionArguments = canResume ? ["--resume", sessionId.rawValue] : ["--session-id", sessionId.rawValue]
            arguments.append(contentsOf: sessionArguments)
        }
        if let initialPrompt = spawnConfig.initialPrompt {
            arguments.append(initialPrompt)
        }
        return AgentLaunchConfiguration(
            executable: executablePath,
            arguments: arguments,
            environment: spawnConfig.environment,
            workingDirectory: spawnConfig.workingDirectory,
            sessionContinuity: sessionContinuity
        )
    }

    /// Decodes one Claude stream JSON stdout line.
    public func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        try decoder.decodeLine(line)
    }

    /// Extracts Claude's resumable session identifier from system events.
    public func sessionID(from event: AgentEvent) -> AgentSessionID? {
        guard
            case let .diagnostic(diagnostic) = event,
            case let .string(sessionId)? = diagnostic.metadata["session_id"],
            !sessionId.isEmpty
        else {
            return nil
        }
        return AgentSessionID(rawValue: sessionId)
    }

    /// Encodes host input as Claude stream JSON stdin.
    public func encodeInput(_ input: AgentInput) async throws -> Data {
        try inputEncoder.encode(input)
    }
}

/// Helper for paths passed to Claude metadata.
public enum ClaudePathEncoder {
    /// Encodes a file URL as a standardized path string.
    public static func encode(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Encodes a canonical project path into Claude's project-directory name.
    public static func projectDirectoryName(forCanonicalPath path: String) -> String {
        path.unicodeScalars.map { scalar in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                String(scalar)
            } else {
                "-"
            }
        }
        .joined()
    }

    /// Returns Claude's JSONL session file URL for a session and working directory.
    public static func sessionFileURL(sessionId: AgentSessionID, workingDirectory: URL, homeDirectory: URL) -> URL {
        let encodedDirectory = projectDirectoryName(forCanonicalPath: encode(workingDirectory))
        return homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedDirectory, isDirectory: true)
            .appendingPathComponent("\(sessionId.rawValue).jsonl")
    }
}

import Foundation

/// Launch-time Claude hook settings and token data.
public struct ClaudeHookLaunchConfiguration: Codable, Equatable, Sendable {
    /// Additional Claude arguments, including `--settings`.
    public let arguments: [String]
    /// Environment values required by generated hook settings.
    public let environment: [String: String]
    /// Bearer token scoped to this Claude launch.
    public let token: String
    /// Settings file generated for this launch.
    public let settingsFileURL: URL

    /// Creates a Claude hook launch configuration.
    public init(arguments: [String], environment: [String: String], token: String, settingsFileURL: URL) {
        self.arguments = arguments
        self.environment = environment
        self.token = token
        self.settingsFileURL = settingsFileURL
    }
}

/// Runtime-owned coordinator for Claude hook listener and per-launch settings.
public actor ClaudeHookCoordinator {
    private let tokenStore: AgentHookTokenStore
    private let server: ClaudeHookServer
    private let supportDirectory: URL
    private let fileManager: FileManager
    private let makeListener: @Sendable (ClaudeHookServer, Int) -> any ClaudeHookListeningTransport
    private var listener: (any ClaudeHookListeningTransport)?
    private var listenerPort: Int?
    private var launchTokens: [UUID: String] = [:]
    private var launchSettingsFiles: [UUID: URL] = [:]

    /// Creates a Claude hook coordinator.
    public init(
        tokenStore: AgentHookTokenStore,
        server: ClaudeHookServer,
        supportDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCLIKitClaudeHooks", isDirectory: true),
        fileManager: FileManager = .default,
        makeListener: @escaping @Sendable (ClaudeHookServer, Int) -> any ClaudeHookListeningTransport = { server, maxBodyBytes in
            ClaudeHookHTTPListener(server: server, maxBodyBytes: maxBodyBytes)
        }
    ) {
        self.tokenStore = tokenStore
        self.server = server
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        self.makeListener = makeListener
    }

    /// Prepares hook settings for one Claude launch.
    public func prepareLaunch(
        conversationId: AgentConversationID,
        processToken: UUID,
        permissionMode: String? = nil,
        workingDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeoutSeconds: Int = ClaudeHookPolicy.defaultHookTimeoutSeconds
    ) async throws -> ClaudeHookLaunchConfiguration {
        let port = try await ensureListenerPort()
        let token = await tokenStore.issueProcessScoped()
        let settingsURL = settingsURL(processToken: processToken)
        guard let endpoints = endpointURLs(
            port: port,
            conversationId: conversationId,
            processToken: processToken
        ) else {
            await server.invalidateToken(token.value)
            throw AgentCLIError.invalidInput("Could not build Claude hook endpoint URL.")
        }
        let settings = ClaudeHookSettings(
            endpointURL: endpoints.preToolUse,
            includePreToolUse: ClaudeHookPolicy.shouldEnableHooks(permissionMode: permissionMode),
            preCompactEndpointURL: endpoints.preCompact,
            postCompactEndpointURL: endpoints.postCompact,
            timeoutSeconds: timeoutSeconds
        )
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try settings.encodedData().write(to: settingsURL, options: [.atomic])
        } catch {
            await server.invalidateToken(token.value)
            try? fileManager.removeItem(at: settingsURL)
            throw error
        }
        await registerLaunchState(ClaudeHookLaunchRegistration(
            token: token.value,
            processToken: processToken,
            settingsURL: settingsURL,
            conversationId: conversationId,
            permissionMode: permissionMode,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        ))
        return ClaudeHookLaunchConfiguration(
            arguments: ["--settings", settingsURL.path],
            environment: [settings.tokenEnvironmentVariable: token.value],
            token: token.value,
            settingsFileURL: settingsURL
        )
    }

    /// Invalidates hook state for a finished or superseded launch.
    public func invalidate(processToken: UUID) async {
        let token = launchTokens.removeValue(forKey: processToken)
        let settingsURL = launchSettingsFiles.removeValue(forKey: processToken)
        if let token {
            await server.invalidateToken(token)
        }
        removeSettingsFile(at: settingsURL)
    }

    /// Updates cached permission mode used for hook decisions when Claude reports in-session mode changes.
    public func updatePermissionMode(_ permissionMode: String?, for conversationId: AgentConversationID) async {
        await server.updatePermissionMode(permissionMode, for: conversationId)
    }

    /// Returns compact hook runtime events for one launch.
    public func runtimeEvents(context: AgentProviderRuntimeContext) -> AsyncStream<AgentProviderRuntimeEvent> {
        let stream = AsyncStream<AgentProviderRuntimeEvent>.makeStream()
        Task {
            await server.registerCompactRuntimeEvents(processToken: context.processToken, continuation: stream.continuation)
        }
        stream.continuation.onTermination = { _ in
            Task {
                await self.server.unregisterCompactRuntimeEvents(processToken: context.processToken)
            }
        }
        return stream.stream
    }

    /// Stops the listener and invalidates active launch tokens.
    public func shutdown() async {
        let tokens = Array(launchTokens.values)
        let settingsURLs = Array(launchSettingsFiles.values)
        launchTokens.removeAll()
        launchSettingsFiles.removeAll()
        for token in tokens {
            await server.invalidateToken(token)
        }
        // Generated hook settings are scoped to one provider launch and should not survive process teardown.
        settingsURLs.forEach { removeSettingsFile(at: $0) }
        await listener?.stop()
        listener = nil
        listenerPort = nil
    }

    private func ensureListenerPort() async throws -> Int {
        if let listenerPort {
            return listenerPort
        }
        let listener = makeListener(server, 1_000_000)
        let port = try await listener.start()
        self.listener = listener
        self.listenerPort = port
        return port
    }

    private func settingsURL(processToken: UUID) -> URL {
        supportDirectory.appendingPathComponent("claude-hooks-\(processToken.uuidString).json")
    }

    private func registerLaunchState(_ registration: ClaudeHookLaunchRegistration) async {
        await server.updatePermissionMode(registration.permissionMode, for: registration.conversationId)
        await server.registerCompactHooks(processToken: registration.processToken, token: registration.token)
        if let workingDirectory = registration.workingDirectory {
            await server.registerLaunchContext(
                processToken: registration.processToken,
                workingDirectory: workingDirectory,
                homeDirectory: registration.homeDirectory
            )
        }
        launchTokens[registration.processToken] = registration.token
        launchSettingsFiles[registration.processToken] = registration.settingsURL
    }

    private func endpointURLs(port: Int, conversationId: AgentConversationID, processToken: UUID) -> ClaudeHookEndpointURLs? {
        guard let preToolUse = endpointURL(
            path: "/claude/hooks/pre-tool-use",
            port: port,
            conversationId: conversationId,
            processToken: processToken
        ),
        let preCompact = endpointURL(
            path: "/claude/hooks/pre-compact",
            port: port,
            conversationId: conversationId,
            processToken: processToken
        ),
        let postCompact = endpointURL(
            path: "/claude/hooks/post-compact",
            port: port,
            conversationId: conversationId,
            processToken: processToken
        ) else {
            return nil
        }
        return ClaudeHookEndpointURLs(preToolUse: preToolUse, preCompact: preCompact, postCompact: postCompact)
    }

    private func endpointURL(path: String, port: Int, conversationId: AgentConversationID, processToken: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "conversation_id", value: conversationId.rawValue),
            URLQueryItem(name: "process_token", value: processToken.uuidString)
        ]
        return components.url
    }

    private func removeSettingsFile(at url: URL?) {
        guard let url else {
            return
        }
        try? fileManager.removeItem(at: url)
    }
}

private struct ClaudeHookEndpointURLs {
    let preToolUse: URL
    let preCompact: URL
    let postCompact: URL
}

private struct ClaudeHookLaunchRegistration {
    let token: String
    let processToken: UUID
    let settingsURL: URL
    let conversationId: AgentConversationID
    let permissionMode: String?
    let workingDirectory: URL?
    let homeDirectory: URL
}

/// Transport used by `ClaudeHookCoordinator` to accept hook requests.
public protocol ClaudeHookListeningTransport: Sendable {
    /// Starts listening and returns the bound port.
    func start() async throws -> Int
    /// Stops listening.
    func stop() async
}

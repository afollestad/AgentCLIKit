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
    private let beforeLaunchServerRegistration: @Sendable () async -> Void
    private var listener: (any ClaudeHookListeningTransport)?
    private var listenerPort: Int?
    private var listenerStartOperation: ClaudeHookListenerStartOperation?
    private var launchTokens: [UUID: String] = [:]
    private var launchSettingsFiles: [UUID: URL] = [:]
    private var isShutdown = false
    private var isShutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

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
        self.beforeLaunchServerRegistration = {}
    }

    init(
        tokenStore: AgentHookTokenStore,
        server: ClaudeHookServer,
        supportDirectory: URL,
        fileManager: FileManager = .default,
        makeListener: @escaping @Sendable (ClaudeHookServer, Int) -> any ClaudeHookListeningTransport,
        beforeLaunchServerRegistration: @escaping @Sendable () async -> Void
    ) {
        self.tokenStore = tokenStore
        self.server = server
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        self.makeListener = makeListener
        self.beforeLaunchServerRegistration = beforeLaunchServerRegistration
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
        try ensureCoordinatorIsActive()
        let token = await tokenStore.issueProcessScoped()
        guard !isShutdown else {
            await server.invalidateToken(token.value)
            throw AgentCLIError.invalidInput("Claude hook coordinator has shut down.")
        }
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
        try await writeSettings(settings, to: settingsURL, token: token.value)
        launchTokens[processToken] = token.value
        launchSettingsFiles[processToken] = settingsURL
        await registerLaunchServerState(ClaudeHookLaunchRegistration(
            token: token.value,
            processToken: processToken,
            settingsURL: settingsURL,
            conversationId: conversationId,
            permissionMode: permissionMode,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        ))
        try await ensureLaunchRegistrationIsActive(
            processToken: processToken,
            token: token.value,
            settingsURL: settingsURL
        )
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
        if isShutdown {
            guard !isShutdownComplete else {
                return
            }
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        isShutdown = true
        let tokens = Array(launchTokens.values)
        let settingsURLs = Array(launchSettingsFiles.values)
        let activeListener = listener
        let pendingListenerStart = listenerStartOperation
        launchTokens.removeAll()
        launchSettingsFiles.removeAll()
        listener = nil
        listenerPort = nil
        listenerStartOperation = nil
        for token in tokens {
            await server.invalidateToken(token)
        }
        // Generated hook settings are scoped to one provider launch and should not survive process teardown.
        settingsURLs.forEach { removeSettingsFile(at: $0) }
        if let pendingListenerStart {
            await pendingListenerStart.listener.stop()
        }
        if let activeListener {
            await activeListener.stop()
        } else if let pendingListenerStart,
                  case let .success(startedListener) = await pendingListenerStart.task.result {
            await startedListener.listener.stop()
        }
        isShutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func ensureListenerPort() async throws -> Int {
        try ensureCoordinatorIsActive()
        if let listenerPort {
            return listenerPort
        }
        let operation: ClaudeHookListenerStartOperation
        if let listenerStartOperation {
            operation = listenerStartOperation
        } else {
            let listener = makeListener(server, 1_000_000)
            let newTask = Task {
                let port = try await listener.start()
                return ClaudeHookStartedListener(listener: listener, port: port)
            }
            let newOperation = ClaudeHookListenerStartOperation(id: UUID(), listener: listener, task: newTask)
            listenerStartOperation = newOperation
            operation = newOperation
        }
        do {
            let startedListener = try await operation.task.value
            try ensureCoordinatorIsActive()
            listener = startedListener.listener
            listenerPort = startedListener.port
            if listenerStartOperation?.id == operation.id {
                listenerStartOperation = nil
            }
            return startedListener.port
        } catch {
            if listenerStartOperation?.id == operation.id {
                listenerStartOperation = nil
            }
            throw error
        }
    }

    private func settingsURL(processToken: UUID) -> URL {
        supportDirectory.appendingPathComponent("claude-hooks-\(processToken.uuidString).json")
    }

    private func registerLaunchServerState(_ registration: ClaudeHookLaunchRegistration) async {
        await beforeLaunchServerRegistration()
        await server.updatePermissionMode(registration.permissionMode, for: registration.conversationId)
        if let workingDirectory = registration.workingDirectory {
            await server.registerLaunchContext(
                processToken: registration.processToken,
                workingDirectory: workingDirectory,
                homeDirectory: registration.homeDirectory
            )
        }
        // Install the token mapping last so a post-registration token invalidation can always find and clear path context.
        await server.registerCompactHooks(processToken: registration.processToken, token: registration.token)
    }

    private func ensureCoordinatorIsActive() throws {
        guard !isShutdown else {
            throw AgentCLIError.invalidInput("Claude hook coordinator has shut down.")
        }
    }

    private func ensureLaunchRegistrationIsActive(
        processToken: UUID,
        token: String,
        settingsURL: URL
    ) async throws {
        let mappingIsCurrent = launchTokens[processToken] == token && launchSettingsFiles[processToken] == settingsURL
        guard !isShutdown, mappingIsCurrent else {
            await cleanUpFailedLaunchRegistration(
                processToken: processToken,
                token: token,
                settingsURL: settingsURL
            )
            let reason = isShutdown
                ? "Claude hook coordinator has shut down."
                : "Claude hook launch registration was invalidated."
            throw AgentCLIError.invalidInput(reason)
        }
    }

    private func cleanUpFailedLaunchRegistration(
        processToken: UUID,
        token: String,
        settingsURL: URL
    ) async {
        await server.invalidateToken(token)
        let hasReplacement = launchTokens[processToken].map { $0 != token } == true
        if launchTokens[processToken] == token {
            launchTokens[processToken] = nil
        }
        if !hasReplacement, launchSettingsFiles[processToken] == settingsURL {
            launchSettingsFiles[processToken] = nil
            removeSettingsFile(at: settingsURL)
        } else if launchSettingsFiles[processToken] == nil {
            removeSettingsFile(at: settingsURL)
        }
    }

    private func writeSettings(_ settings: ClaudeHookSettings, to settingsURL: URL, token: String) async throws {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try settings.encodedData().write(to: settingsURL, options: [.atomic])
        } catch {
            await server.invalidateToken(token)
            try? fileManager.removeItem(at: settingsURL)
            throw error
        }
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

private struct ClaudeHookStartedListener: Sendable {
    let listener: any ClaudeHookListeningTransport
    let port: Int
}

private struct ClaudeHookListenerStartOperation: Sendable {
    let id: UUID
    let listener: any ClaudeHookListeningTransport
    let task: Task<ClaudeHookStartedListener, Error>
}

/// Transport used by `ClaudeHookCoordinator` to accept hook requests.
public protocol ClaudeHookListeningTransport: Sendable {
    /// Starts listening and returns the bound port.
    func start() async throws -> Int
    /// Idempotently stops listening, including a start that has not reached readiness yet.
    func stop() async
}

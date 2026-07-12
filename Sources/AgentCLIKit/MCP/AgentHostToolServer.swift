import Foundation
import MCP
import Security

struct AgentHostToolServerFailure: Equatable, Sendable {
    let processTokens: [UUID]
    let message: String
}

protocol AgentHostToolServing: Sendable {
    func register(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        processToken: UUID,
        server: AgentHostToolServerMetadata,
        tools: [AgentHostToolDefinition]
    ) async throws -> AgentHostToolEndpoint

    func failures() async -> AsyncStream<AgentHostToolServerFailure>
    func invalidate(processToken: UUID) async
    func shutdown() async
}

extension AgentHostToolServing {
    func failures() async -> AsyncStream<AgentHostToolServerFailure> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

actor DefaultAgentHostToolServer: AgentHostToolServing {
    private struct ListenerStartOperation {
        let id: UUID
        let task: Task<Int, Error>
    }

    struct Configuration: Sendable {
        let maxBodyBytes: Int
        let maxOutputBytes: Int
        let toolTimeoutNanoseconds: UInt64

        init(
            maxBodyBytes: Int = 1_000_000,
            maxOutputBytes: Int = 1_000_000,
            toolTimeoutNanoseconds: UInt64 = 30_000_000_000
        ) {
            self.maxBodyBytes = max(1, maxBodyBytes)
            self.maxOutputBytes = max(1, maxOutputBytes)
            self.toolTimeoutNanoseconds = toolTimeoutNanoseconds
        }
    }

    struct Registration {
        let path: String
        let server: Server
        let invocationLifetime: AgentHostToolInvocationLifetime
    }

    private struct PreparedRegistration {
        let port: Int
        let path: String
        let token: String
        let transport: StatelessHTTPServerTransport
        let server: Server
        let invocationLifetime: AgentHostToolInvocationLifetime
    }

    private struct RegistrationContext {
        let conversationId: AgentConversationID
        let providerId: AgentProviderID
        let processToken: UUID
    }

    private let handling: AgentHostToolHandling
    private let configuration: Configuration
    let listener: AgentHostToolHTTPListener
    var port: Int?
    private var listenerStartOperation: ListenerStartOperation?
    var registrations: [UUID: Registration] = [:]
    private var preparingProcessTokens = Set<UUID>()
    private var cancelledProcessTokens = Set<UUID>()
    var failureContinuations: [UUID: AsyncStream<AgentHostToolServerFailure>.Continuation] = [:]
    var isFailureHandlerInstalled = false
    var isShutdown = false
    private var shutdownTask: Task<Void, Never>?

    init(
        handling: AgentHostToolHandling,
        configuration: Configuration = Configuration(),
        listener: AgentHostToolHTTPListener? = nil
    ) {
        self.handling = handling
        self.configuration = configuration
        self.listener = listener ?? AgentHostToolHTTPListener(
            maxBodyBytes: configuration.maxBodyBytes,
            maxResponseBytes: Self.wireResponseLimit(for: configuration.maxOutputBytes)
        )
    }

    func register(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        processToken: UUID,
        server metadata: AgentHostToolServerMetadata,
        tools: [AgentHostToolDefinition]
    ) async throws -> AgentHostToolEndpoint {
        installFailureHandlerIfNeeded()
        guard !isShutdown else {
            throw AgentCLIError.invalidInput("Host tool server has shut down.")
        }
        try validate(metadata: metadata, tools: tools)
        await invalidate(processToken: processToken)
        guard !isShutdown else {
            throw AgentCLIError.invalidInput("Host tool server has shut down.")
        }
        preparingProcessTokens.insert(processToken)
        do {
            let prepared = try await prepareRegistration(
                conversationId: conversationId,
                providerId: providerId,
                processToken: processToken,
                metadata: metadata,
                tools: tools
            )
            do {
                return try await activateRegistration(
                    prepared,
                    processToken: processToken,
                    serverName: metadata.name,
                    tools: tools
                )
            } catch {
                prepared.invocationLifetime.deactivate()
                await prepared.server.stop()
                throw error
            }
        } catch {
            finishPreparing(processToken)
            throw error
        }
    }

    private func prepareRegistration(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        processToken: UUID,
        metadata: AgentHostToolServerMetadata,
        tools: [AgentHostToolDefinition]
    ) async throws -> PreparedRegistration {
        let port = try await listeningPort()
        try ensureRegistrationIsCurrent(processToken)
        let token = try Self.secureIdentifier(byteCount: 32)
        let path = "/mcp/\(try Self.secureIdentifier(byteCount: 24))"
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AgentHostBearerTokenValidator(expectedToken: token),
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator()
            ])
        )
        let invocationLifetime = AgentHostToolInvocationLifetime()
        let server = await configuredServer(
            registrationContext: RegistrationContext(
                conversationId: conversationId,
                providerId: providerId,
                processToken: processToken
            ),
            metadata: metadata,
            tools: tools,
            invocationLifetime: invocationLifetime
        )
        do {
            try await server.start(transport: transport)
            try ensureRegistrationIsCurrent(processToken)
        } catch {
            await server.stop()
            throw error
        }
        return PreparedRegistration(
            port: port,
            path: path,
            token: token,
            transport: transport,
            server: server,
            invocationLifetime: invocationLifetime
        )
    }

    private func configuredServer(
        registrationContext: RegistrationContext,
        metadata: AgentHostToolServerMetadata,
        tools: [AgentHostToolDefinition],
        invocationLifetime: AgentHostToolInvocationLifetime
    ) async -> Server {
        let definitionByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let server = Server(
            name: metadata.name,
            version: "1.0.0",
            title: metadata.title,
            instructions: metadata.instructions,
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .strict
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: try tools.map(Self.mcpTool))
        }
        await server.withMethodHandler(CallTool.self) { [handling, configuration, invocationLifetime] parameters in
            guard definitionByName[parameters.name] != nil else {
                let result = AgentHostToolResult(
                    text: "Unknown host tool.",
                    isError: true
                )
                return Self.mcpResult(Self.bounded(result, maxBytes: configuration.maxOutputBytes))
            }
            let arguments = try Self.agentArguments(parameters.arguments)
            let requestId = Self.requestId(from: Server.currentHandlerContext?.httpContext?.body)
            let context = AgentHostToolCallContext(
                conversationId: registrationContext.conversationId,
                providerId: registrationContext.providerId,
                processToken: registrationContext.processToken,
                requestId: requestId
            )
            let result = await Self.handleWithTimeout(
                handling: handling,
                context: context,
                call: AgentHostToolCall(name: parameters.name, arguments: arguments),
                timeoutNanoseconds: configuration.toolTimeoutNanoseconds,
                invocationLifetime: invocationLifetime
            )
            let validatedResult = Self.validatedStructuredResult(result)
            return Self.mcpResult(Self.bounded(validatedResult, maxBytes: configuration.maxOutputBytes))
        }
        return server
    }

    private func activateRegistration(
        _ prepared: PreparedRegistration,
        processToken: UUID,
        serverName: String,
        tools: [AgentHostToolDefinition]
    ) async throws -> AgentHostToolEndpoint {
        try ensureRegistrationIsCurrent(processToken)
        guard listener.addRoute(
            path: prepared.path,
            transport: prepared.transport,
            bearerToken: prepared.token,
            port: prepared.port,
            processToken: processToken
        ) else {
            throw AgentCLIError.hostToolsUnavailable(reason: "Host tool listener stopped before route activation.")
        }
        registrations[processToken] = Registration(
            path: prepared.path,
            server: prepared.server,
            invocationLifetime: prepared.invocationLifetime
        )
        finishPreparing(processToken)
        guard let url = URL(string: "http://127.0.0.1:\(prepared.port)\(prepared.path)") else {
            await invalidate(processToken: processToken)
            throw AgentCLIError.invalidInput("Could not construct the host tool endpoint URL.")
        }
        return AgentHostToolEndpoint(
            serverName: serverName,
            url: url,
            bearerToken: prepared.token,
            enabledToolNames: tools.map(\.name)
        )
    }

    func invalidate(processToken: UUID) async {
        if preparingProcessTokens.contains(processToken) {
            cancelledProcessTokens.insert(processToken)
        }
        guard let registration = registrations.removeValue(forKey: processToken) else {
            return
        }
        registration.invocationLifetime.deactivate()
        listener.removeRoute(path: registration.path)
        await registration.server.stop()
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShutdown = true
        let failureContinuations = self.failureContinuations
        self.failureContinuations.removeAll()
        failureContinuations.values.forEach { $0.finish() }
        cancelledProcessTokens.formUnion(preparingProcessTokens)
        let startupTask = listenerStartOperation?.task
        startupTask?.cancel()
        listenerStartOperation = nil
        let active = registrations
        registrations.removeAll()
        for registration in active.values {
            registration.invocationLifetime.deactivate()
            listener.removeRoute(path: registration.path)
        }
        let listener = self.listener
        let shutdownTask = Task {
            for registration in active.values {
                await registration.server.stop()
            }
            await listener.stop()
            if let startupTask {
                _ = await startupTask.result
            }
        }
        self.shutdownTask = shutdownTask
        await shutdownTask.value
        port = nil
    }

    private func listeningPort() async throws -> Int {
        if let port, listener.activePort == port {
            return port
        }
        if port != nil {
            port = nil
            await invalidateRegistrationsAfterListenerFailure()
        }
        let operation: ListenerStartOperation
        if let listenerStartOperation {
            operation = listenerStartOperation
        } else {
            let newTask = Task { try await listener.start() }
            let newOperation = ListenerStartOperation(id: UUID(), task: newTask)
            listenerStartOperation = newOperation
            operation = newOperation
        }
        let startedPort: Int
        do {
            startedPort = try await operation.task.value
        } catch {
            if listenerStartOperation?.id == operation.id {
                listenerStartOperation = nil
            }
            throw error
        }
        guard !isShutdown else {
            await listener.stop()
            throw AgentCLIError.invalidInput("Host tool server shut down during startup.")
        }
        guard listener.activePort == startedPort else {
            if listenerStartOperation?.id == operation.id {
                listenerStartOperation = nil
            }
            throw AgentCLIError.hostToolsUnavailable(reason: "Host tool listener stopped during startup.")
        }
        port = startedPort
        if listenerStartOperation?.id == operation.id {
            listenerStartOperation = nil
        }
        return startedPort
    }

#if DEBUG
    func isRegistered(processToken: UUID) -> Bool {
        registrations[processToken] != nil
    }
#endif

    private func ensureRegistrationIsCurrent(_ processToken: UUID) throws {
        guard !isShutdown, !cancelledProcessTokens.contains(processToken) else {
            throw AgentCLIError.invalidInput("Host tool registration was cancelled.")
        }
    }

    private func finishPreparing(_ processToken: UUID) {
        preparingProcessTokens.remove(processToken)
        cancelledProcessTokens.remove(processToken)
    }

    private func validate(metadata: AgentHostToolServerMetadata, tools: [AgentHostToolDefinition]) throws {
        guard metadata.hasValidProviderName else {
            throw AgentCLIError.invalidInput("Host tool server names must be 1 to 128 ASCII letters, numbers, underscores, or hyphens.")
        }
        guard !tools.isEmpty else {
            throw AgentCLIError.invalidInput("At least one host tool is required to register an endpoint.")
        }
        var names = Set<String>()
        for tool in tools {
            guard tool.hasValidProviderName else {
                throw AgentCLIError.invalidInput("Host tool names must be 1 to 128 ASCII letters, numbers, periods, underscores, or hyphens.")
            }
            guard names.insert(tool.name).inserted else {
                throw AgentCLIError.invalidInput("Duplicate host tool name '\(tool.name)'.")
            }
            try tool.validateObjectSchemas()
        }
        let encodedDefinitions = try JSONEncoder().encode(tools)
        guard encodedDefinitions.count <= configuration.maxOutputBytes else {
            throw AgentCLIError.invalidInput("Host tool definitions exceed the configured output size limit.")
        }
    }

    private static func secureIdentifier(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AgentCLIError.invalidInput("Could not generate secure host tool credentials.")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct AgentHostBearerTokenValidator: HTTPRequestValidator {
    let expectedToken: String

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        let prefix = "Bearer "
        guard let authorization = request.header(HTTPHeaderName.authorization),
              authorization.hasPrefix(prefix),
              Self.constantTimeEqual(String(authorization.dropFirst(prefix.count)), expectedToken) else {
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized"),
                extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"]
            )
        }
        return nil
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

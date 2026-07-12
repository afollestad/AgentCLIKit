import Foundation

/// Runtime context supplied before a provider creates or resumes its native session.
public struct AgentProviderLaunchContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Desired spawn configuration.
    public let spawnConfig: AgentSpawnConfig
    /// Persisted provider session selected for resume, if any.
    public let resumedSession: AgentSessionRecord?
    /// Authenticated host-owned MCP endpoint registered for this process, if any.
    public let hostToolEndpoint: AgentHostToolEndpoint?

    /// Creates provider launch context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?,
        hostToolEndpoint: AgentHostToolEndpoint? = nil
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.spawnConfig = spawnConfig
        self.resumedSession = resumedSession
        self.hostToolEndpoint = hostToolEndpoint
    }
}

extension AgentProviderLaunchContext {
    func validatedHostToolEndpoint() throws -> AgentHostToolEndpoint? {
        guard !spawnConfig.hostTools.isEmpty else {
            guard hostToolEndpoint == nil else {
                throw AgentCLIError.invalidInput("A host tool endpoint was supplied without host tool definitions.")
            }
            return nil
        }
        guard let hostToolEndpoint else {
            throw AgentCLIError.hostToolsUnavailable(reason: "Host tool definitions require a registered endpoint.")
        }
        guard spawnConfig.hostToolServer.hasValidProviderName else {
            throw AgentCLIError.invalidInput(
                "Host tool server names must be 1 to 128 ASCII letters, numbers, underscores, or hyphens."
            )
        }
        let expectedNames = spawnConfig.hostTools.map(\.name)
        guard spawnConfig.hostTools.allSatisfy(\.hasValidProviderName) else {
            throw AgentCLIError.invalidInput(
                "Host tool names must be 1 to 128 ASCII letters, numbers, periods, underscores, or hyphens."
            )
        }
        guard Set(expectedNames).count == expectedNames.count else {
            throw AgentCLIError.invalidInput("Host tool names must be unique within one endpoint.")
        }
        for tool in spawnConfig.hostTools {
            try tool.validateObjectSchemas()
        }
        guard hostToolEndpoint.url.scheme == "http",
              hostToolEndpoint.url.host == "127.0.0.1",
              hostToolEndpoint.url.port != nil,
              !hostToolEndpoint.url.path.isEmpty,
              hostToolEndpoint.url.user == nil,
              hostToolEndpoint.url.password == nil,
              hostToolEndpoint.url.query == nil,
              hostToolEndpoint.url.fragment == nil,
              !hostToolEndpoint.bearerToken.isEmpty else {
            throw AgentCLIError.invalidInput("Host tool endpoints must use authenticated IPv4 loopback HTTP URLs.")
        }
        guard hostToolEndpoint.enabledToolNames == expectedNames,
              hostToolEndpoint.serverName == spawnConfig.hostToolServer.name else {
            throw AgentCLIError.invalidInput("The host tool endpoint does not match the spawn configuration.")
        }
        return hostToolEndpoint
    }
}

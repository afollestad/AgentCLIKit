import Foundation

/// Provider-neutral definition of a host-owned MCP tool exposed for one agent process.
public struct AgentHostToolDefinition: Codable, Equatable, Sendable {
    /// Tool name exposed through MCP.
    public let name: String
    /// Optional human-readable title.
    public let title: String?
    /// Guidance that helps the agent decide when and how to call the tool.
    public let description: String
    /// JSON Schema describing accepted tool arguments.
    public let inputSchema: JSONValue
    /// Optional JSON Schema describing structured tool output.
    public let outputSchema: JSONValue?
    /// Operational hints advertised to MCP clients.
    public let annotations: AgentHostToolAnnotations

    /// Creates a host tool definition.
    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        annotations: AgentHostToolAnnotations = AgentHostToolAnnotations()
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }
}

/// Provider-neutral MCP tool annotations.
public struct AgentHostToolAnnotations: Codable, Equatable, Sendable {
    /// Whether the tool only reads host state.
    public let readOnlyHint: Bool?
    /// Whether the tool may perform destructive updates.
    public let destructiveHint: Bool?
    /// Whether exact repeated calls have no additional effect.
    public let idempotentHint: Bool?
    /// Whether the tool interacts with entities outside the host's closed domain.
    public let openWorldHint: Bool?

    /// Creates tool annotations.
    public init(
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

/// Host-provided MCP server identity and instructions for one process launch.
public struct AgentHostToolServerMetadata: Codable, Equatable, Sendable {
    /// Provider-facing MCP server identifier.
    public let name: String
    /// Optional human-readable server title.
    public let title: String?
    /// Optional instructions that help the agent use the server correctly.
    public let instructions: String?

    /// Creates host tool server metadata.
    public init(
        name: String = "agentclikit_host",
        title: String? = nil,
        instructions: String? = nil
    ) {
        self.name = name
        self.title = title
        self.instructions = instructions
    }
}

extension AgentHostToolServerMetadata {
    var hasValidProviderName: Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.unicodeScalars.allSatisfy {
            switch $0.value {
            case 48...57, 65...90, 97...122, 45, 95:
                true
            default:
                false
            }
        }
    }
}

extension AgentHostToolDefinition {
    var hasValidProviderName: Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.unicodeScalars.allSatisfy {
            switch $0.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                true
            default:
                false
            }
        }
    }

    func validateObjectSchemas() throws {
        guard case let .object(inputSchema) = inputSchema,
              inputSchema["type"] == .string("object") else {
            throw AgentCLIError.invalidInput("Host tool '\(name)' input schema must declare root type 'object'.")
        }
        guard let outputSchema else {
            return
        }
        guard case let .object(outputSchema) = outputSchema,
              outputSchema["type"] == .string("object") else {
            throw AgentCLIError.invalidInput("Host tool '\(name)' output schema must declare root type 'object'.")
        }
    }
}

/// Context supplied to a host-owned tool handler.
public struct AgentHostToolCallContext: Sendable {
    /// Host conversation identifier for the process that invoked the tool.
    public let conversationId: AgentConversationID
    /// Provider that invoked the tool.
    public let providerId: AgentProviderID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Provider JSON-RPC request identifier when available.
    public let requestId: String?

    /// Creates host tool call context.
    public init(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        processToken: UUID,
        requestId: String? = nil
    ) {
        self.conversationId = conversationId
        self.providerId = providerId
        self.processToken = processToken
        self.requestId = requestId
    }
}

/// One invocation of a host-owned tool.
public struct AgentHostToolCall: Equatable, Sendable {
    /// Tool name.
    public let name: String
    /// JSON-compatible arguments supplied by the provider.
    public let arguments: [String: JSONValue]

    /// Creates a host tool call.
    public init(name: String, arguments: [String: JSONValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

/// Provider-neutral result returned by a host-owned tool.
public struct AgentHostToolResult: Equatable, Sendable {
    /// Text fallback shown by clients that do not consume structured content.
    public let text: String
    /// Optional JSON-compatible structured result.
    public let structuredContent: JSONValue?
    /// Whether the result represents a handled tool error.
    public let isError: Bool

    /// Creates a host tool result.
    public init(text: String, structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

/// Host-owned tool dispatcher injected separately from persisted spawn configuration.
public struct AgentHostToolHandling: Sendable {
    /// Handler invoked for an authenticated tool call. Long-running handlers should cooperate with task cancellation.
    public typealias Handler = @Sendable (AgentHostToolCallContext, AgentHostToolCall) async -> AgentHostToolResult

    private let handler: Handler

    /// Creates host tool handling from a dispatcher closure.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Dispatches one host tool call.
    public func handle(
        context: AgentHostToolCallContext,
        call: AgentHostToolCall
    ) async -> AgentHostToolResult {
        await handler(context, call)
    }
}

/// Authenticated loopback endpoint registered for one provider process.
public struct AgentHostToolEndpoint: Equatable, Sendable {
    /// Provider-facing MCP server name.
    public let serverName: String
    /// Streamable HTTP endpoint URL.
    public let url: URL
    /// Per-process bearer token.
    public let bearerToken: String
    /// Tool names available on this endpoint.
    public let enabledToolNames: [String]

    /// Creates a host tool endpoint.
    public init(serverName: String, url: URL, bearerToken: String, enabledToolNames: [String]) {
        self.serverName = serverName
        self.url = url
        self.bearerToken = bearerToken
        self.enabledToolNames = enabledToolNames
    }
}

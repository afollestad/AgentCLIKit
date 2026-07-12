import Foundation
import MCP

extension DefaultAgentHostToolServer {
    static func mcpTool(_ definition: AgentHostToolDefinition) throws -> Tool {
        Tool(
            name: definition.name,
            title: definition.title,
            description: definition.description,
            inputSchema: try Value(definition.inputSchema),
            annotations: Tool.Annotations(
                title: definition.title,
                readOnlyHint: definition.annotations.readOnlyHint,
                destructiveHint: definition.annotations.destructiveHint,
                idempotentHint: definition.annotations.idempotentHint,
                openWorldHint: definition.annotations.openWorldHint
            ),
            outputSchema: try definition.outputSchema.map(Value.init)
        )
    }

    static func agentArguments(_ arguments: [String: Value]?) throws -> [String: JSONValue] {
        guard let arguments else {
            return [:]
        }
        let data = try JSONEncoder().encode(arguments)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    static func mcpResult(_ result: AgentHostToolResult) -> CallTool.Result {
        let structuredContent: Value?
        if let value = result.structuredContent {
            guard let converted = try? Value(value) else {
                return CallTool.Result(
                    content: [.text(text: "Host tool structured content could not be encoded.", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            structuredContent = converted
        } else {
            structuredContent = nil
        }
        return CallTool.Result(
            content: [.text(text: result.text, annotations: nil, _meta: nil)],
            structuredContent: structuredContent,
            isError: result.isError
        )
    }

    static func bounded(_ result: AgentHostToolResult, maxBytes: Int) -> AgentHostToolResult {
        let structuredBytes: Int
        if let structuredContent = result.structuredContent {
            guard let encoded = try? JSONEncoder().encode(structuredContent) else {
                return AgentHostToolResult(text: "Host tool structured content could not be encoded.", isError: true)
            }
            structuredBytes = encoded.count
        } else {
            structuredBytes = 0
        }
        let (totalBytes, overflow) = result.text.utf8.count.addingReportingOverflow(structuredBytes)
        guard !overflow, totalBytes <= maxBytes else {
            return AgentHostToolResult(text: "Host tool output exceeded the configured size limit.", isError: true)
        }
        return result
    }

    static func validatedStructuredResult(_ result: AgentHostToolResult) -> AgentHostToolResult {
        guard let structuredContent = result.structuredContent else {
            return result
        }
        guard case .object = structuredContent else {
            return AgentHostToolResult(text: "Host tool structured content must be a JSON object.", isError: true)
        }
        guard (try? JSONEncoder().encode(structuredContent)) != nil,
              (try? Value(structuredContent)) != nil else {
            return AgentHostToolResult(text: "Host tool structured content could not be encoded.", isError: true)
        }
        return result
    }

    static func handleWithTimeout(
        handling: AgentHostToolHandling,
        context: AgentHostToolCallContext,
        call: AgentHostToolCall,
        timeoutNanoseconds: UInt64,
        invocationLifetime: AgentHostToolInvocationLifetime
    ) async -> AgentHostToolResult {
        await invocationLifetime.execute(timeoutNanoseconds: timeoutNanoseconds) {
            await handling.handle(context: context, call: call)
        }
    }

    static func wireResponseLimit(for outputLimit: Int) -> Int {
        let (expanded, overflow) = outputLimit.multipliedReportingOverflow(by: 6)
        guard !overflow, expanded <= Int.max - 65_536 else {
            return Int.max
        }
        return expanded + 65_536
    }

    static func requestId(from body: Data?) -> String? {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let identifier = object["id"] else {
            return nil
        }
        if let identifier = identifier as? String {
            return "string:\(identifier)"
        }
        if let identifier = identifier as? NSNumber, CFGetTypeID(identifier) != CFBooleanGetTypeID() {
            return "number:\(identifier.stringValue)"
        }
        return nil
    }
}

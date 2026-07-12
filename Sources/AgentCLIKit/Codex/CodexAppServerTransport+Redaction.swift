import Foundation

public extension CodexAppServerTransport {
    /// Does nothing for custom transports that do not retain diagnostic text.
    func registerSensitiveValues(_ values: [String], processToken: UUID) async {}

    /// Does nothing for custom transports that do not retain diagnostic text.
    func unregisterSensitiveValues(processToken: UUID) async {}
}

extension CodexAppServerError {
    func redacting(sensitiveValues: some Sequence<String>) -> CodexAppServerError {
        switch self {
        case let .jsonRPCError(method, code, message):
            .jsonRPCError(
                method: method,
                code: code,
                message: AgentSensitiveValueRedactor.redact(message, sensitiveValues: sensitiveValues)
            )
        case let .appServerExited(exitCode, stderrTail):
            .appServerExited(
                exitCode: exitCode,
                stderrTail: AgentSensitiveValueRedactor.redact(stderrTail, sensitiveValues: sensitiveValues)
            )
        case .missingThreadID, .requestTimeout, .shutdownTimeout, .unsupportedTransport:
            self
        }
    }
}

struct CodexTransportJSONRPCError {
    let code: Int?
    let message: String
}

extension JSONValue {
    func transportRedacting(sensitiveValues: Set<String>) -> JSONValue {
        switch self {
        case let .array(values):
            .array(values.map { $0.transportRedacting(sensitiveValues: sensitiveValues) })
        case let .object(values):
            .object(values.mapValues { $0.transportRedacting(sensitiveValues: sensitiveValues) })
        case let .string(value):
            .string(AgentSensitiveValueRedactor.redact(value, sensitiveValues: sensitiveValues))
        case .bool, .null, .number:
            self
        }
    }

    var transportIntValue: Int? {
        switch self {
        case let .number(value):
            Int(value)
        case let .string(value):
            Int(value)
        default:
            nil
        }
    }

    var transportJSONRPCError: CodexTransportJSONRPCError? {
        guard case let .object(object) = self else {
            return nil
        }
        let code = object["code"]?.transportIntValue
        let message: String
        if case let .string(value)? = object["message"] {
            message = value
        } else {
            message = "Unknown JSON-RPC error."
        }
        return CodexTransportJSONRPCError(code: code, message: message)
    }
}

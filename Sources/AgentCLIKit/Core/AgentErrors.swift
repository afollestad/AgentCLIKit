import Foundation

/// Stable machine-readable error codes for host UI mapping and logging.
public enum AgentErrorCode: String, Codable, Hashable, Sendable {
    /// A requested provider was not registered.
    case providerNotRegistered
    /// The provider is registered but no executable could be found.
    case providerUnavailable
    /// A shell command returned a non-zero exit code.
    case commandFailed
    /// A shell command could not be launched.
    case commandLaunchFailed
    /// A shell argument string ended before a quote was closed.
    case unterminatedQuote
    /// Session persistence failed while reading or writing a store.
    case sessionStoreFailed
    /// The host sent input that is not valid for the current session state.
    case invalidInput
    /// The host requested a provider capability that is not currently supported.
    case unsupportedCapability
    /// Host-owned tool integration could not be prepared for a launch.
    case hostToolsUnavailable
    /// The host sent an input attachment that the provider cannot encode.
    case unsupportedInputAttachment
    /// The provider supports a capability, but it is unavailable for the current session or project.
    case goalUnavailable
}

/// Errors thrown by generic AgentCLIKit services.
public enum AgentCLIError: Error, Equatable, Sendable, LocalizedError {
    /// A requested provider was not registered.
    case providerNotRegistered(AgentProviderID)
    /// The provider is registered but no executable could be found.
    case providerUnavailable(AgentProviderID)
    /// A shell command returned a non-zero exit code.
    case commandFailed(executable: String, arguments: [String], exitCode: Int32, stderr: String)
    /// A shell command could not be launched.
    case commandLaunchFailed(executable: String, reason: String)
    /// A shell argument string ended before a quote was closed.
    case unterminatedQuote(String)
    /// Session persistence failed while reading or writing a store.
    case sessionStoreFailed(String)
    /// The host sent input that is not valid for the current session state.
    case invalidInput(String)
    /// The host requested a provider capability that is not currently supported.
    case unsupportedCapability(providerId: AgentProviderID, capability: String)
    /// Host-owned tool integration could not be prepared for a launch.
    case hostToolsUnavailable(reason: String)
    /// The host sent an input attachment that the provider cannot encode.
    case unsupportedInputAttachment(providerId: AgentProviderID, attachmentId: String, type: String, reason: String)
    /// The provider supports Goal mode, but goal control is unavailable for the current session or project.
    case goalUnavailable(providerId: AgentProviderID, reason: String)

    /// Stable machine-readable code for host UI mapping and telemetry.
    public var code: AgentErrorCode {
        switch self {
        case .providerNotRegistered:
            .providerNotRegistered
        case .providerUnavailable:
            .providerUnavailable
        case .commandFailed:
            .commandFailed
        case .commandLaunchFailed:
            .commandLaunchFailed
        case .unterminatedQuote:
            .unterminatedQuote
        case .sessionStoreFailed:
            .sessionStoreFailed
        case .invalidInput:
            .invalidInput
        case .unsupportedCapability:
            .unsupportedCapability
        case .hostToolsUnavailable:
            .hostToolsUnavailable
        case .unsupportedInputAttachment:
            .unsupportedInputAttachment
        case .goalUnavailable:
            .goalUnavailable
        }
    }

    /// Structured error fields that hosts can inspect instead of parsing `errorDescription`.
    public var metadata: [String: JSONValue] {
        switch self {
        case let .providerNotRegistered(providerId), let .providerUnavailable(providerId):
            ["provider_id": .string(providerId.rawValue)]
        case let .commandFailed(executable, arguments, exitCode, stderr):
            [
                "executable": .string(executable),
                "arguments": .array(arguments.map(JSONValue.string)),
                "exit_code": .number(Double(exitCode)),
                "stderr": .string(stderr)
            ]
        case let .commandLaunchFailed(executable, reason):
            ["executable": .string(executable), "reason": .string(reason)]
        case let .unterminatedQuote(argumentString):
            ["argument_string": .string(argumentString)]
        case let .sessionStoreFailed(message), let .invalidInput(message):
            ["message": .string(message)]
        case let .unsupportedCapability(providerId, capability):
            [
                "provider_id": .string(providerId.rawValue),
                "capability": .string(capability)
            ]
        case let .hostToolsUnavailable(reason):
            ["reason": .string(reason)]
        case let .unsupportedInputAttachment(providerId, attachmentId, type, reason):
            [
                "provider_id": .string(providerId.rawValue),
                "attachment_id": .string(attachmentId),
                "attachment_type": .string(type),
                "reason": .string(reason)
            ]
        case let .goalUnavailable(providerId, reason):
            [
                "provider_id": .string(providerId.rawValue),
                "reason": .string(reason)
            ]
        }
    }

    /// Human-readable description suitable for diagnostics and logs.
    public var errorDescription: String? {
        switch self {
        case let .providerNotRegistered(providerId):
            "Provider '\(providerId.rawValue)' is not registered."
        case let .providerUnavailable(providerId):
            "Provider '\(providerId.rawValue)' is unavailable."
        case let .commandFailed(executable, arguments, exitCode, stderr):
            "Command failed with exit code \(exitCode): \(executable) \(arguments.joined(separator: " ")). \(stderr)"
        case let .commandLaunchFailed(executable, reason):
            "Could not launch command '\(executable)': \(reason)"
        case let .unterminatedQuote(argumentString):
            "Unterminated quote in shell arguments: \(argumentString)"
        case let .sessionStoreFailed(message):
            "Session store failed: \(message)"
        case let .invalidInput(message):
            "Invalid agent input: \(message)"
        case let .unsupportedCapability(providerId, capability):
            "Provider '\(providerId.rawValue)' does not support \(capability)."
        case let .hostToolsUnavailable(reason):
            "Host tools are unavailable: \(reason)"
        case let .unsupportedInputAttachment(providerId, attachmentId, type, reason):
            "Provider '\(providerId.rawValue)' cannot encode attachment '\(attachmentId)' of type '\(type)': \(reason)"
        case let .goalUnavailable(providerId, reason):
            "Provider '\(providerId.rawValue)' cannot control the active goal: \(reason)"
        }
    }
}

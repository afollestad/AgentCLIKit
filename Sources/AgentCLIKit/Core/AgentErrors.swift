import Foundation

/// Stable machine-readable error codes for host UI mapping and logging.
/// Raw values retain their original spelling so persisted errors remain readable.
public enum AgentErrorCode: String, Codable, Hashable, Sendable {
    /// A requested harness was not registered.
    case harnessNotRegistered = "providerNotRegistered"
    /// The harness is registered but no executable could be found.
    case harnessUnavailable = "providerUnavailable"
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
    /// The host requested a harness capability that is not currently supported.
    case unsupportedCapability
    /// Host-owned tool integration could not be prepared for a launch.
    case hostToolsUnavailable
    /// The host sent an input attachment that the harness cannot encode.
    case unsupportedInputAttachment
    /// The harness supports a capability, but it is unavailable for the current session or project.
    case goalUnavailable
}

/// Errors thrown by generic AgentCLIKit services.
public enum AgentCLIError: Error, Equatable, Sendable, LocalizedError {
    /// A requested harness was not registered.
    case harnessNotRegistered(AgentHarnessID)
    /// The harness is registered but no executable could be found.
    case harnessUnavailable(AgentHarnessID)
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
    /// The host requested a harness capability that is not currently supported.
    case unsupportedCapability(harnessId: AgentHarnessID, capability: String)
    /// Host-owned tool integration could not be prepared for a launch.
    case hostToolsUnavailable(reason: String)
    /// The host sent an input attachment that the harness cannot encode.
    case unsupportedInputAttachment(harnessId: AgentHarnessID, attachmentId: String, type: String, reason: String)
    /// The harness supports Goal mode, but goal control is unavailable for the current session or project.
    case goalUnavailable(harnessId: AgentHarnessID, reason: String)

    /// Stable machine-readable code for host UI mapping and telemetry.
    public var code: AgentErrorCode {
        switch self {
        case .harnessNotRegistered:
            .harnessNotRegistered
        case .harnessUnavailable:
            .harnessUnavailable
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
        case let .harnessNotRegistered(harnessId), let .harnessUnavailable(harnessId):
            ["provider_id": .string(harnessId.rawValue)]
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
        case let .unsupportedCapability(harnessId, capability):
            [
                "provider_id": .string(harnessId.rawValue),
                "capability": .string(capability)
            ]
        case let .hostToolsUnavailable(reason):
            ["reason": .string(reason)]
        case let .unsupportedInputAttachment(harnessId, attachmentId, type, reason):
            [
                "provider_id": .string(harnessId.rawValue),
                "attachment_id": .string(attachmentId),
                "attachment_type": .string(type),
                "reason": .string(reason)
            ]
        case let .goalUnavailable(harnessId, reason):
            [
                "provider_id": .string(harnessId.rawValue),
                "reason": .string(reason)
            ]
        }
    }

    /// Human-readable description suitable for diagnostics and logs.
    public var errorDescription: String? {
        switch self {
        case let .harnessNotRegistered(harnessId):
            "Harness '\(harnessId.rawValue)' is not registered."
        case let .harnessUnavailable(harnessId):
            "Harness '\(harnessId.rawValue)' is unavailable."
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
        case let .unsupportedCapability(harnessId, capability):
            "Harness '\(harnessId.rawValue)' does not support \(capability)."
        case let .hostToolsUnavailable(reason):
            "Host tools are unavailable: \(reason)"
        case let .unsupportedInputAttachment(harnessId, attachmentId, type, reason):
            "Harness '\(harnessId.rawValue)' cannot encode attachment '\(attachmentId)' of type '\(type)': \(reason)"
        case let .goalUnavailable(harnessId, reason):
            "Harness '\(harnessId.rawValue)' cannot control the active goal: \(reason)"
        }
    }
}

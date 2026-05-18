import Foundation

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
        }
    }
}

import Foundation

/// Claude's Bash sandbox with network cut off, the Claude side of `AgentIntegrationIsolation.shellNetwork`.
///
/// Claude honors only the last `--settings` flag, so this block rides both as its own flag, for launches whose hook
/// setup failed, and inside the generated hook settings file, which is appended after it and would otherwise drop it.
struct ClaudeSandboxSettings: Codable, Equatable, Sendable {
    struct Filesystem: Codable, Equatable, Sendable {
        let allowWrite: [String]
    }

    struct Network: Codable, Equatable, Sendable {
        let strictAllowlist: Bool
        let allowedDomains: [String]
        let deniedDomains: [String]
    }

    let enabled: Bool
    let autoAllowBashIfSandboxed: Bool
    let allowUnsandboxedCommands: Bool
    let failIfUnavailable: Bool
    let filesystem: Filesystem
    let network: Network

    /// Working-directory and session-temp writes are Claude's defaults; `/tmp` matches Codex's workspace-write
    /// sandbox, where skills commonly write scratch files. The strict allowlist denies instead of prompting, and the
    /// wildcard deny also covers hosts a user's `WebFetch(domain:)` rules would add to that allowlist. Auto-allow stays
    /// off so isolation never loosens the conversation's own approval mode.
    static let networkIsolated = ClaudeSandboxSettings(
        enabled: true,
        autoAllowBashIfSandboxed: false,
        allowUnsandboxedCommands: false,
        failIfUnavailable: true,
        filesystem: Filesystem(allowWrite: ["/tmp", "/private/tmp"]),
        network: Network(strictAllowlist: true, allowedDomains: [], deniedDomains: ["*"])
    )

    /// Inline `--settings` JSON for launches without the hook settings file.
    func settingsArgument() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let argument = String(bytes: try encoder.encode(["sandbox": self]), encoding: .utf8) else {
            throw AgentCLIError.invalidInput("Claude sandbox settings could not be encoded.")
        }
        return argument
    }
}

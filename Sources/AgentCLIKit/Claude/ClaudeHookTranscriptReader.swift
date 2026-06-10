import Foundation

/// Result restored from Claude's JSONL transcript for a hook-driven tool approval.
public enum ClaudeHookTranscriptResolution: Equatable, Sendable {
    /// A permission decision recorded by Claude after a hook request completed.
    case permissionDecision(ClaudeApprovalDecision)
    /// A non-blocking hook error recorded by Claude when the hook transport failed after the host approval was shown.
    case nonBlockingError
}

/// Reads Claude session transcripts to recover hook approval outcomes after a host restart.
///
/// Claude records hook results in per-session JSONL files under `.claude/projects`. Host apps can use this reader to
/// restore pending approval UI without knowing Claude's path encoding or JSON attachment shape. Missing files, malformed
/// lines, malformed hook stdout, and unsupported decision strings are treated as unresolved so restore never invents a
/// denial from incomplete historical data.
public struct ClaudeHookTranscriptReader: Sendable {
    private let homeDirectory: URL

    /// Creates a reader rooted at the home directory that contains Claude's `.claude/projects` transcripts.
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// Returns a restored hook resolution for a tool use in a Claude session and working directory URL.
    ///
    /// The session file path is derived with `ClaudePathEncoder`. Returns `nil` when the transcript is missing,
    /// unreadable, does not contain the tool use, or only contains malformed/unsupported hook entries.
    public func resolution(
        forToolUseId toolUseId: AgentInteractionID,
        sessionId: AgentSessionID,
        workingDirectory: URL
    ) -> ClaudeHookTranscriptResolution? {
        resolution(
            forToolUseId: toolUseId,
            sessionFileURL: ClaudePathEncoder.sessionFileURL(
                sessionId: sessionId,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            )
        )
    }

    /// Returns a restored hook resolution for a tool use in a Claude session and working directory path.
    ///
    /// The path may include `~`; it is canonicalized using `homeDirectory` before Claude's transcript directory is
    /// derived. Missing or malformed transcript data returns `nil`.
    public func resolution(
        forToolUseId toolUseId: AgentInteractionID,
        sessionId: AgentSessionID,
        workingDirectoryPath: String
    ) -> ClaudeHookTranscriptResolution? {
        resolution(
            forToolUseId: toolUseId,
            sessionFileURL: ClaudePathEncoder.sessionFileURL(
                sessionId: sessionId,
                workingDirectoryPath: workingDirectoryPath,
                homeDirectory: homeDirectory
            )
        )
    }

    /// Returns whether Claude persisted a deferred-tool marker for a tool use in a session and working directory path.
    ///
    /// Claude re-runs a deferred tool on `--resume` only when its transcript contains this marker. A deferral whose
    /// process died before flushing the marker resumes as a plain idle session, so hosts should check this before
    /// relying on a respawn to complete a deferred approval. The path may include `~`; it is canonicalized using
    /// `homeDirectory`. Missing or malformed transcript data returns `false`.
    public func hasDeferredToolMarker(
        forToolUseId toolUseId: AgentInteractionID,
        sessionId: AgentSessionID,
        workingDirectoryPath: String
    ) -> Bool {
        hasDeferredToolMarker(
            forToolUseId: toolUseId,
            sessionFileURL: ClaudePathEncoder.sessionFileURL(
                sessionId: sessionId,
                workingDirectoryPath: workingDirectoryPath,
                homeDirectory: homeDirectory
            )
        )
    }

    /// Returns whether Claude persisted a deferred-tool marker for a tool use in an explicit JSONL session file.
    public func hasDeferredToolMarker(
        forToolUseId toolUseId: AgentInteractionID,
        sessionFileURL: URL
    ) -> Bool {
        guard let contents = try? String(contentsOf: sessionFileURL, encoding: .utf8) else {
            return false
        }
        return contents.split(whereSeparator: \.isNewline).contains { line in
            guard let event = Self.transcriptEvent(from: String(line)),
                  event.type == "attachment",
                  let attachment = event.attachment else {
                return false
            }
            return attachment.type == "hook_deferred_tool" && attachment.toolUseId == toolUseId.rawValue
        }
    }

    /// Returns a restored hook resolution for a tool use from an explicit Claude JSONL session file.
    ///
    /// Lines are scanned in transcript order. The first matching terminal result is returned; a matching deferred
    /// decision is returned only if no later terminal result exists for the same tool use.
    public func resolution(
        forToolUseId toolUseId: AgentInteractionID,
        sessionFileURL: URL
    ) -> ClaudeHookTranscriptResolution? {
        guard let contents = try? String(contentsOf: sessionFileURL, encoding: .utf8) else {
            return nil
        }

        var deferredResolution: ClaudeHookTranscriptResolution?
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let event = Self.transcriptEvent(from: String(line)),
                  event.type == "attachment",
                  let attachment = event.attachment,
                  attachment.toolUseId == toolUseId.rawValue else {
                continue
            }

            switch attachment.type {
            case "hook_non_blocking_error":
                return .nonBlockingError
            case "hook_success":
                guard let decision = Self.permissionDecision(fromStdout: attachment.stdout) else {
                    continue
                }
                switch decision {
                case .allow, .deny:
                    return .permissionDecision(decision)
                case .deferDecision:
                    deferredResolution = .permissionDecision(.deferDecision)
                }
            default:
                continue
            }
        }

        return deferredResolution
    }

    private static func transcriptEvent(from line: String) -> ClaudeTranscriptEvent? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeTranscriptEvent.self, from: data)
    }

    private static func permissionDecision(fromStdout stdout: String?) -> ClaudeApprovalDecision? {
        guard let stdout,
              let data = stdout.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(body) = value else {
            return nil
        }

        let decision = hookSpecificPermissionDecision(from: body) ?? topLevelDecision(from: body)
        return decision.flatMap(Self.permissionDecision)
    }

    private static func hookSpecificPermissionDecision(from body: [String: JSONValue]) -> String? {
        guard case let .object(output)? = body["hookSpecificOutput"],
              case let .string(decision)? = output["permissionDecision"] else {
            return nil
        }
        return decision
    }

    private static func topLevelDecision(from body: [String: JSONValue]) -> String? {
        guard case let .string(decision)? = body["decision"] else {
            return nil
        }
        return decision
    }

    private static func permissionDecision(_ rawValue: String) -> ClaudeApprovalDecision? {
        switch rawValue {
        case "allow":
            return .allow
        case "deny":
            return .deny
        case "defer", "deferDecision":
            return .deferDecision
        default:
            return nil
        }
    }
}

private struct ClaudeTranscriptEvent: Decodable {
    let type: String?
    let attachment: ClaudeTranscriptAttachment?
}

private struct ClaudeTranscriptAttachment: Decodable {
    let type: String?
    let toolUseID: String?
    let toolUseIdCamel: String?
    let toolUseIdSnake: String?
    let stdout: String?

    var toolUseId: String? {
        Self.nonEmpty(toolUseID) ?? Self.nonEmpty(toolUseIdCamel) ?? Self.nonEmpty(toolUseIdSnake)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case toolUseID
        case toolUseIdCamel = "toolUseId"
        case toolUseIdSnake = "tool_use_id"
        case stdout
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}

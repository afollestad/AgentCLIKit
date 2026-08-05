import Foundation

/// Helper for paths passed to Claude metadata.
public enum ClaudePathEncoder {
    /// Encodes a file URL as a standardized path string.
    public static func encode(_ url: URL) -> String {
        AgentPathHelpers.canonicalPath(url)
    }

    /// Encodes a path that may include `~` as a canonical path string.
    public static func encode(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        AgentPathHelpers.canonicalPath(path, homeDirectory: homeDirectory)
    }

    /// Encodes a canonical project path into Claude's project-directory name.
    public static func projectDirectoryName(forCanonicalPath path: String) -> String {
        path.unicodeScalars.map { scalar in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                String(scalar)
            } else {
                "-"
            }
        }
        .joined()
    }

    /// Returns Claude's JSONL session file URL for a session and working directory.
    public static func sessionFileURL(sessionId: AgentSessionID, workingDirectory: URL, homeDirectory: URL) -> URL {
        let encodedDirectory = projectDirectoryName(forCanonicalPath: encode(workingDirectory))
        return homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedDirectory, isDirectory: true)
            .appendingPathComponent("\(sessionId.rawValue).jsonl")
    }

    /// Returns Claude's JSONL session file URL for a session and working directory path.
    public static func sessionFileURL(
        sessionId: AgentSessionID,
        workingDirectoryPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let encodedDirectory = projectDirectoryName(forCanonicalPath: encode(workingDirectoryPath, homeDirectory: homeDirectory))
        return homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedDirectory, isDirectory: true)
            .appendingPathComponent("\(sessionId.rawValue).jsonl")
    }

    /// Returns whether Claude's JSONL session file exists for a session and working directory.
    public static func sessionFileExists(
        sessionId: AgentSessionID,
        workingDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: sessionFileURL(
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        ).path)
    }

    /// Returns whether Claude's JSONL session file exists for a session and working directory path.
    public static func sessionFileExists(
        sessionId: AgentSessionID,
        workingDirectoryPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: sessionFileURL(
            sessionId: sessionId,
            workingDirectoryPath: workingDirectoryPath,
            homeDirectory: homeDirectory
        ).path)
    }
}

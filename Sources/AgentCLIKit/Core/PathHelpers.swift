import Foundation

/// File-system helpers shared by provider-neutral services.
public enum AgentPathHelpers {
    /// Returns `path` with a leading tilde expanded against the supplied home directory.
    public static func expandingTilde(in path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    /// Creates a directory if needed and returns its standardized URL.
    @discardableResult
    public static func ensureDirectory(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    /// Returns a symlink-resolved, standardized file URL for stable project matching.
    public static func canonicalFileURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Returns a symlink-resolved, standardized file URL for a path that may include `~`.
    public static func canonicalFileURL(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        canonicalFileURL(expandingTilde(in: path, homeDirectory: homeDirectory))
    }

    /// Returns a symlink-resolved, standardized file path for stable project matching.
    public static func canonicalPath(_ url: URL) -> String {
        canonicalFileURL(url).path
    }

    /// Returns a symlink-resolved, standardized file path for a path that may include `~`.
    public static func canonicalPath(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        canonicalFileURL(path, homeDirectory: homeDirectory).path
    }

    /// Returns whether two file URLs point at the same canonical path.
    public static func isSameCanonicalPath(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    /// Returns whether two paths point at the same canonical path.
    public static func isSameCanonicalPath(
        _ lhs: String,
        _ rhs: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        canonicalPath(lhs, homeDirectory: homeDirectory) == canonicalPath(rhs, homeDirectory: homeDirectory)
    }
}

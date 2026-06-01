import Foundation

/// Removes Claude caveat prefixes that should not be persisted as assistant content.
public enum ClaudeCaveatStripper {
    /// Returns text without a leading caveat line.
    public static func strip(_ text: String) -> String {
        let text = stripLocalCommandCaveat(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.lowercased().hasPrefix("caveat:") else {
            return text
        }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLocalCommandCaveat(from text: String) -> String {
        let startTag = "<local-command-caveat>"
        let endTag = "</local-command-caveat>"
        var stripped = text
        guard let startRange = stripped.range(of: startTag),
              let endRange = stripped.range(of: endTag, range: startRange.upperBound..<stripped.endIndex) else {
            return stripped
        }
        stripped.removeSubrange(endRange)
        stripped.removeSubrange(startRange)
        return stripped
    }
}

enum ClaudeInterruptionMarker {
    private static let userInterruptionMarkers = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]"
    ]

    static func isUserInterruption(_ text: String) -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return userInterruptionMarkers.contains {
            normalizedText.caseInsensitiveCompare($0) == .orderedSame
        }
    }
}

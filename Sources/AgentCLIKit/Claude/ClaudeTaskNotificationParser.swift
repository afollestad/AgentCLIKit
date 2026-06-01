import Foundation

struct ClaudeTaskNotification {
    let taskId: String?
    let toolUseId: String
    let status: String?
    let summary: String?
    let result: String?
    let outputFile: String?
    let totalTokens: Int?
    let toolUses: Int?
    let durationMs: Int?
}

enum ClaudeTaskNotificationParser {
    static func parse(_ rawContent: String) -> ClaudeTaskNotification? {
        guard rawContent.contains("<task-notification>"),
              let toolUseId = tag("tool-use-id", in: rawContent) else {
            return nil
        }

        return ClaudeTaskNotification(
            taskId: tag("task-id", in: rawContent),
            toolUseId: toolUseId,
            status: tag("status", in: rawContent),
            summary: tag("summary", in: rawContent),
            result: tag("result", in: rawContent),
            outputFile: tag("output-file", in: rawContent),
            totalTokens: intTag("total_tokens", in: rawContent),
            toolUses: intTag("tool_uses", in: rawContent),
            durationMs: intTag("duration_ms", in: rawContent)
        )
    }

    private static func intTag(_ tagName: String, in rawContent: String) -> Int? {
        tag(tagName, in: rawContent).flatMap(Int.init)
    }

    private static func tag(_ tagName: String, in rawContent: String) -> String? {
        let pattern = #"<\#(tagName)>(.*?)</\#(tagName)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(
                  in: rawContent,
                  range: NSRange(rawContent.startIndex..<rawContent.endIndex, in: rawContent)
              ),
              let range = Range(match.range(at: 1), in: rawContent) else {
            return nil
        }

        let value = rawContent[range].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return decodedXMLEntities(in: String(value))
    }

    private static func decodedXMLEntities(in value: String) -> String {
        var decoded = value
        for _ in 0..<3 {
            let next = decoded
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard next != decoded else {
                break
            }
            decoded = next
        }
        return decoded
    }
}

import Foundation

struct ClaudeTaskOutputReader: Sendable {
    let maximumBytes: UInt64

    init(maximumBytes: UInt64 = 256 * 1024) {
        self.maximumBytes = maximumBytes
    }

    func resultText(from url: URL) -> String? {
        guard let tail = tailText(from: url) else {
            return nil
        }
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines.reversed() {
            guard let result = assistantText(fromJSONLine: line) else {
                continue
            }
            return result
        }
        return nil
    }

    private func tailText(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        guard let size = try? handle.seekToEnd() else {
            return nil
        }
        let offset = size > maximumBytes ? size - maximumBytes : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if offset > 0, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(...newline)
        }
        return text
    }

    private func assistantText(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let outputLine = try? JSONDecoder().decode(ClaudeTaskOutputLine.self, from: data),
              outputLine.message?.role == "assistant" else {
            return nil
        }
        let text = outputLine.message?.content.compactMap { content -> String? in
            guard content.type == "text" else {
                return nil
            }
            return content.text
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

private struct ClaudeTaskOutputLine: Decodable {
    let message: ClaudeTaskOutputMessage?
}

private struct ClaudeTaskOutputMessage: Decodable {
    let role: String?
    let content: [ClaudeTaskOutputContent]

    enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decodeIfPresent(String.self, forKey: .role)
        self.content = (try? container.decodeIfPresent([ClaudeTaskOutputContent].self, forKey: .content)) ?? []
    }
}

private struct ClaudeTaskOutputContent: Decodable {
    let type: String
    let text: String?
}

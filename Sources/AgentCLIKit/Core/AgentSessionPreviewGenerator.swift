import Foundation

/// Generates a short provider-neutral preview from an initial session prompt.
public enum AgentSessionPreviewGenerator {
    /// Generates a user-facing preview from an initial prompt.
    ///
    /// The preview is intentionally conservative: very short prompts, confirmations, and slash commands return `nil`.
    /// HTML and Markdown image tags are compacted to `(Image)`, Markdown links are flattened to their label text —
    /// a label that is a long file path collapsing to its file name — other HTML tags are stripped outside Markdown
    /// code spans and fences, and long prompts are truncated to a readable 50-character prefix.
    public static func preview(fromInitialPrompt prompt: String) -> String? {
        let initialPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard initialPrompt.count >= 10 else {
            return nil
        }

        let compactedPrompt = compactRichText(in: initialPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compactedPrompt.count >= 10 || compactedPrompt.contains(Self.imagePlaceholder) else {
            return nil
        }

        let lowercasedPrompt = compactedPrompt.lowercased()
        guard !confirmationPrompts.contains(lowercasedPrompt), !compactedPrompt.hasPrefix("/") else {
            return nil
        }
        return truncate(compactedPrompt)
    }

    private static let maximumLength = 50
    /// The shortest prefix a word-boundary truncation may keep. Without a floor, a token longer than the whole budget —
    /// a file path, a pasted URL — pushes the only whitespace in range back to whatever single word preceded it, and
    /// "In <long path> the ..." previews as "In...".
    private static let minimumWordBoundaryLength = maximumLength / 2
    /// The longest link label that may appear in full. Past half the budget a label crowds out the sentence around it,
    /// which is what `compactedLinkLabel(_:)` exists to prevent.
    private static let maximumInlineLabelLength = maximumLength / 2
    private static let imagePlaceholder = "(Image)"
    private static let confirmationPrompts: Set<String> = [
        "y", "yes", "ok", "sure", "yep", "yeah", "yea", "go", "do it", "go ahead"
    ]
    private static let markdownLinkPattern = #"\[([^\[\]]*)\]\([^()]*\)"#
    private static let markdownLinkRegex = try? NSRegularExpression(pattern: markdownLinkPattern)

    private static func truncate(_ preview: String) -> String {
        guard preview.count > maximumLength else {
            return preview
        }
        let prefix = String(preview.prefix(maximumLength))
        if let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }),
           prefix.distance(from: prefix.startIndex, to: lastSpace) >= minimumWordBoundaryLength {
            return String(prefix[..<lastSpace]) + "..."
        }
        return prefix + "..."
    }

    /// Compacts image markup to `(Image)` and flattens Markdown links so previews never show raw link syntax,
    /// which truncation would otherwise cut mid-URL. Markdown images compact before links so the link pattern
    /// cannot match an image's `[alt](url)` tail and leave a stray `!`.
    private static func compactRichText(in text: String) -> String {
        let compactedImages = compactMarkdownImagesOutsideCode(in: compactHTMLImagesOutsideCode(in: text))
        return stripHTMLTagsOutsideCode(in: flattenMarkdownLinksOutsideCode(in: compactedImages))
    }

    private static func compactMarkdownImagesOutsideCode(in text: String) -> String {
        replaceOutsideCode(in: text) { segment in
            segment.replacingOccurrences(
                of: #"!\[[^\[\]]*\]\([^()]*\)"#,
                with: imagePlaceholder,
                options: .regularExpression
            )
        }
    }

    private static func flattenMarkdownLinksOutsideCode(in text: String) -> String {
        replaceOutsideCode(in: text) { segment in
            flattenMarkdownLinks(in: segment)
        }
    }

    /// Replaces each link with its label, compacted. A template replacement cannot transform the capture, so this
    /// walks the matches; a pattern that failed to compile falls back to the plain label.
    private static func flattenMarkdownLinks(in segment: String) -> String {
        guard let markdownLinkRegex else {
            return segment.replacingOccurrences(of: markdownLinkPattern, with: "$1", options: .regularExpression)
        }
        let source = segment as NSString
        var flattened = ""
        var copiedUpTo = 0
        for match in markdownLinkRegex.matches(in: segment, range: NSRange(location: 0, length: source.length)) {
            flattened += source.substring(with: NSRange(location: copiedUpTo, length: match.range.location - copiedUpTo))
            flattened += compactedLinkLabel(source.substring(with: match.range(at: 1)))
            copiedUpTo = match.range.upperBound
        }
        return flattened + source.substring(from: copiedUpTo)
    }

    /// Shortens a file-path link label to its file name, because a host composer inserts an `@` mention as a link
    /// labelled with the whole repo-relative path — which spends the entire preview budget before reaching what the
    /// user actually asked for. Only a label long enough to crowd out the request is compacted, and a URL is left
    /// whole so its trailing path segment cannot stand in for it.
    private static func compactedLinkLabel(_ label: String) -> String {
        guard label.count > maximumInlineLabelLength,
              label.contains("/"),
              !label.contains("://"),
              let fileName = label.split(separator: "/").last else {
            return label
        }
        return String(fileName)
    }

    private static func compactHTMLImagesOutsideCode(in text: String) -> String {
        replaceOutsideCode(in: text) { segment in
            segment.replacingOccurrences(
                of: #"<\s*img\b[^>]*>"#,
                with: imagePlaceholder,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private static func stripHTMLTagsOutsideCode(in text: String) -> String {
        replaceOutsideCode(in: text) { segment in
            segment.replacingOccurrences(
                of: #"</?\s*[A-Za-z][A-Za-z0-9:-]*(?:\s+[^<>]*)?\s*/?>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private static func replaceOutsideCode(in text: String, transform: (String) -> String) -> String {
        var result = ""
        var index = text.startIndex
        var plainStart = index

        func appendPlain(upTo end: String.Index) {
            guard plainStart < end else {
                return
            }
            result += transform(String(text[plainStart..<end]))
        }

        while index < text.endIndex {
            if text[index] == "`" || text[index] == "~" {
                let delimiter = text[index]
                let runEnd = firstNonDelimiterIndex(startingAt: index, delimiter: delimiter, in: text)
                let delimiterCount = text.distance(from: index, to: runEnd)
                guard delimiter == "`" || delimiterCount >= 3 else {
                    index = text.index(after: index)
                    continue
                }
                appendPlain(upTo: index)
                if delimiterCount >= 3 {
                    let codeEnd = endOfFencedCode(
                        startingAt: runEnd,
                        delimiter: delimiter,
                        fenceLength: delimiterCount,
                        in: text
                    )
                    result += String(text[index..<codeEnd])
                    index = codeEnd
                    plainStart = index
                } else {
                    let codeEnd = endOfInlineCode(startingAt: runEnd, tickCount: delimiterCount, in: text)
                    result += String(text[index..<codeEnd])
                    index = codeEnd
                    plainStart = index
                }
            } else {
                index = text.index(after: index)
            }
        }
        appendPlain(upTo: text.endIndex)
        return result
    }

    private static func firstNonBacktickIndex(startingAt start: String.Index, in text: String) -> String.Index {
        firstNonDelimiterIndex(startingAt: start, delimiter: "`", in: text)
    }

    private static func firstNonDelimiterIndex(
        startingAt start: String.Index,
        delimiter: Character,
        in text: String
    ) -> String.Index {
        var index = start
        while index < text.endIndex, text[index] == delimiter {
            index = text.index(after: index)
        }
        return index
    }

    private static func endOfInlineCode(
        startingAt start: String.Index,
        tickCount: Int,
        in text: String
    ) -> String.Index {
        guard let closingStart = matchingBacktickRun(startingAt: start, tickCount: tickCount, in: text) else {
            return text.endIndex
        }
        return text.index(closingStart, offsetBy: tickCount)
    }

    private static func endOfFencedCode(
        startingAt start: String.Index,
        delimiter: Character,
        fenceLength: Int,
        in text: String
    ) -> String.Index {
        var index = start
        while index < text.endIndex {
            guard text[index] == "\n" else {
                index = text.index(after: index)
                continue
            }
            let lineStart = text.index(after: index)
            let closingStart = firstNonWhitespaceIndex(startingAt: lineStart, in: text)
            guard closingStart < text.endIndex, text[closingStart] == delimiter else {
                index = lineStart
                continue
            }
            let closingEnd = firstNonDelimiterIndex(startingAt: closingStart, delimiter: delimiter, in: text)
            if text.distance(from: closingStart, to: closingEnd) >= fenceLength {
                return endOfLine(startingAt: closingEnd, in: text)
            }
            index = lineStart
        }
        return text.endIndex
    }

    private static func matchingBacktickRun(
        startingAt start: String.Index,
        tickCount: Int,
        in text: String
    ) -> String.Index? {
        var index = start
        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }
            let runEnd = firstNonBacktickIndex(startingAt: index, in: text)
            if text.distance(from: index, to: runEnd) == tickCount {
                return index
            }
            index = runEnd
        }
        return nil
    }

    private static func firstNonWhitespaceIndex(startingAt start: String.Index, in text: String) -> String.Index {
        var index = start
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
        return index
    }

    private static func endOfLine(startingAt start: String.Index, in text: String) -> String.Index {
        var index = start
        while index < text.endIndex, text[index] != "\n" {
            index = text.index(after: index)
        }
        return index < text.endIndex ? text.index(after: index) : index
    }
}

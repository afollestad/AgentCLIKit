import Foundation

/// Parser for shell-style argument strings used in provider configuration.
public enum ShellArgumentParser {
    // This compact state machine keeps quoting and escaping behavior in one pass.
    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Splits a shell-style argument string into arguments.
    ///
    /// The parser intentionally supports only portable quoting and escaping rules needed by
    /// provider launch configuration. It does not evaluate variables, command substitution, or globs.
    public static func parse(_ string: String) throws -> [String] {
        try lex(string).map(\.value)
    }

    static func lex(_ string: String) throws -> [ShellArgumentToken] {
        var tokens: [ShellArgumentToken] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasCurrentArgument = false
        var wasQuoted = false
        var tokenStart: String.Index?

        func beginTokenIfNeeded(at index: String.Index) {
            if tokenStart == nil {
                tokenStart = index
            }
        }

        func appendCurrentToken(endingAt endIndex: String.Index) {
            guard let startIndex = tokenStart else {
                return
            }
            let rawValue = String(string[startIndex..<endIndex])
            tokens.append(ShellArgumentToken(
                value: current,
                rawValue: rawValue,
                range: startIndex..<endIndex,
                wasQuoted: wasQuoted
            ))
            current = ""
            hasCurrentArgument = false
            wasQuoted = false
            tokenStart = nil
        }

        var index = string.startIndex
        while index < string.endIndex {
            let character = string[index]
            let nextIndex = string.index(after: index)
            if escaping {
                beginTokenIfNeeded(at: index)
                current.append(character)
                escaping = false
                hasCurrentArgument = true
                index = nextIndex
                continue
            }

            if let activeQuote = quote {
                if activeQuote == "'", character == activeQuote {
                    quote = nil
                    index = nextIndex
                    continue
                }
                if activeQuote == "\"" {
                    if character == "\\" {
                        escaping = true
                        index = nextIndex
                        continue
                    }
                    if character == activeQuote {
                        quote = nil
                        index = nextIndex
                        continue
                    }
                }
                beginTokenIfNeeded(at: index)
                current.append(character)
                hasCurrentArgument = true
                index = nextIndex
                continue
            }

            if character == "\\" {
                beginTokenIfNeeded(at: index)
                escaping = true
                index = nextIndex
                continue
            }

            if character == "'" || character == "\"" {
                beginTokenIfNeeded(at: index)
                quote = character
                wasQuoted = true
                hasCurrentArgument = true
            } else if character.isWhitespace {
                if hasCurrentArgument {
                    appendCurrentToken(endingAt: index)
                }
            } else {
                beginTokenIfNeeded(at: index)
                current.append(character)
                hasCurrentArgument = true
            }
            index = nextIndex
        }

        if escaping {
            beginTokenIfNeeded(at: string.index(before: string.endIndex))
            current.append("\\")
            hasCurrentArgument = true
        }

        if quote != nil {
            throw AgentCLIError.unterminatedQuote(string)
        }

        if hasCurrentArgument {
            appendCurrentToken(endingAt: string.endIndex)
        }

        return tokens
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}

struct ShellArgumentToken {
    let value: String
    let rawValue: String
    let range: Range<String.Index>
    let wasQuoted: Bool
}

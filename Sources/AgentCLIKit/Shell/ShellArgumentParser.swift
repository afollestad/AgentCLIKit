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
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasCurrentArgument = false

        for character in string {
            if escaping {
                current.append(character)
                escaping = false
                hasCurrentArgument = true
                continue
            }

            if let activeQuote = quote {
                if activeQuote == "'", character == activeQuote {
                    quote = nil
                    continue
                }
                if activeQuote == "\"" {
                    if character == "\\" {
                        escaping = true
                        continue
                    }
                    if character == activeQuote {
                        quote = nil
                        continue
                    }
                }
                current.append(character)
                hasCurrentArgument = true
                continue
            }

            if character == "\\" {
                escaping = true
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                hasCurrentArgument = true
            } else if character.isWhitespace {
                if hasCurrentArgument {
                    arguments.append(current)
                    current = ""
                    hasCurrentArgument = false
                }
            } else {
                current.append(character)
                hasCurrentArgument = true
            }
        }

        if escaping {
            current.append("\\")
            hasCurrentArgument = true
        }

        if quote != nil {
            throw AgentCLIError.unterminatedQuote(string)
        }

        if hasCurrentArgument {
            arguments.append(current)
        }

        return arguments
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}

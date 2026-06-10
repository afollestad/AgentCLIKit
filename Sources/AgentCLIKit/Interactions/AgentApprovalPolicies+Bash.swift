import Foundation

extension AgentSessionApprovalRequest {
    var normalizedBashCommand: String? {
        guard let command = stringInput("command")?.trimmingCharacters(in: .whitespacesAndNewlines).approvalNilIfEmpty else {
            return nil
        }
        return Self.approvalIdentityCommand(for: command)
    }

    var bashCommandGroup: String? {
        recommendedBashCommandGroup ?? genericBashCommandGroup
    }

    /// A conservative command group that is safe to *preselect* for session approval.
    ///
    /// Stricter than ``bashCommandGroup``: it rejects every command-substitution and control
    /// construct via ``containsShellExecutionConstruct`` rather than the looser operator-only
    /// check used for offered-but-not-recommended generic groups. A recommended scope is
    /// approved without further host scrutiny, so it must not let a wrapper smuggle execution.
    var recommendedBashCommandGroup: String? {
        guard let command = normalizedBashCommand else {
            return nil
        }
        guard !Self.containsShellExecutionConstruct(command) else {
            return nil
        }

        guard let tokens = Self.parsedCommandTokens(command) else {
            return nil
        }
        guard !tokens.contains(where: Self.isXargsToken) else {
            return nil
        }

        return Self.recommendedSQLiteCommandGroup(tokens)
            ?? Self.recommendedGitCommandGroup(tokens)
            ?? Self.recommendedSearchListCommandGroup(tokens)
    }

    func stringInput(_ key: String) -> String? {
        guard case let .object(object) = toolInput,
              case let .string(value)? = object[key] else {
            return nil
        }
        return value
    }

    private var genericBashCommandGroup: String? {
        guard let command = normalizedBashCommand, !Self.containsShellControlOperator(command) else {
            return nil
        }
        let tokens = (try? ShellArgumentParser.parse(command)).flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackCommandTokens(command)
        guard let executable = tokens.first?.approvalNilIfEmpty, tokens.count >= 2 else {
            return nil
        }

        let groupToken = tokens[1]
        guard Self.isCommandGroupToken(groupToken) else {
            return nil
        }
        return [executable, groupToken].joined(separator: " ").approvalNilIfEmpty
    }
}

private extension AgentSessionApprovalRequest {
    /// Normalizes a Bash command to the identity used for approval matching.
    ///
    /// Strips a leading unquoted `rtk` transparent-wrapper prefix so a wrapped command
    /// (`rtk git log`) shares the same exact and group approval identity as the unwrapped
    /// command (`git log`). The prefix is only stripped when it is a bare leading token
    /// followed by whitespace; a quoted `"rtk"` keeps its own identity so an executable that
    /// merely starts with `rtk` is not misattributed.
    static func approvalIdentityCommand(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("rtk") else {
            return trimmed.approvalNilIfEmpty
        }
        let prefixEnd = trimmed.index(trimmed.startIndex, offsetBy: 3)
        guard prefixEnd < trimmed.endIndex, trimmed[prefixEnd].isWhitespace else {
            return trimmed.approvalNilIfEmpty
        }
        return trimmed[prefixEnd...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .approvalNilIfEmpty
    }

    static func fallbackCommandTokens(_ command: String) -> [String] {
        command
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func parsedCommandTokens(_ command: String) -> [String]? {
        (try? ShellArgumentParser.parse(command)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func isCommandGroupToken(_ token: String) -> Bool {
        guard !token.isEmpty, !token.hasPrefix("-") else {
            return false
        }
        return token.rangeOfCharacter(from: CharacterSet(charactersIn: "./")) == nil
    }

    static func recommendedSQLiteCommandGroup(_ tokens: [String]) -> String? {
        guard let executable = tokens.first,
              executableName(executable) == "sqlite3" else {
            return nil
        }

        var index = 1
        var hasReadonlyFlag = false
        while index < tokens.count {
            let token = tokens[index]
            if token == "-readonly" || token == "--readonly" {
                hasReadonlyFlag = true
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                return nil
            }
            guard hasReadonlyFlag else {
                return nil
            }
            return [executable, "-readonly", token].joined(separator: " ").approvalNilIfEmpty
        }
        return nil
    }

    static func recommendedGitCommandGroup(_ tokens: [String]) -> String? {
        guard let executable = tokens.first,
              executableName(executable) == "git" else {
            return nil
        }

        var index = 1
        while index < tokens.count, tokens[index] == "-C" {
            guard index + 1 < tokens.count else {
                return nil
            }
            index += 2
        }

        guard index < tokens.count else {
            return nil
        }

        let subcommand = tokens[index]
        guard !subcommand.hasPrefix("-") else {
            return nil
        }

        let arguments = Array(tokens.dropFirst(index + 1))
        if subcommand == "branch" {
            guard isListOnlyGitBranch(arguments) else {
                return nil
            }
            return [executable, subcommand].joined(separator: " ")
        }

        guard readOnlyGitSubcommands.contains(subcommand),
              !arguments.contains(where: isUnsafeReadOnlyGitArgument) else {
            return nil
        }
        return [executable, subcommand].joined(separator: " ")
    }

    static func recommendedSearchListCommandGroup(_ tokens: [String]) -> String? {
        guard let executable = tokens.first else {
            return nil
        }

        switch executableName(executable) {
        case "pwd":
            return tokens.count == 1 ? executable : nil
        case "rg", "grep":
            return searchCommandGroup(executable: executable, arguments: Array(tokens.dropFirst()))
        case "ls", "wc":
            return listCommandGroup(executable: executable, arguments: Array(tokens.dropFirst()))
        default:
            return nil
        }
    }

    static func searchCommandGroup(executable: String, arguments: [String]) -> String? {
        guard let target = explicitSearchTarget(arguments) else {
            return executable
        }
        return [executable, target].joined(separator: " ")
    }

    static func listCommandGroup(executable: String, arguments: [String]) -> String? {
        guard let target = explicitListTarget(arguments) else {
            return executable
        }
        return [executable, target].joined(separator: " ")
    }

    static func explicitSearchTarget(_ arguments: [String]) -> String? {
        let values = positionalArguments(arguments, optionValueNames: searchOptionValueNames)
        guard values.count >= 2 else {
            return nil
        }
        return values[1]
    }

    static func explicitListTarget(_ arguments: [String]) -> String? {
        positionalArguments(arguments, optionValueNames: listOptionValueNames).first
    }

    static func positionalArguments(_ arguments: [String], optionValueNames: Set<String>) -> [String] {
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                positional.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if argument.hasPrefix("--") {
                if argument.contains("=") {
                    index += 1
                    continue
                }
                if optionValueNames.contains(argument), index + 1 < arguments.count {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument.count > 1 {
                if optionValueNames.contains(argument), index + 1 < arguments.count {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            positional.append(argument)
            index += 1
        }
        return positional
    }

    static func isListOnlyGitBranch(_ arguments: [String]) -> Bool {
        arguments.allSatisfy { branchListArguments.contains($0) }
    }

    static func isUnsafeReadOnlyGitArgument(_ argument: String) -> Bool {
        argument == "--ext-diff"
            || argument == "--exec"
            || argument == "-c"
            || argument.hasPrefix("--output")
            || argument.hasPrefix("--exec=")
    }

    static func executableName(_ executable: String) -> String {
        URL(fileURLWithPath: executable).lastPathComponent
    }

    static func isXargsToken(_ token: String) -> Bool {
        executableName(token) == "xargs"
    }

    /// Loose gate for offered generic groups: flags only the control operators `&;|<>`.
    /// Recommended groups use the stricter ``containsShellExecutionConstruct``.
    static func containsShellControlOperator(_ command: String) -> Bool {
        let controlCharacters = CharacterSet(charactersIn: "&;|<>")
        var activeQuote: Character?
        var isEscaping = false

        for character in command {
            if isEscaping {
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if activeQuote == character {
                    activeQuote = nil
                } else if activeQuote == nil {
                    activeQuote = character
                }
                continue
            }
            guard activeQuote == nil else {
                continue
            }
            if let scalar = character.unicodeScalars.first,
               controlCharacters.contains(scalar) {
                return true
            }
        }
        return false
    }

    /// Strict gate for recommended groups: in addition to control operators, rejects newlines
    /// and command substitution (`$( )` and backticks) outside single quotes, since either can
    /// run a hidden command that a preselected approval would otherwise wave through.
    static func containsShellExecutionConstruct(_ command: String) -> Bool {
        let controlCharacters = CharacterSet(charactersIn: "&;|<>\n")
        var activeQuote: Character?
        var isEscaping = false
        var previousCharacter: Character?

        for character in command {
            defer {
                previousCharacter = character
            }

            if isEscaping {
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if activeQuote == character {
                    activeQuote = nil
                } else if activeQuote == nil {
                    activeQuote = character
                }
                continue
            }

            if activeQuote == nil,
               let scalar = character.unicodeScalars.first,
               controlCharacters.contains(scalar) {
                return true
            }
            if activeQuote != "'",
               character == "`" || (previousCharacter == "$" && character == "(") {
                return true
            }
        }
        return false
    }

    static var readOnlyGitSubcommands: Set<String> {
        [
            "blame",
            "diff",
            "log",
            "ls-files",
            "merge-base",
            "rev-parse",
            "show",
            "status"
        ]
    }

    static var branchListArguments: Set<String> {
        [
            "--all",
            "--list",
            "--remotes",
            "--show-current",
            "--verbose",
            "-a",
            "-r",
            "-v",
            "-vv"
        ]
    }

    static var searchOptionValueNames: Set<String> {
        [
            "--after-context",
            "--before-context",
            "--context",
            "--file",
            "--glob",
            "--max-count",
            "--max-depth",
            "--regexp",
            "--type",
            "--type-not",
            "-A",
            "-B",
            "-C",
            "-e",
            "-f",
            "-g",
            "-m",
            "-t",
            "-T"
        ]
    }

    static var listOptionValueNames: Set<String> {
        [
            "--block-size",
            "--format",
            "--tabsize",
            "--time-style",
            "-w"
        ]
    }
}

private extension String {
    var approvalNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

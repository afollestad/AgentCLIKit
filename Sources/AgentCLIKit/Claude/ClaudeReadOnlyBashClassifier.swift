import Foundation

// This classifier keeps conservative shell parsing local to Claude hook policy.
enum ClaudeReadOnlyBashClassifier {
    static func isReadOnly(
        _ command: String,
        workingDirectory: URL?,
        homeDirectory: URL
    ) -> Bool {
        guard workingDirectory != nil,
              let segments = commandSegments(command) else {
            return false
        }
        return segments.allSatisfy {
            isReadOnlySegment($0, workingDirectory: workingDirectory, homeDirectory: homeDirectory)
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private static func commandSegments(_ command: String) -> [String]? {
        let characters = Array(command)
        var segments: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaping = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if isEscaping {
                current.append(character)
                isEscaping = false
                index += 1
                continue
            }

            if character == "\\" {
                current.append(character)
                isEscaping = true
                index += 1
                continue
            }

            if let quote = activeQuote {
                if quote != "'", character == "$" || character == "`" {
                    return nil
                }
                current.append(character)
                if character == quote {
                    activeQuote = nil
                }
                index += 1
                continue
            }

            if character == "'" || character == "\"" {
                activeQuote = character
                current.append(character)
                index += 1
                continue
            }

            if character == "$" || character == "`" || character == "|" || character == ";" ||
                character == "<" || character == ">" || character == "\n" {
                return nil
            }

            if character == "&" {
                guard index + 1 < characters.count,
                      characters[index + 1] == "&",
                      let segment = current.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                    return nil
                }
                segments.append(segment)
                current = ""
                index += 2
                continue
            }

            current.append(character)
            index += 1
        }

        guard activeQuote == nil,
              let finalSegment = current.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        segments.append(finalSegment)
        return segments
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    private static func isReadOnlySegment(
        _ segment: String,
        workingDirectory: URL?,
        homeDirectory: URL
    ) -> Bool {
        guard let tokens = try? ShellArgumentParser.parse(segment),
              let executable = tokens.first,
              !executable.contains("/") else {
            return false
        }

        let arguments = Array(tokens.dropFirst())
        switch executableName(executable) {
        case "pwd":
            return arguments.isEmpty
        case "ls":
            return commandPathsStayInsideWorkingDirectory(
                positionalArguments(arguments, optionValueNames: listOptionValueNames),
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            )
        case "wc":
            return !arguments.contains(where: isUnsafeWordCountArgument) &&
                commandPathsStayInsideWorkingDirectory(
                    positionalArguments(arguments, optionValueNames: listOptionValueNames),
                    workingDirectory: workingDirectory,
                    homeDirectory: homeDirectory
                )
        case "rg", "grep":
            return searchCommandPathsStayInsideWorkingDirectory(
                arguments,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            )
        case "git":
            return isReadOnlyGitCommand(
                arguments,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            )
        case "sqlite3":
            return isReadOnlySQLiteCommand(
                arguments,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            )
        default:
            return false
        }
    }

    private static func isReadOnlyGitCommand(
        _ arguments: [String],
        workingDirectory: URL?,
        homeDirectory: URL
    ) -> Bool {
        var index = 0
        while index < arguments.count, arguments[index] == "-C" {
            guard index + 1 < arguments.count,
                  isPathContained(arguments[index + 1], in: workingDirectory, homeDirectory: homeDirectory) else {
                return false
            }
            index += 2
        }

        guard index < arguments.count else {
            return false
        }

        let subcommand = arguments[index]
        guard !subcommand.hasPrefix("-") else {
            return false
        }

        let subcommandArguments = Array(arguments.dropFirst(index + 1))
        if subcommand == "branch" {
            return subcommandArguments.allSatisfy { branchListArguments.contains($0) }
        }

        return readOnlyGitSubcommands.contains(subcommand) &&
            !subcommandArguments.contains(where: isUnsafeReadOnlyGitArgument)
    }

    private static func isReadOnlySQLiteCommand(
        _ arguments: [String],
        workingDirectory: URL?,
        homeDirectory: URL
    ) -> Bool {
        var hasReadonlyFlag = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-readonly" || argument == "--readonly" {
                hasReadonlyFlag = true
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                return false
            }
            let queryArguments = Array(arguments.dropFirst(index + 1))
            return hasReadonlyFlag &&
                isPathContained(argument, in: workingDirectory, homeDirectory: homeDirectory) &&
                !queryArguments.isEmpty &&
                queryArguments.allSatisfy(isReadOnlySQLiteQuery)
        }
        return false
    }

    private static func isReadOnlySQLiteQuery(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.hasPrefix(".") else {
            return false
        }

        var statement = trimmedQuery
        if statement.hasSuffix(";") {
            statement.removeLast()
            statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !statement.contains(";") else {
            return false
        }

        let uppercasedQuery = statement.uppercased()
        guard !uppercasedQuery.contains("LOAD_EXTENSION") else {
            return false
        }

        return uppercasedQuery.hasPrefix("SELECT ") ||
            uppercasedQuery.hasPrefix("SELECT\n") ||
            uppercasedQuery == "SELECT" ||
            uppercasedQuery.hasPrefix("WITH ") ||
            uppercasedQuery.hasPrefix("WITH\n") ||
            uppercasedQuery == "WITH" ||
            uppercasedQuery.hasPrefix("EXPLAIN ")
    }

    private static func commandPathsStayInsideWorkingDirectory(
        _ paths: [String],
        workingDirectory: URL?,
        homeDirectory: URL
    ) -> Bool {
        paths.allSatisfy { path in
            path != "-" && isPathContained(path, in: workingDirectory, homeDirectory: homeDirectory)
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private static func searchCommandPathsStayInsideWorkingDirectory(
        _ arguments: [String],
        workingDirectory: URL?,
        homeDirectory: URL
    ) -> Bool {
        var paths: [String] = []
        var patternConsumed = false
        var pathOnlyMode = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let remainingArguments = Array(arguments.dropFirst(index + 1))
                if pathOnlyMode || patternConsumed {
                    paths.append(contentsOf: remainingArguments)
                } else if !remainingArguments.isEmpty {
                    patternConsumed = true
                    paths.append(contentsOf: remainingArguments.dropFirst())
                }
                break
            }

            if argument == "--files" {
                pathOnlyMode = true
                index += 1
                continue
            }

            if argument == "--pre" || argument.hasPrefix("--pre=") {
                return false
            }

            if argument == "-e" || argument == "--regexp" {
                guard index + 1 < arguments.count else {
                    return false
                }
                patternConsumed = true
                index += 2
                continue
            }

            if argument.hasPrefix("--regexp=") || argument.hasPrefix("-e"), argument.count > 2 {
                patternConsumed = true
                index += 1
                continue
            }

            if argument == "-f" || argument == "--file" {
                guard index + 1 < arguments.count,
                      isPathContained(arguments[index + 1], in: workingDirectory, homeDirectory: homeDirectory) else {
                    return false
                }
                patternConsumed = true
                index += 2
                continue
            }

            if argument.hasPrefix("--file=") {
                guard let patternFilePath = argument.split(separator: "=", maxSplits: 1).last,
                      isPathContained(String(patternFilePath), in: workingDirectory, homeDirectory: homeDirectory) else {
                    return false
                }
                patternConsumed = true
                index += 1
                continue
            }

            if argument.hasPrefix("-f"), argument.count > 2 {
                let patternFilePath = String(argument.dropFirst(2))
                guard isPathContained(patternFilePath, in: workingDirectory, homeDirectory: homeDirectory) else {
                    return false
                }
                patternConsumed = true
                index += 1
                continue
            }

            if argument.hasPrefix("--") {
                if argument.contains("=") {
                    index += 1
                    continue
                }
                if searchOptionValueNames.contains(argument), index + 1 < arguments.count {
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if argument.hasPrefix("-"), argument.count > 1 {
                if searchOptionValueNames.contains(argument), index + 1 < arguments.count {
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if pathOnlyMode || patternConsumed {
                paths.append(argument)
            } else {
                patternConsumed = true
            }
            index += 1
        }

        guard patternConsumed || pathOnlyMode else {
            return false
        }
        return commandPathsStayInsideWorkingDirectory(paths, workingDirectory: workingDirectory, homeDirectory: homeDirectory)
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    private static func positionalArguments(_ arguments: [String], optionValueNames: Set<String>) -> [String] {
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

    private static func isPathContained(_ path: String, in workingDirectory: URL?, homeDirectory: URL) -> Bool {
        guard let workingDirectory,
              let pathURL = fileURL(for: path, workingDirectory: workingDirectory, homeDirectory: homeDirectory) else {
            return false
        }

        let rootPath = AgentPathHelpers.canonicalPath(workingDirectory)
        let targetPath = AgentPathHelpers.canonicalPath(pathURL)
        return targetPath == rootPath || targetPath.hasPrefix(rootPath.appending("/"))
    }

    private static func fileURL(for path: String, workingDirectory: URL, homeDirectory: URL) -> URL? {
        if path == "~" || path.hasPrefix("~/") {
            return AgentPathHelpers.expandingTilde(in: path, homeDirectory: homeDirectory)
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return workingDirectory.appendingPathComponent(path)
    }

    private static func executableName(_ executable: String) -> String {
        URL(fileURLWithPath: executable).lastPathComponent
    }

    private static func isUnsafeReadOnlyGitArgument(_ argument: String) -> Bool {
        argument == "--ext-diff"
            || argument == "--exec"
            || argument == "-c"
            || argument.hasPrefix("--exec=")
            || argument.hasPrefix("--git-dir")
            || argument.hasPrefix("--output")
            || argument.hasPrefix("--work-tree")
    }

    private static func isUnsafeWordCountArgument(_ argument: String) -> Bool {
        argument == "--files0-from" ||
            argument.hasPrefix("--files0-from=")
    }

    private static var readOnlyGitSubcommands: Set<String> {
        ["blame", "diff", "log", "ls-files", "merge-base", "rev-parse", "show", "status"]
    }

    private static var branchListArguments: Set<String> {
        ["--all", "--list", "--remotes", "--show-current", "--verbose", "-a", "-r", "-v", "-vv"]
    }

    private static var searchOptionValueNames: Set<String> {
        [
            "--after-context", "--before-context", "--context", "--file", "--glob", "--max-count",
            "--max-depth", "--regexp", "--type", "--type-not", "-A", "-B", "-C", "-e", "-f", "-g", "-m", "-t", "-T"
        ]
    }

    private static var listOptionValueNames: Set<String> {
        ["--block-size", "--format", "--tabsize", "--time-style", "-w"]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

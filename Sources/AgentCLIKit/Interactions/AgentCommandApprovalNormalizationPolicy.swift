import Foundation

/// Policy for deriving a provider-neutral approval identity from wrapped command tool input.
public struct AgentCommandApprovalNormalizationPolicy: Codable, Equatable, Sendable {
    /// Default policy used by approval requests when no host-specific identity was supplied.
    public static let `default` = AgentCommandApprovalNormalizationPolicy()

    /// Transparent wrapper executable basenames stripped before deriving approval identity.
    public let transparentWrapperBasenames: [String]
    /// Shell executable basenames that may wrap a command string through safe `-c` forms.
    public let shellWrapperBasenames: [String]
    /// Environment wrapper basenames stripped when followed only by assignments, `--`, and a command.
    public let envWrapperBasenames: [String]
    /// Maximum number of wrapper layers to unwrap.
    public let maxUnwrapDepth: Int

    /// Creates a command approval normalization policy.
    public init(
        transparentWrapperBasenames: [String] = ["rtk"],
        shellWrapperBasenames: [String] = ["sh", "bash", "zsh"],
        envWrapperBasenames: [String] = ["env"],
        maxUnwrapDepth: Int = 8
    ) {
        self.transparentWrapperBasenames = transparentWrapperBasenames
        self.shellWrapperBasenames = shellWrapperBasenames
        self.envWrapperBasenames = envWrapperBasenames
        self.maxUnwrapDepth = max(maxUnwrapDepth, 0)
    }

    /// Returns canonical tool input for approval matching when this policy can derive one.
    public func normalizedApprovalIdentityToolInput(toolName: String, toolInput: JSONValue) -> JSONValue? {
        guard toolName == "Bash",
              let command = toolInput.stringInput("command"),
              let normalizedCommand = approvalIdentityCommand(for: command) else {
            return nil
        }
        return .object(["command": .string(normalizedCommand)])
    }

    func approvalIdentityCommand(for command: String) -> String? {
        var current = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            return nil
        }

        for _ in 0..<maxUnwrapDepth {
            guard let unwrapped = unwrapOnce(current), unwrapped != current else {
                break
            }
            current = unwrapped
        }
        return current.nilIfEmpty
    }

    func legacyRawExactCommand(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return transparentWrapperCommand(from: trimmed) ?? trimmed
    }

    private func unwrapOnce(_ command: String) -> String? {
        transparentWrapperCommand(from: command)
            ?? envWrappedCommand(from: command)
            ?? shellWrappedCommand(from: command)
    }

    private func transparentWrapperCommand(from command: String) -> String? {
        guard let tokens = try? ShellArgumentParser.lex(command),
              let first = tokens.first,
              !first.wasQuoted,
              transparentWrapperBasenames.contains(Self.executableName(first.value)),
              tokens.count >= 2 else {
            return nil
        }
        return command[tokens[1].range.lowerBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func envWrappedCommand(from command: String) -> String? {
        guard let tokens = try? ShellArgumentParser.lex(command),
              let first = tokens.first,
              !first.wasQuoted,
              envWrapperBasenames.contains(Self.executableName(first.value)) else {
            return nil
        }

        var index = 1
        if index < tokens.count, tokens[index].value == "--" {
            index += 1
        }
        while index < tokens.count, Self.isEnvironmentAssignment(tokens[index].value) {
            index += 1
        }
        guard index < tokens.count,
              !tokens[index].value.hasPrefix("-") else {
            return nil
        }
        return command[tokens[index].range.lowerBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func shellWrappedCommand(from command: String) -> String? {
        guard let tokens = try? ShellArgumentParser.lex(command),
              let first = tokens.first,
              !first.wasQuoted,
              shellWrapperBasenames.contains(Self.executableName(first.value)) else {
            return nil
        }

        let commandIndex: Int
        let tokenValues = tokens.map(\.value)
        if tokenValues.count == 3, ["-c", "-lc", "-cl"].contains(tokenValues[1]) {
            commandIndex = 2
        } else if tokenValues.count == 4, tokenValues[1] == "-l", tokenValues[2] == "-c" {
            commandIndex = tokens.count - 1
        } else {
            return nil
        }

        return tokens[commandIndex].value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func executableName(_ executable: String) -> String {
        URL(fileURLWithPath: executable).lastPathComponent
    }

    private static func isEnvironmentAssignment(_ value: String) -> Bool {
        guard let equalsIndex = value.firstIndex(of: "="), equalsIndex > value.startIndex else {
            return false
        }
        let key = value[..<equalsIndex]
        guard let first = key.first, first == "_" || first.isLetter else {
            return false
        }
        return key.allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }
}

private extension JSONValue {
    func stringInput(_ key: String) -> String? {
        guard case let .object(object) = self,
              case let .string(value)? = object[key] else {
            return nil
        }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

import Foundation

enum CodexConfigKey {
    static let projects = "projects"
    static let trustLevel = "trust_level"
    static let mcpServers = "mcp_servers"
    static let command = "command"
    static let args = "args"
    static let env = "env"
    static let envVars = "env_vars"
    static let cwd = "cwd"
    static let url = "url"
    static let bearerTokenEnvVar = "bearer_token_env_var"
    static let httpHeaders = "http_headers"
    static let envHTTPHeaders = "env_http_headers"
    static let startupTimeoutSec = "startup_timeout_sec"
    static let toolTimeoutSec = "tool_timeout_sec"
    static let enabled = "enabled"
    static let required = "required"
    static let enabledTools = "enabled_tools"
    static let disabledTools = "disabled_tools"
    static let defaultToolsApprovalMode = "default_tools_approval_mode"
}

struct CodexMCPServerConfigBuilder {
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var envVars: [String]?
    var cwd: String?
    var url: String?
    var bearerTokenEnvVar: String?
    var httpHeaders: [String: String]?
    var envHTTPHeaders: [String: String]?
    var startupTimeoutSec: Int?
    var toolTimeoutSec: Int?
    var enabled: Bool?
    var required: Bool?
    var enabledTools: [String]?
    var disabledTools: [String]?
    var defaultToolsApprovalMode: String?

    mutating func applyRoot(_ values: [String: CodexTOMLValue]) {
        command = values[CodexConfigKey.command]?.stringValue ?? command
        args = values[CodexConfigKey.args]?.stringArrayValue ?? args
        env = values[CodexConfigKey.env]?.stringMapValue ?? env
        envVars = values[CodexConfigKey.envVars]?.stringArrayValue ?? envVars
        cwd = values[CodexConfigKey.cwd]?.stringValue ?? cwd
        url = values[CodexConfigKey.url]?.stringValue ?? url
        bearerTokenEnvVar = values[CodexConfigKey.bearerTokenEnvVar]?.stringValue ?? bearerTokenEnvVar
        httpHeaders = values[CodexConfigKey.httpHeaders]?.stringMapValue ?? httpHeaders
        envHTTPHeaders = values[CodexConfigKey.envHTTPHeaders]?.stringMapValue ?? envHTTPHeaders
        startupTimeoutSec = values[CodexConfigKey.startupTimeoutSec]?.intValue ?? startupTimeoutSec
        toolTimeoutSec = values[CodexConfigKey.toolTimeoutSec]?.intValue ?? toolTimeoutSec
        enabled = values[CodexConfigKey.enabled]?.boolValue ?? enabled
        required = values[CodexConfigKey.required]?.boolValue ?? required
        enabledTools = values[CodexConfigKey.enabledTools]?.stringArrayValue ?? enabledTools
        disabledTools = values[CodexConfigKey.disabledTools]?.stringArrayValue ?? disabledTools
        defaultToolsApprovalMode = values[CodexConfigKey.defaultToolsApprovalMode]?.stringValue ?? defaultToolsApprovalMode
    }

    func build() -> CodexMCPServerConfig {
        CodexMCPServerConfig(
            command: command,
            args: args,
            env: env,
            envVars: envVars,
            cwd: cwd,
            url: url,
            bearerTokenEnvVar: bearerTokenEnvVar,
            httpHeaders: httpHeaders,
            envHTTPHeaders: envHTTPHeaders,
            startupTimeoutSec: startupTimeoutSec,
            toolTimeoutSec: toolTimeoutSec,
            enabled: enabled,
            required: required,
            enabledTools: enabledTools,
            disabledTools: disabledTools,
            defaultToolsApprovalMode: defaultToolsApprovalMode
        )
    }
}

struct CodexTOMLDocument {
    let lines: [String]
    let tables: [CodexTOMLTable]

    init(text: String) {
        self.lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.tables = Self.parseTables(lines: lines)
    }

    func removingTables(where shouldRemove: (CodexTOMLTable) -> Bool) -> String {
        let ranges = tables.filter(shouldRemove).map(\.range)
        guard !ranges.isEmpty else {
            return lines.joined(separator: "\n")
        }
        let filtered = lines.enumerated().compactMap { index, line -> String? in
            ranges.contains { $0.contains(index) } ? nil : line
        }
        return filtered.joined(separator: "\n").trimmedTrailingWhitespaceAndNewlines()
    }

    private static func parseTables(lines: [String]) -> [CodexTOMLTable] {
        let starts = lines.enumerated().compactMap { index, line -> (Int, [String])? in
            guard let path = CodexTOMLParser.tablePath(from: line) else {
                return nil
            }
            return (index, path)
        }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1].0 : lines.count
            return CodexTOMLTable(
                path: start.1,
                bodyLines: Array(lines[(start.0 + 1)..<end]),
                range: start.0..<end
            )
        }
    }
}

struct CodexTOMLTable {
    let path: [String]
    let bodyLines: [String]
    let range: Range<Int>
}

enum CodexTOMLValue: Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case stringArray([String])
    case stringMap([String: String])

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        guard case let .int(value) = self else {
            return nil
        }
        return value
    }

    var stringArrayValue: [String]? {
        guard case let .stringArray(value) = self else {
            return nil
        }
        return value
    }

    var stringMapValue: [String: String]? {
        guard case let .stringMap(value) = self else {
            return nil
        }
        return value
    }
}

enum CodexTOMLParser {
    static func tablePath(from line: String) -> [String]? {
        let trimmed = stripComment(from: line).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return nil
        }
        let inner = String(trimmed.dropFirst().dropLast())
        guard !inner.hasPrefix("[") else {
            return nil
        }
        return splitTopLevel(inner, separator: ".").compactMap(parseKey)
    }

    static func keyValues(from lines: [String]) -> [String: CodexTOMLValue] {
        lines.compactMap { line -> (String, CodexTOMLValue)? in
            let stripped = stripComment(from: line).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty,
                  let equalsIndex = firstTopLevelEquals(in: stripped) else {
                return nil
            }
            let keyText = String(stripped[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            let valueText = String(stripped[stripped.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            guard let key = parseKey(keyText),
                  let value = parseValue(valueText) else {
                return nil
            }
            return (key, value)
        }.reduce(into: [:]) { result, entry in
            result[entry.0] = entry.1
        }
    }

    private static func parseValue(_ text: String) -> CodexTOMLValue? {
        if let string = parseQuotedString(text) {
            return .string(string)
        }
        if text == "true" {
            return .bool(true)
        }
        if text == "false" {
            return .bool(false)
        }
        if let int = Int(text) {
            return .int(int)
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            let values = splitTopLevel(inner, separator: ",").compactMap { parseQuotedString($0.trimmingCharacters(in: .whitespaces)) }
            return .stringArray(values)
        }
        if text.hasPrefix("{"), text.hasSuffix("}") {
            return .stringMap(parseInlineStringMap(String(text.dropFirst().dropLast())))
        }
        return nil
    }

    private static func parseInlineStringMap(_ text: String) -> [String: String] {
        splitTopLevel(text, separator: ",").compactMap { entry -> (String, String)? in
            guard let equalsIndex = firstTopLevelEquals(in: entry) else {
                return nil
            }
            let keyText = String(entry[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            let valueText = String(entry[entry.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            guard let key = parseKey(keyText), let value = parseQuotedString(valueText) else {
                return nil
            }
            return (key, value)
        }.reduce(into: [:]) { result, entry in
            result[entry.0] = entry.1
        }
    }

    private static func parseKey(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let quoted = parseQuotedString(trimmed) {
            return quoted
        }
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func parseQuotedString(_ text: String) -> String? {
        guard text.first == "\"", text.last == "\"" else {
            return nil
        }
        var result = ""
        var isEscaped = false
        for character in text.dropFirst().dropLast() {
            if isEscaped {
                switch character {
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                case "\"":
                    result.append("\"")
                case "\\":
                    result.append("\\")
                default:
                    result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func stripComment(from line: String) -> String {
        var isInString = false
        var isEscaped = false
        for index in line.indices {
            let character = line[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = isInString
                continue
            }
            if character == "\"" {
                isInString.toggle()
                continue
            }
            if character == "#", !isInString {
                return String(line[..<index])
            }
        }
        return line
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func firstTopLevelEquals(in text: String) -> String.Index? {
        var isInString = false
        var isEscaped = false
        var bracketDepth = 0
        var braceDepth = 0
        for index in text.indices {
            let character = text[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = isInString
                continue
            }
            if character == "\"" {
                isInString.toggle()
                continue
            }
            guard !isInString else {
                continue
            }
            switch character {
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth -= 1
            case "{":
                braceDepth += 1
            case "}":
                braceDepth -= 1
            case "=" where bracketDepth == 0 && braceDepth == 0:
                return index
            default:
                continue
            }
        }
        return nil
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var values: [String] = []
        var current = ""
        var isInString = false
        var isEscaped = false
        var bracketDepth = 0
        var braceDepth = 0
        for character in text {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                isEscaped = isInString
                continue
            }
            if character == "\"" {
                current.append(character)
                isInString.toggle()
                continue
            }
            if !isInString {
                switch character {
                case "[":
                    bracketDepth += 1
                case "]":
                    bracketDepth -= 1
                case "{":
                    braceDepth += 1
                case "}":
                    braceDepth -= 1
                case separator where bracketDepth == 0 && braceDepth == 0:
                    values.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                default:
                    break
                }
            }
            current.append(character)
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            values.append(trimmed)
        }
        return values
    }
}

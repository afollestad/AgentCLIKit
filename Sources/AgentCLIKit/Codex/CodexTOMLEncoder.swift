import Foundation

enum CodexTOMLEncoder {
    static func mcpServerSection(id: String, server: CodexMCPServerConfig) -> String {
        var lines = ["[mcp_servers.\(quotedSegment(id))]"]
        appendString(CodexConfigKey.command, server.command, to: &lines)
        appendStringArray(CodexConfigKey.args, server.args, to: &lines)
        appendStringArray(CodexConfigKey.envVars, server.envVars, to: &lines)
        appendString(CodexConfigKey.cwd, server.cwd, to: &lines)
        appendString(CodexConfigKey.url, server.url, to: &lines)
        appendString(CodexConfigKey.bearerTokenEnvVar, server.bearerTokenEnvVar, to: &lines)
        appendInt(CodexConfigKey.startupTimeoutSec, server.startupTimeoutSec, to: &lines)
        appendInt(CodexConfigKey.toolTimeoutSec, server.toolTimeoutSec, to: &lines)
        appendBool(CodexConfigKey.enabled, server.enabled, to: &lines)
        appendBool(CodexConfigKey.required, server.required, to: &lines)
        appendStringArray(CodexConfigKey.enabledTools, server.enabledTools, to: &lines)
        appendStringArray(CodexConfigKey.disabledTools, server.disabledTools, to: &lines)
        appendString(CodexConfigKey.defaultToolsApprovalMode, server.defaultToolsApprovalMode, to: &lines)
        appendTable(CodexConfigKey.env, values: server.env, serverID: id, to: &lines)
        appendTable(CodexConfigKey.httpHeaders, values: server.httpHeaders, serverID: id, to: &lines)
        appendTable(CodexConfigKey.envHTTPHeaders, values: server.envHTTPHeaders, serverID: id, to: &lines)
        return lines.joined(separator: "\n")
    }

    static func quotedSegment(_ value: String) -> String {
        string(value)
    }

    static func string(_ value: String) -> String {
        "\"\(escaped(value))\""
    }

    private static func appendString(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value else {
            return
        }
        lines.append("\(key) = \(string(value))")
    }

    private static func appendStringArray(_ key: String, _ values: [String]?, to lines: inout [String]) {
        guard let values, !values.isEmpty else {
            return
        }
        lines.append("\(key) = [\(values.map(string).joined(separator: ", "))]")
    }

    private static func appendBool(_ key: String, _ value: Bool?, to lines: inout [String]) {
        guard let value else {
            return
        }
        lines.append("\(key) = \(value ? "true" : "false")")
    }

    private static func appendInt(_ key: String, _ value: Int?, to lines: inout [String]) {
        guard let value else {
            return
        }
        lines.append("\(key) = \(value)")
    }

    private static func appendTable(_ key: String, values: [String: String]?, serverID: String, to lines: inout [String]) {
        guard let values, !values.isEmpty else {
            return
        }
        lines.append("")
        lines.append("[mcp_servers.\(quotedSegment(serverID)).\(key)]")
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            lines.append("\(quotedSegment(name)) = \(string(value))")
        }
    }

    private static func escaped(_ value: String) -> String {
        value.reduce(into: "") { output, character in
            switch character {
            case "\\":
                output.append("\\\\")
            case "\"":
                output.append("\\\"")
            case "\n":
                output.append("\\n")
            case "\t":
                output.append("\\t")
            default:
                output.append(character)
            }
        }
    }
}

extension Dictionary where Key == String, Value == CodexTOMLValue {
    func stringMap() -> [String: String]? {
        var result: [String: String] = [:]
        for (key, value) in self {
            if let string = value.stringValue {
                result[key] = string
            }
        }
        return result.isEmpty ? nil : result
    }
}

extension String {
    func trimmedTrailingWhitespaceAndNewlines() -> String {
        var output = self
        while output.last?.isWhitespace == true {
            output.removeLast()
        }
        return output
    }

    func appendingTOMLSections(_ sections: String) -> String {
        let trimmedSections = sections.trimmedTrailingWhitespaceAndNewlines()
        guard !trimmedSections.isEmpty else {
            return trimmedTrailingWhitespaceAndNewlines()
        }
        let base = trimmedTrailingWhitespaceAndNewlines()
        guard !base.isEmpty else {
            return trimmedSections
        }
        return "\(base)\n\n\(trimmedSections)"
    }
}

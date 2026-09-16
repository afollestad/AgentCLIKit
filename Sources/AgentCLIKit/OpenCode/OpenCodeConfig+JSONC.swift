import Foundation

/// Keeps user comments and unrelated configuration byte-for-byte when replacing the MCP member.
struct OpenCodeJSONCDocument {
    let data: Data
    let root: [String: JSONValue]
    private let cleaned: [UInt8]
    private let commentsRemoved: [UInt8]

    init(data: Data) throws {
        self.data = data
        let commentsRemoved = try Self.clean(Array(data))
        self.commentsRemoved = commentsRemoved
        let cleaned = try Self.removingTrailingCommas(commentsRemoved)
        self.cleaned = cleaned
        root = try JSONDecoder().decode([String: JSONValue].self, from: Data(cleaned))
    }

    func replacingRootMember(_ key: String, with replacement: Data) throws -> Data {
        let members = try rootMembers()
        var bytes = Array(data)
        if let range = members[key] {
            bytes.replaceSubrange(range, with: replacement)
        } else {
            guard let end = cleaned.lastIndex(of: 0x7D) else { throw Self.invalidDocument() }
            let previous = commentsRemoved[..<end].last(where: { !Self.isWhitespace($0) })
            let separator = previous == 0x7B || previous == 0x2C ? "" : ","
            let encodedKey = try JSONEncoder().encode(key)
            let addition = Data("\(separator)\n  ".utf8) + encodedKey + Data(": ".utf8) + replacement + Data("\n".utf8)
            bytes.insert(contentsOf: addition, at: end)
        }
        return Data(bytes)
    }

    private func rootMembers() throws -> [String: Range<Int>] {
        guard let start = cleaned.firstIndex(where: { !Self.isWhitespace($0) }), cleaned[start] == 0x7B else {
            throw Self.invalidDocument()
        }
        var index = start + 1
        var members: [String: Range<Int>] = [:]
        while index < cleaned.count {
            while index < cleaned.count && (Self.isWhitespace(cleaned[index]) || cleaned[index] == 0x2C) { index += 1 }
            if index == cleaned.count || cleaned[index] == 0x7D { break }
            let keyEnd = try Self.stringEnd(cleaned, start: index)
            let key = try JSONDecoder().decode(String.self, from: Data(cleaned[index..<keyEnd]))
            index = keyEnd
            while index < cleaned.count && Self.isWhitespace(cleaned[index]) { index += 1 }
            guard index < cleaned.count, cleaned[index] == 0x3A else { throw Self.invalidDocument() }
            index += 1
            while index < cleaned.count && Self.isWhitespace(cleaned[index]) { index += 1 }
            let valueStart = index
            index = try Self.valueEnd(cleaned, start: index)
            guard members[key] == nil else { throw Self.invalidDocument() }
            members[key] = valueStart..<index
        }
        return members
    }

    private static func clean(_ bytes: [UInt8]) throws -> [UInt8] {
        var result = bytes
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x22 {
                index = try stringEnd(bytes, start: index)
                continue
            }
            guard bytes[index] == 0x2F, index + 1 < bytes.count else { index += 1; continue }
            if bytes[index + 1] == 0x2F {
                while index < bytes.count && bytes[index] != 0x0A {
                    result[index] = 0x20
                    index += 1
                }
            } else if bytes[index + 1] == 0x2A {
                result[index] = 0x20
                result[index + 1] = 0x20
                index += 2
                var closed = false
                while index + 1 < bytes.count {
                    if bytes[index] == 0x2A && bytes[index + 1] == 0x2F {
                        result[index] = 0x20
                        result[index + 1] = 0x20
                        index += 2
                        closed = true
                        break
                    }
                    if !isWhitespace(bytes[index]) { result[index] = 0x20 }
                    index += 1
                }
                guard closed else { throw invalidDocument() }
            } else {
                index += 1
            }
        }
        return result
    }

    private static func removingTrailingCommas(_ bytes: [UInt8]) throws -> [UInt8] {
        var result = bytes
        var index = 0
        while index < result.count {
            if result[index] == 0x22 {
                index = try stringEnd(result, start: index)
                continue
            }
            if result[index] == 0x2C {
                var next = index + 1
                while next < result.count && isWhitespace(result[next]) { next += 1 }
                if next < result.count && (result[next] == 0x7D || result[next] == 0x5D) { result[index] = 0x20 }
            }
            index += 1
        }
        return result
    }

    private static func valueEnd(_ bytes: [UInt8], start: Int) throws -> Int {
        guard start < bytes.count else { throw invalidDocument() }
        if bytes[start] == 0x22 { return try stringEnd(bytes, start: start) }
        if bytes[start] == 0x7B || bytes[start] == 0x5B {
            var depth = 0
            var index = start
            while index < bytes.count {
                if bytes[index] == 0x22 {
                    index = try stringEnd(bytes, start: index)
                    continue
                }
                if bytes[index] == 0x7B || bytes[index] == 0x5B { depth += 1 }
                if bytes[index] == 0x7D || bytes[index] == 0x5D {
                    depth -= 1
                    if depth == 0 { return index + 1 }
                }
                index += 1
            }
            throw invalidDocument()
        }
        var index = start
        while index < bytes.count && !isWhitespace(bytes[index]) && bytes[index] != 0x2C && bytes[index] != 0x7D {
            index += 1
        }
        return index
    }

    private static func stringEnd(_ bytes: [UInt8], start: Int) throws -> Int {
        guard start < bytes.count, bytes[start] == 0x22 else { throw invalidDocument() }
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == 0x22 { return index + 1 }
            index += bytes[index] == 0x5C ? 2 : 1
        }
        throw invalidDocument()
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func invalidDocument() -> AgentCLIError {
        .invalidInput("OpenCode config must be a valid JSON or JSONC object with unique root keys.")
    }
}

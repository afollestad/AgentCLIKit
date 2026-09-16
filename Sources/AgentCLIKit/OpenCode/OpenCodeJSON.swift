import Foundation

/// Keeps native JSON traversal local to the OpenCode wire format.
extension JSONValue {
    var ocObject: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var ocArray: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var ocString: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var ocInt: Int? {
        guard case let .number(value) = self, value.isFinite,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }

    var ocBool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    subscript(oc key: String) -> JSONValue? { ocObject?[key] }
}

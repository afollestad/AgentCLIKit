extension JSONValue {
    var threadResponseId: String? {
        guard case let .object(response) = self,
              case let .object(thread)? = response["thread"],
              case let .string(threadId)? = thread["id"],
              !threadId.isEmpty else {
            return nil
        }
        return threadId
    }

    var threadResponseName: String? {
        guard case let .object(response) = self,
              case let .object(thread)? = response["thread"],
              case let .string(name)? = thread["name"],
              !name.isEmpty else {
            return nil
        }
        return name
    }

    var threadResponsePreview: String? {
        guard case let .object(response) = self,
              case let .object(thread)? = response["thread"],
              case let .string(preview)? = thread["preview"],
              !preview.isEmpty else {
            return nil
        }
        return preview
    }

    var threadResponseForkedFromId: String? {
        guard case let .object(response) = self,
              case let .object(thread)? = response["thread"],
              case let .string(forkedFromId)? = thread["forkedFromId"],
              !forkedFromId.isEmpty else {
            return nil
        }
        return forkedFromId
    }

    var turnResponseId: String? {
        guard case let .object(response) = self,
              case let .object(turn)? = response["turn"],
              case let .string(turnId)? = turn["id"],
              !turnId.isEmpty else {
            return nil
        }
        return turnId
    }

    func stringValue(_ key: String) -> String? {
        guard case let .object(object) = self,
              case let .string(value)? = object[key],
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension CodexAppServerNotification {
    var threadId: String? {
        params?.threadId
    }

    var startedTurnId: String? {
        guard method == "turn/started" else {
            return nil
        }
        return params?.turnId
    }

    var completedTurnId: String? {
        guard method == "turn/completed" else {
            return nil
        }
        return params?.turnId
    }

    var marksThreadIdle: Bool {
        guard method == "thread/status/changed",
              let statusType = params?.threadStatusType else {
            return false
        }
        return statusType == "idle" || statusType == "notLoaded" || statusType == "systemError"
    }

    var marksThreadActive: Bool {
        guard method == "thread/status/changed",
              let statusType = params?.threadStatusType else {
            return false
        }
        return statusType == "active"
    }
}

extension CodexAppServerRequest {
    var threadId: String? {
        params?.threadId
    }
}

extension CodexAppServerError {
    var isNoActiveTurnInterrupt: Bool {
        guard case let .jsonRPCError(method, _, message) = self else {
            return false
        }
        return method == "turn/interrupt" && message.localizedCaseInsensitiveContains("no active turn")
    }
}

extension JSONValue {
    var threadId: String? {
        guard case let .object(params) = self,
              let threadId = params.topLevelThreadId ?? params.nestedThreadId else {
            return nil
        }
        return threadId
    }

    var turnId: String? {
        guard case let .object(params) = self,
              case let .object(turn)? = params["turn"],
              case let .string(turnId)? = turn["id"],
              !turnId.isEmpty else {
            return nil
        }
        return turnId
    }

    var threadStatusType: String? {
        guard case let .object(params) = self,
              let status = params["status"] else {
            return nil
        }
        if case let .object(statusObject) = status,
           case let .string(type)? = statusObject["type"],
           !type.isEmpty {
            return type
        }
        if case let .string(type) = status, !type.isEmpty {
            return type
        }
        return nil
    }
}

private extension [String: JSONValue] {
    var topLevelThreadId: String? {
        stringValue("threadId", "thread_id")
    }

    var nestedThreadId: String? {
        guard case let .object(thread)? = self["thread"],
              case let .string(threadId)? = thread["id"],
              !threadId.isEmpty else {
            return nil
        }
        return threadId
    }

    func stringValue(_ keys: String...) -> String? {
        keys.lazy.compactMap { key -> String? in
            guard case let .string(value)? = self[key], !value.isEmpty else {
                return nil
            }
            return value
        }.first
    }
}

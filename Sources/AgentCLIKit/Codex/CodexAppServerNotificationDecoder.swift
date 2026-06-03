import Foundation

struct CodexAppServerNotificationDecoder {
    func decode(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        switch notification.method {
        case "thread/status/changed":
            decodeThreadStatusChanged(notification)
        case "turn/started":
            decodeTurnStarted(notification)
        case "turn/completed":
            decodeTurnCompleted(notification)
        case "thread/settings/updated":
            decodeThreadSettingsUpdated(notification)
        default:
            []
        }
    }

    private func decodeThreadStatusChanged(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let status = params["status"],
              let statusType = status.codexObjectValue?["type"]?.codexStringValue ?? status.codexStringValue else {
            return []
        }
        let metadata = metadata(
            method: notification.method,
            threadId: threadId,
            values: ["codex_status": .string(statusType)]
        )
        switch statusType {
        case "active":
            return [runtimeEvent(.activity(AgentActivityEvent(state: .active, metadata: metadata)))]
        case "idle", "notLoaded":
            return [runtimeEvent(.activity(AgentActivityEvent(state: .idle, metadata: metadata)))]
        case "systemError":
            return [
                runtimeEvent(.activity(AgentActivityEvent(state: .idle, metadata: metadata))),
                runtimeEvent(.diagnostic(AgentDiagnosticEvent(
                    code: .codexAppServerResponseFailure,
                    severity: .warning,
                    message: "Codex App Server reported a thread system error.",
                    metadata: metadata
                )))
            ]
        default:
            return []
        }
    }

    private func decodeTurnStarted(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turn = params["turn"]?.codexObjectValue,
              let turnId = turn["id"]?.codexStringValue else {
            return []
        }
        let status = turn["status"]?.codexStringValue
        return [
            runtimeEvent(.activity(AgentActivityEvent(
                state: .active,
                turnId: turnId,
                metadata: metadata(
                    method: notification.method,
                    threadId: threadId,
                    turnId: turnId,
                    values: ["codex_turn_status": status.map(JSONValue.string)]
                )
            )))
        ]
    }

    private func decodeTurnCompleted(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turn = params["turn"]?.codexObjectValue,
              let turnId = turn["id"]?.codexStringValue else {
            return []
        }
        let status = turn["status"]?.codexStringValue
        let metadata = metadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            values: [
                "codex_turn_status": status.map(JSONValue.string),
                "duration_ms": turn["durationMs"]
            ]
        )
        var events = [
            runtimeEvent(.activity(AgentActivityEvent(state: .idle, turnId: turnId, metadata: metadata)))
        ]
        if status == "failed" {
            events.append(runtimeEvent(.diagnostic(AgentDiagnosticEvent(
                code: .codexAppServerResponseFailure,
                severity: .error,
                message: turn.errorMessage ?? "Codex turn failed.",
                metadata: metadata.merging(["codex_turn_error": turn["error"] ?? .null]) { _, new in new }
            ))))
        }
        return events
    }

    private func decodeThreadSettingsUpdated(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let settings = params["threadSettings"]?.codexObjectValue else {
            return []
        }
        var events: [AgentProviderRuntimeEvent] = []
        let metadata = metadata(
            method: notification.method,
            threadId: threadId,
            values: [
                "codex_model": settings["model"],
                "codex_model_provider": settings["modelProvider"],
                "codex_effort": settings["effort"],
                "codex_approval_policy": settings["approvalPolicy"]
            ]
        )
        if let approvalPolicy = settings["approvalPolicy"]?.codexStringValue {
            events.append(runtimeEvent(.permissionMode(AgentPermissionModeEvent(mode: approvalPolicy, metadata: metadata))))
        }
        events.append(runtimeEvent(.diagnostic(AgentDiagnosticEvent(
            severity: .info,
            message: "Codex thread settings updated.",
            metadata: metadata
        ))))
        return events
    }

    private func runtimeEvent(_ event: AgentEvent) -> AgentProviderRuntimeEvent {
        AgentProviderRuntimeEvent(event: event, source: .runtime)
    }

    private func metadata(
        method: String,
        threadId: String,
        turnId: String? = nil,
        values: [String: JSONValue?] = [:]
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "codex_method": .string(method),
            "codex_thread_id": .string(threadId)
        ]
        if let turnId {
            metadata["codex_turn_id"] = .string(turnId)
        }
        for (key, value) in values {
            if let value {
                metadata[key] = value
            }
        }
        return metadata
    }
}

private extension [String: JSONValue] {
    var errorMessage: String? {
        guard let error = self["error"]?.codexObjectValue else {
            return nil
        }
        return error["message"]?.codexStringValue
    }
}

private extension JSONValue {
    var codexObjectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var codexStringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}

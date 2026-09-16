import Foundation

/// Owns generations independently: no session can observe another generation's host-tool credentials.
actor OpenCodeClient {
    let configuration: OpenCodeHarnessAdapter.Configuration
    var generations: [UUID: OpenCodeGeneration] = [:]
    var cancelledTokens: Set<UUID> = []
    var actionTransports: [UUID: any OpenCodeServerTransport] = [:]
    var isShutdown = false
    var lastMessageTimestamp: UInt64 = 0

    init(configuration: OpenCodeHarnessAdapter.Configuration) { self.configuration = configuration }

    static func validate(_ config: AgentSpawnConfig) throws {
        guard config.harnessId == .opencode else { throw AgentCLIError.invalidInput("Expected the OpenCode harness.") }
        try config.validateAdditionalWorkspaceRoots()
        if config.initialGoal != nil { throw unsupported("native goals") }
        if config.speedMode == .fast { throw unsupported("Fast mode") }
        if !config.arguments.isEmpty { throw unsupported("custom CLI arguments") }
        if let mode = config.permissionMode, !["configured", "ask", "fullAccess"].contains(mode) {
            throw AgentCLIError.invalidInput("Unknown OpenCode permission mode: \(mode)")
        }
    }

    static func unsupported(_ capability: String) -> AgentCLIError {
        .unsupportedCapability(harnessId: .opencode, capability: capability)
    }

    func bootstrap(_ context: AgentHarnessLaunchContext, endpoint: AgentHostToolEndpoint?) async throws -> OpenCodeBootstrap {
        try Self.validate(context.spawnConfig)
        try checkLive(context.processToken)
        let serverConfiguration = try await serverConfiguration(config: context.spawnConfig, endpoint: endpoint)
        try checkLive(context.processToken)
        let state = OpenCodeGeneration(
            context: context, transport: configuration.makeTransport(serverConfiguration),
            sensitiveValues: endpoint.map { [$0.bearerToken, $0.url.absoluteString] } ?? []
        )
        generations[context.processToken] = state
        do {
            try await state.transport.start()
            try checkLive(context.processToken)
            let health = try await state.transport.request(method: "GET", path: "/global/health", body: nil)
            try checkLive(context.processToken)
            try OpenCodeVersionSupport.validate(health[oc: "version"]?.ocString ?? "unknown")
            state.providers = try await state.transport.request(method: "GET", path: "/provider", body: nil)
            try checkLive(context.processToken)
            let session = try await openSession(context, state: state)
            try checkLive(context.processToken)
            guard let id = session[oc: "id"]?.ocString else {
                throw OpenCodeTransportError.invalidResponse("Session has no ID.")
            }
            try Self.validateID(id)
            state.sessionID = id
            state.translator = OpenCodeEventTranslator(rootSessionID: id, contextWindow: selectedModel(state)?[oc: "limit"]?[oc: "context"]?.ocInt)
            for sessionID in try await discoverSessions(state) {
                let history = try await state.transport.request(method: "GET", path: "/session/\(sessionID)/message", body: nil)
                state.translator.seed(messages: history.ocArray ?? [])
            }
            // A restored process never restarts the interrupted native loop on its own.
            let stream = try await state.transport.events()
            try checkLive(context.processToken)
            state.eventTask = Task { await self.consume(stream, processToken: context.processToken) }
            emit(.sessionMetadata(AgentSessionMetadataEvent(
                harnessSessionId: AgentSessionID(rawValue: id), name: OpenCodeSessionTitle.meaningful(session[oc: "title"]?.ocString),
                metadata: ["provider_session_id": .string(id), "opencode_session_id": .string(id)]
            )), state: state)
            try await reconcile(state, includeHistory: false)
            return OpenCodeBootstrap(sessionID: id, continuity: state.continuity)
        } catch {
            await stop(processToken: context.processToken)
            throw error
        }
    }

    func openSession(_ context: AgentHarnessLaunchContext, state: OpenCodeGeneration) async throws -> JSONValue {
        try checkLive(context.processToken)
        let config = context.spawnConfig
        let forkID = config.sessionFork?.sourceSessionId ?? (config.forkSession ? context.resumedSession?.harnessSessionId : nil)
        let session: JSONValue
        if let forkID {
            try Self.validateID(forkID.rawValue)
            state.continuity = .forked
            session = try await state.transport.request(method: "POST", path: "/session/\(forkID.rawValue)/fork", body: .object([:]))
            try checkLive(context.processToken)
            guard let id = session[oc: "id"]?.ocString else {
                throw OpenCodeTransportError.invalidResponse("Fork has no native session ID.")
            }
            let destination = AgentPathHelpers.canonicalFileURL(config.workingDirectory).path
            if session[oc: "directory"]?.ocString != destination {
                // V1 session routes select the source directory. Move only the newly forked session;
                // the native control plane preserves its messages and never copies workspace changes.
                _ = try await state.transport.request(method: "POST", path: "/experimental/control-plane/move-session", body: .object([
                    "sessionID": .string(id), "destination": .object(["directory": .string(destination)]), "moveChanges": .bool(false)
                ]))
                let moved = try await state.transport.request(method: "GET", path: "/session/\(id)", body: nil)
                guard moved[oc: "directory"]?.ocString == destination else {
                    throw OpenCodeTransportError.invalidResponse("Native fork did not move into the requested workspace.")
                }
            }
        } else if let resumed = context.resumedSession {
            guard resumed.harnessId == .opencode else { throw AgentCLIError.invalidInput("Cannot resume another harness's session.") }
            try Self.validateID(resumed.harnessSessionId.rawValue)
            state.continuity = .resumed
            session = try await state.transport.request(method: "GET", path: "/session/\(resumed.harnessSessionId.rawValue)", body: nil)
        } else {
            var body: [String: JSONValue] = [:]
            if let permission = Self.permissionRules(config.permissionMode) { body["permission"] = permission }
            session = try await state.transport.request(method: "POST", path: "/session", body: .object(body))
        }
        try checkLive(context.processToken)
        if state.continuity != .fresh, let id = session[oc: "id"]?.ocString,
           let permission = Self.permissionRules(config.permissionMode) {
            _ = try await state.transport.request(method: "PATCH", path: "/session/\(id)", body: .object(["permission": permission]))
        }
        return session
    }

    func events(processToken: UUID) -> AsyncStream<AgentHarnessRuntimeEvent> {
        generations[processToken]?.stream ?? AsyncStream { $0.finish() }
    }

    func emit(_ event: AgentEvent, state: OpenCodeGeneration) {
        guard generations[state.context.processToken] === state else { return }
        var safeEvent = event
        if !state.sensitiveValues.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            if let bytes = try? encoder.encode(event), let text = String(data: bytes, encoding: .utf8) {
                let redacted = AgentSensitiveValueRedactor.redact(text, sensitiveValues: state.sensitiveValues)
                if redacted != text, let decoded = try? JSONDecoder().decode(AgentEvent.self, from: Data(redacted.utf8)) {
                    safeEvent = decoded
                }
            }
        }
        state.continuation.yield(AgentHarnessRuntimeEvent(event: safeEvent))
    }

    func checkLive(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !isShutdown, !cancelledTokens.contains(token) else { throw CancellationError() }
    }

    func requireState(_ token: UUID) throws -> OpenCodeGeneration {
        try checkLive(token)
        guard let state = generations[token], !state.sessionID.isEmpty, !state.failed else {
            throw OpenCodeTransportError.unavailable("The session must be resumed before sending more input.")
        }
        return state
    }

    func stop(processToken: UUID) async {
        cancelledTokens.insert(processToken)
        guard let state = generations.removeValue(forKey: processToken) else { return }
        state.eventTask?.cancel()
        state.continuation.finish()
        await state.transport.stop()
    }

    func shutdown() async {
        isShutdown = true
        let actions = Array(actionTransports.values)
        actionTransports.removeAll()
        for transport in actions { await transport.stop() }
        for token in Array(generations.keys) { await stop(processToken: token) }
    }

    static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 256,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }) else {
            throw AgentCLIError.invalidInput("Invalid OpenCode identifier.")
        }
    }

    static func permissionRules(_ mode: String?) -> JSONValue? {
        switch mode ?? OpenCodeHarnessDefinition.defaultPermissionMode {
        case "configured": return .array([])
        case "fullAccess": return .array([.object(["permission": .string("*"), "pattern": .string("*"), "action": .string("allow")])])
        default: return .array([.object(["permission": .string("*"), "pattern": .string("*"), "action": .string("ask")])])
        }
    }
}

struct OpenCodeBootstrap: Sendable {
    let sessionID: String
    let continuity: AgentSessionContinuity
}

/// Mutated only by OpenCodeClient; references remain private to that actor across awaits.
final class OpenCodeGeneration {
    let context: AgentHarnessLaunchContext
    let transport: any OpenCodeServerTransport
    let sensitiveValues: [String]
    let stream: AsyncStream<AgentHarnessRuntimeEvent>
    let continuation: AsyncStream<AgentHarnessRuntimeEvent>.Continuation
    var sessionID = ""
    var continuity: AgentSessionContinuity = .fresh
    var translator = OpenCodeEventTranslator(rootSessionID: "")
    var providers: JSONValue = .null
    var eventTask: Task<Void, Never>?
    var failed = false
    var active = false
    var nativeStatus: String?
    var currentMessageID: String?
    var pendingMessageIDs: Set<String> = []
    var steering: [String: AgentMessageInput] = [:]
    var lastFinishedParentID: String?
    var lastCompletionError: String?

    var collaborationMode: AgentCollaborationMode
    var compacting = false
    var priorManualCompactionID: String?
    var interrupted = false
    var pendingInteractions: [String: OpenCodePendingInteraction] = [:]
    var resolvedInteractions: Set<String> = []

    init(context: AgentHarnessLaunchContext, transport: any OpenCodeServerTransport, sensitiveValues: [String] = []) {
        self.context = context
        self.collaborationMode = context.spawnConfig.collaborationMode ?? .default
        self.transport = transport
        self.sensitiveValues = sensitiveValues
        (stream, continuation) = AsyncStream.makeStream()
    }
}

struct OpenCodePendingInteraction: Sendable {
    let kind: String
    let payload: JSONValue
}

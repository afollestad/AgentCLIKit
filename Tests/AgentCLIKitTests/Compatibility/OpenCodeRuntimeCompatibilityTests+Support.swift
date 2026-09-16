import XCTest

@testable import AgentCLIKit

/// Models server outcomes, including a lost response after acceptance, without retrying mutations in the fake.
actor OpenCodeCompatibilityTransport: OpenCodeServerTransport {
    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        let body: JSONValue?
    }

    enum PromptBehavior: Equatable, Sendable { case accepted, acceptedWithoutResponse, unknownAcceptance }
    private(set) var requests: [Request] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var eventStreamCount = 0
    private var continuations: [AsyncThrowingStream<JSONValue, Error>.Continuation] = []
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var suspendedPaths: Set<String> = []
    private var requestContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var requestResponses: [String: JSONValue] = [:]
    private let suspendStart: Bool
    private let promptBehavior: PromptBehavior
    private let losePermissionReplyResponse: Bool
    private let emitPermissionReplyEvent: Bool
    private var directory: String
    private var history: [JSONValue] = []
    private var messageReadFailures = 0
    private var requestFailures: [String: (error: OpenCodeTransportError, remaining: Int)] = [:]
    private var statuses: JSONValue = .object([:])
    private var crashed = false
    private var nativeModel: JSONValue?
    private var configuredModel: String? = "alpha/family/model"
    private var permissions: [JSONValue]
    private var questions: [JSONValue]

    init(
        directory: String = OpenCodeCompatibilityFixture.directory.path,
        promptBehavior: PromptBehavior = .accepted,
        suspendStart: Bool = false,
        losePermissionReplyResponse: Bool = false,
        emitPermissionReplyEvent: Bool = true,
        permissions: [JSONValue] = [],
        questions: [JSONValue] = []
    ) {
        self.directory = directory
        self.promptBehavior = promptBehavior
        self.suspendStart = suspendStart
        self.losePermissionReplyResponse = losePermissionReplyResponse
        self.emitPermissionReplyEvent = emitPermissionReplyEvent
        self.permissions = permissions
        self.questions = questions
    }

    func start() async throws {
        startCount += 1
        if suspendStart { await withCheckedContinuation { startContinuation = $0 } }
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func suspendNextRequest(path: String) { suspendedPaths.insert(path) }

    func releaseRequest(path: String) { requestContinuations.removeValue(forKey: path)?.resume() }

    func respondToNextRequest(path: String, response: JSONValue) { requestResponses[path] = response }

    func request(method: String, path: String, body: JSONValue?) async throws -> JSONValue {
        requests.append(Request(method: method, path: path, body: body))
        try checkAvailable(path: path)
        let response = requestResponses.removeValue(forKey: path)
        if suspendedPaths.remove(path) != nil { await withCheckedContinuation { requestContinuations[path] = $0 } }
        if let response { return response }
        return try routeRequest(method: method, path: path, body: body)
    }

    private func routeRequest(method: String, path: String, body: JSONValue?) throws -> JSONValue {
        switch path {
        case "/global/health": return .object(["healthy": .bool(true), "version": .string("1.18.31")])
        case "/provider": return openCodeProviderFixture()
        case "/permission": return .array(permissions)
        case "/question": return .array(questions)
        case "/session/status": return statuses
        case "/config": return .object(configuredModel.map { ["model": .string($0)] } ?? [:])
        case "/session": return session("ses_current")
        case "/experimental/control-plane/move-session":
            directory = body?[oc: "destination"]?[oc: "directory"]?.ocString ?? directory
            return .bool(true)
        default: return try requestSession(method: method, path: path, body: body)
        }
    }

    private func checkAvailable(path: String) throws {
        if crashed { throw OpenCodeTransportError.unavailable("Server crashed") }
        if let failure = requestFailures[path] {
            requestFailures[path] = failure.remaining > 1 ? (failure.error, failure.remaining - 1) : nil
            throw failure.error
        }
    }

    private func requestSession(method: String, path: String, body: JSONValue?) throws -> JSONValue {
        if path.hasSuffix("/fork") { return session("ses_fork") }
        if path.hasSuffix("/children") { return .array([]) }
        if path.hasSuffix("/message") {
            if messageReadFailures > 0 {
                messageReadFailures -= 1
                throw OpenCodeTransportError.unavailable("Temporary history failure")
            }
            return .array(history)
        }
        if path.hasSuffix("/prompt_async") { return try submitPrompt(body) }
        if path.hasPrefix("/permission/") { return try replyToPermission(path) }
        if path.hasPrefix("/question/") {
            questions.removeAll { path.contains($0[oc: "id"]?.ocString ?? "missing") }
            return .bool(true)
        }
        if path.hasPrefix("/session/") { return session(path.split(separator: "/").last.map(String.init) ?? "missing") }
        throw OpenCodeTransportError.invalidResponse("Unexpected test route: \(method) \(path)")
    }

    private func submitPrompt(_ body: JSONValue?) throws -> JSONValue {
        if promptBehavior == .acceptedWithoutResponse {
            history.append(.object([
                "info": .object([
                    "id": body?[oc: "messageID"] ?? .string("missing"), "role": .string("user"),
                    "sessionID": .string("ses_current")
                ]), "parts": body?[oc: "parts"] ?? .array([])
            ]))
        }
        if promptBehavior != .accepted { throw OpenCodeTransportError.unavailable("Response lost") }
        return .null
    }

    private func replyToPermission(_ path: String) throws -> JSONValue {
        let permission = permissions.first { path.contains($0[oc: "id"]?.ocString ?? "missing") }
        permissions.removeAll { path.contains($0[oc: "id"]?.ocString ?? "missing") }
        if losePermissionReplyResponse {
            if emitPermissionReplyEvent {
                continuations.last?.yield(.object([
                    "type": .string("permission.replied"), "properties": .object([
                        "requestID": permission?[oc: "id"] ?? .null, "sessionID": permission?[oc: "sessionID"] ?? .null
                    ])
                ]))
            }
            throw OpenCodeTransportError.unavailable("Permission reply response lost")
        }
        return .bool(true)
    }

    func failNextRequest(path: String, error: OpenCodeTransportError, count: Int = 1) { requestFailures[path] = (error, count) }

    func setRecovery(history: [JSONValue], statuses: JSONValue = .object([:]), failures: Int = 0) {
        self.history = history
        self.statuses = statuses
        messageReadFailures = failures
    }

    func events() async throws -> AsyncThrowingStream<JSONValue, Error> {
        eventStreamCount += 1
        if crashed { throw OpenCodeTransportError.unavailable("Server crashed") }
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        continuations.append(continuation)
        return stream
    }

    func setModels(native: JSONValue?, configured: String?) {
        nativeModel = native
        configuredModel = configured
    }

    func crash() {
        crashed = true
        disconnect()
    }

    func recover() { crashed = false }

    func emit(_ value: JSONValue) { continuations.last?.yield(value) }
    func askPermission(_ payload: JSONValue) {
        permissions.append(payload)
        emit(.object(["type": .string("permission.asked"), "properties": payload]))
    }
    func disconnect() { continuations.last?.finish(throwing: OpenCodeTransportError.unavailable("SSE disconnected")) }
    func stop() async {
        stopCount += 1
        for continuation in continuations { continuation.finish() }
    }

    private func session(_ id: String) -> JSONValue {
        var info: [String: JSONValue] = ["id": .string(id), "directory": .string(directory), "title": .string("Native session")]
        info["model"] = nativeModel
        return .object(info)
    }
}

struct OpenCodeCompatibilityFixture {
    static let directory = URL(fileURLWithPath: "/tmp/opencode-project").resolvingSymlinksInPath()
    let transport: OpenCodeCompatibilityTransport
    let adapter: OpenCodeHarnessAdapter
    let context: AgentHarnessLaunchContext

    init(
        transport: OpenCodeCompatibilityTransport = OpenCodeCompatibilityTransport(),
        config: AgentSpawnConfig? = nil,
        resumed: AgentSessionRecord? = nil,
        token: UUID = UUID()
    ) {
        self.transport = transport
        adapter = OpenCodeHarnessAdapter(configuration: .init(executablePath: "/test/opencode", makeTransport: { _ in transport }))
        context = AgentHarnessLaunchContext(
            conversationId: "conversation", processToken: token,
            spawnConfig: config ?? AgentSpawnConfig(harnessId: .opencode, workingDirectory: Self.directory), resumedSession: resumed
        )
    }

    func launch() async throws -> AgentLaunchConfiguration { try await adapter.makeLaunchConfiguration(context: context) }
    func send(_ input: AgentInput) async throws {
        _ = try await adapter.encodeInput(input, context: AgentHarnessInputContext(
            conversationId: context.conversationId, processToken: context.processToken, harnessSessionId: "ses_current",
            spawnConfig: context.spawnConfig, isTurnActive: true
        ))
    }
    func stream() async -> AsyncStream<AgentHarnessRuntimeEvent> {
        await adapter.runtimeEvents(context: AgentHarnessRuntimeContext(
            conversationId: context.conversationId, processToken: context.processToken, harnessSessionId: "ses_current",
            spawnConfig: context.spawnConfig
        ))
    }
    func stop() async { await adapter.shutdownHarnessResources() }

    static func record(id: AgentSessionID = "ses_current", superseded: [String] = []) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation", harnessId: .opencode, harnessSessionId: id, workingDirectory: directory, generation: 1,
            metadata: [AgentSessionRecord.supersededHarnessSessionIdsMetadataKey: .array(superseded.map(JSONValue.string))]
        )
    }
}

actor OpenCodeCompatibilityEvents {
    private(set) var values: [AgentEvent] = []
    func append(_ event: AgentEvent) { values.append(event) }
    func consume(_ stream: AsyncStream<AgentHarnessRuntimeEvent>) async {
        for await item in stream { values.append(item.event) }
    }
}

func openCodeWaitUntil(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return false
}

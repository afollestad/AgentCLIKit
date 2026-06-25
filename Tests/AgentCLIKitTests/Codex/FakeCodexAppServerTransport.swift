import Foundation

@testable import AgentCLIKit

actor FakeCodexAppServerTransport: CodexAppServerTransport {
    struct Request: Sendable {
        let method: String
        let params: JSONValue?
    }

    struct Response: Sendable {
        let id: JSONValue
        let result: JSONValue?
    }

    struct ErrorResponse: Sendable {
        let id: JSONValue
        let code: Int
        let message: String
        let data: JSONValue?
    }

    private var threadIds: [String]
    private var threadNames: [String?]
    private var threadPreviews: [String?]
    private var threadForkedFromIds: [String?]
    private var modelListResponses: [JSONValue]
    private var configRequirementsResponse: JSONValue
    private var goal: [String: JSONValue]?
    private let failModelListRequests: Bool
    private let failModelListRequestsAfterSuccessCount: Int?
    private let failingMethods: Set<String>
    private var turnIndex = 0
    private var successfulModelListRequestCount = 0
    private var incomingContinuations: [UUID: AsyncStream<CodexAppServerIncomingMessage>.Continuation] = [:]
    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private(set) var requestMethods: [String] = []
    private(set) var notificationMethods: [String] = []
    private(set) var requestParams: [String: JSONValue] = [:]
    private(set) var requestLog: [Request] = []
    private(set) var responseLog: [Response] = []
    private(set) var errorResponseLog: [ErrorResponse] = []
    private(set) var incomingStreamCount = 0

    init(
        threadIds: [String],
        threadNames: [String?] = [],
        threadPreviews: [String?] = [],
        threadForkedFromIds: [String?] = [],
        modelListResponses: [JSONValue] = [],
        configRequirementsResponse: JSONValue = .object(["requirements": .null]),
        goal: [String: JSONValue]? = nil,
        failModelListRequests: Bool = false,
        failModelListRequestsAfterSuccessCount: Int? = nil,
        failingMethods: Set<String> = []
    ) {
        self.threadIds = threadIds
        self.threadNames = threadNames
        self.threadPreviews = threadPreviews
        self.threadForkedFromIds = threadForkedFromIds
        self.modelListResponses = modelListResponses
        self.configRequirementsResponse = configRequirementsResponse
        self.goal = goal
        self.failModelListRequests = failModelListRequests
        self.failModelListRequestsAfterSuccessCount = failModelListRequestsAfterSuccessCount
        self.failingMethods = failingMethods
    }

    func start() async throws {
        startCount += 1
    }

    nonisolated func incomingMessages() -> AsyncStream<CodexAppServerIncomingMessage> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.addIncomingContinuation(continuation, id: id)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeIncomingContinuation(id: id)
                }
            }
        }
    }

    func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        requestMethods.append(method)
        requestParams[method] = params
        requestLog.append(Request(method: method, params: params))
        try failIfNeeded(method)
        switch method {
        case "initialize":
            return .object(["server": .string("fake")])
        case "thread/start", "thread/resume", "thread/fork":
            return nextThreadResponse()
        case "turn/start":
            turnIndex += 1
            return .object([
                "turn": .object([
                    "id": .string("turn-\(turnIndex)"),
                    "status": .string("inProgress"),
                    "items": .array([])
                ])
            ])
        case "turn/steer":
            return .object(["turnId": .string("turn-\(turnIndex)")])
        case "turn/interrupt":
            return .object([:])
        case "configRequirements/read":
            return configRequirementsResponse
        case "thread/archive", "thread/unarchive", "thread/delete":
            return .object([:])
        case "thread/goal/set":
            return setGoal(params: params)
        case "thread/goal/get":
            return .object(["goal": goal.map(JSONValue.object) ?? .null])
        case "thread/goal/clear":
            let cleared = goal != nil
            goal = nil
            return .object(["cleared": .bool(cleared)])
        case "model/list":
            if failModelListRequests || shouldFailModelListRequestAfterSuccesses() {
                throw CodexAppServerError.jsonRPCError(method: method, code: -32000, message: "Model list failed.")
            }
            successfulModelListRequestCount += 1
            guard !modelListResponses.isEmpty else {
                return .object(["data": .array([])])
            }
            return modelListResponses.removeFirst()
        default:
            return .null
        }
    }

    private func setGoal(params: JSONValue?) -> JSONValue {
        var nextGoal = goal ?? [:]
        if case let .object(object)? = params {
            if case let .string(threadId)? = object["threadId"] {
                nextGoal["threadId"] = .string(threadId)
            }
            if case let .string(objective)? = object["objective"] {
                nextGoal["objective"] = .string(objective)
            }
            if case let .string(status)? = object["status"] {
                nextGoal["status"] = .string(status)
            } else if nextGoal["status"] == nil {
                nextGoal["status"] = .string("active")
            }
        }
        if nextGoal["objective"] == nil {
            nextGoal["objective"] = .string("Existing goal")
        }
        goal = nextGoal
        return .object(["goal": .object(nextGoal)])
    }

    private func nextThreadResponse() -> JSONValue {
        var thread: [String: JSONValue] = [
            "id": .string(threadIds.removeFirst())
        ]
        if !threadNames.isEmpty, let name = threadNames.removeFirst() {
            thread["name"] = .string(name)
        }
        if !threadPreviews.isEmpty, let preview = threadPreviews.removeFirst() {
            thread["preview"] = .string(preview)
        }
        if !threadForkedFromIds.isEmpty, let forkedFromId = threadForkedFromIds.removeFirst() {
            thread["forkedFromId"] = .string(forkedFromId)
        }
        return .object([
            "thread": .object(thread)
        ])
    }

    func sendNotification(method: String, params: JSONValue?) async throws {
        notificationMethods.append(method)
    }

    private func failIfNeeded(_ method: String) throws {
        if failingMethods.contains(method) {
            throw CodexAppServerError.jsonRPCError(method: method, code: -32000, message: "\(method) failed.")
        }
    }

    private func shouldFailModelListRequestAfterSuccesses() -> Bool {
        guard let failModelListRequestsAfterSuccessCount else {
            return false
        }
        return successfulModelListRequestCount >= failModelListRequestsAfterSuccessCount
    }

    func sendResponse(id: JSONValue, result: JSONValue?) async throws {
        responseLog.append(Response(id: id, result: result))
    }

    func sendErrorResponse(id: JSONValue, code: Int, message: String, data: JSONValue?) async throws {
        errorResponseLog.append(ErrorResponse(id: id, code: code, message: message, data: data))
    }

    func shutdown() async {
        shutdownCount += 1
    }

    func emitNotification(method: String, params: JSONValue?) {
        incomingContinuations.values.forEach {
            $0.yield(.notification(CodexAppServerNotification(method: method, params: params)))
        }
    }

    func emitRequest(id: JSONValue, method: String, params: JSONValue?) {
        incomingContinuations.values.forEach {
            $0.yield(.request(CodexAppServerRequest(id: id, method: method, params: params)))
        }
    }

    private func addIncomingContinuation(
        _ continuation: AsyncStream<CodexAppServerIncomingMessage>.Continuation,
        id: UUID
    ) {
        incomingStreamCount += 1
        incomingContinuations[id] = continuation
    }

    private func removeIncomingContinuation(id: UUID) {
        incomingContinuations[id] = nil
    }

    func finishIncomingMessages() {
        incomingContinuations.values.forEach { $0.finish() }
        incomingContinuations.removeAll()
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }
}

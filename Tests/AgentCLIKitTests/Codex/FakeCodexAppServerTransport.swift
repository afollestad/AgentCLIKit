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
    private var modelListResponses: [JSONValue]
    private let failModelListRequests: Bool
    private var turnIndex = 0
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

    init(threadIds: [String], modelListResponses: [JSONValue] = [], failModelListRequests: Bool = false) {
        self.threadIds = threadIds
        self.modelListResponses = modelListResponses
        self.failModelListRequests = failModelListRequests
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
        switch method {
        case "initialize":
            return .object(["server": .string("fake")])
        case "thread/start", "thread/resume":
            return .object([
                "thread": .object([
                    "id": .string(threadIds.removeFirst())
                ])
            ])
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
        case "model/list":
            if failModelListRequests {
                throw CodexAppServerError.jsonRPCError(method: method, code: -32000, message: "Model list failed.")
            }
            guard !modelListResponses.isEmpty else {
                return .object(["data": .array([])])
            }
            return modelListResponses.removeFirst()
        default:
            return .null
        }
    }

    func sendNotification(method: String, params: JSONValue?) async throws {
        notificationMethods.append(method)
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

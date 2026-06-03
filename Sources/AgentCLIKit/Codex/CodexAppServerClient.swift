import Foundation

struct CodexThreadBootstrap: Sendable {
    let threadId: AgentSessionID
    let continuity: AgentSessionContinuity
}

actor CodexAppServerClient {
    private let configuration: CodexProviderAdapter.Configuration
    private var transport: (any CodexAppServerTransport)?
    private var isInitialized = false

    init(configuration: CodexProviderAdapter.Configuration) {
        self.configuration = configuration
    }

    func bootstrapThread(spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?) async throws -> CodexThreadBootstrap {
        let transport = try await initializedTransport()
        let method = resumedSession == nil ? "thread/start" : "thread/resume"
        let response = try await transport.sendRequest(
            method: method,
            params: threadParams(spawnConfig: spawnConfig, resumedSession: resumedSession)
        )
        guard let threadId = response.threadId else {
            throw CodexAppServerError.missingThreadID(method: method)
        }
        return CodexThreadBootstrap(
            threadId: AgentSessionID(rawValue: threadId),
            continuity: resumedSession == nil ? .fresh : .resumed
        )
    }

    func shutdown() async {
        await transport?.shutdown()
        transport = nil
        isInitialized = false
    }

    private func initializedTransport() async throws -> any CodexAppServerTransport {
        let transport = try await transport()
        guard !isInitialized else {
            return transport
        }
        _ = try await transport.sendRequest(method: "initialize", params: initializeParams())
        try await transport.sendNotification(method: "initialized", params: nil)
        isInitialized = true
        return transport
    }

    private func transport() async throws -> any CodexAppServerTransport {
        if let transport {
            return transport
        }
        let transport = configuration.makeTransport(configuration)
        try await transport.start()
        self.transport = transport
        return transport
    }

    private func initializeParams() -> JSONValue {
        .object([
            "clientInfo": .object([
                "name": .string("AgentCLIKit"),
                "title": .string("AgentCLIKit"),
                "version": .string("0")
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(configuration.experimentalAPIEnabled),
                "requestAttestation": .bool(false)
            ])
        ])
    }

    private func threadParams(spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(spawnConfig.workingDirectory.path)
        ]
        if let resumedSession {
            params["threadId"] = .string(resumedSession.providerSessionId.rawValue)
        } else {
            params["ephemeral"] = .bool(false)
        }
        if let model = spawnConfig.model {
            params["model"] = .string(model)
        }
        if let permissionMode = spawnConfig.permissionMode {
            params["approvalPolicy"] = .string(permissionMode)
        }
        if let effort = spawnConfig.effort {
            params["config"] = .object(["model_reasoning_effort": .string(effort)])
        }
        return .object(params)
    }
}

private extension JSONValue {
    var threadId: String? {
        guard case let .object(response) = self,
              case let .object(thread)? = response["thread"],
              case let .string(threadId)? = thread["id"],
              !threadId.isEmpty else {
            return nil
        }
        return threadId
    }
}

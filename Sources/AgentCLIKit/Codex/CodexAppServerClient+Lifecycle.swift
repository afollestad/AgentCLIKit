import Foundation

extension CodexAppServerClient {
    func shutdown() async {
        if isShutdown {
            guard !isShutdownComplete else {
                return
            }
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        isShutdown = true
        let activeTransport = transport
        let pendingTransportStart = transportStartOperation
        transport = nil
        transportStartOperation = nil
        initializationOperation?.task.cancel()
        initializationOperation = nil
        incomingTask?.cancel()
        incomingTask = nil
        incomingTaskID = nil
        bindingsByConversation.values.forEach { $0.continuation?.finish() }
        bindingsByConversation.removeAll()
        conversationByThreadId.removeAll()
        pendingServerRequests.removeAll()
        recoveredPlanKeysByConversation.removeAll()
        transcriptPlanSessionFileURLsByThreadId.removeAll()
        if let activeTransport {
            await activeTransport.shutdown()
        } else if let pendingTransportStart,
                  case let .success(startedTransport) = await pendingTransportStart.task.result {
            await startedTransport.shutdown()
        }
        isInitialized = false
        isShutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func processDidTerminate(processToken: UUID) async {
        await transport?.unregisterSensitiveValues(processToken: processToken)
    }

    func initializedTransport() async throws -> any CodexAppServerTransport {
        try ensureClientIsActive()
        if isInitialized, let transport {
            startIncomingPumpIfNeeded(transport: transport)
            return transport
        }
        if let initializationOperation {
            return try await finishInitialization(initializationOperation)
        }
        let transport = try await transportForStartup()
        try ensureClientIsActive()
        startIncomingPumpIfNeeded(transport: transport)
        if isInitialized {
            return transport
        }
        if let initializationOperation {
            return try await finishInitialization(initializationOperation)
        }
        let params = initializeParams()
        let task = Task { () throws -> any CodexAppServerTransport in
            _ = try await transport.sendRequest(method: "initialize", params: params)
            try await transport.sendNotification(method: "initialized", params: nil)
            return transport
        }
        let operation = InitializationOperation(id: UUID(), task: task)
        initializationOperation = operation
        return try await finishInitialization(operation)
    }

    private func transportForStartup() async throws -> any CodexAppServerTransport {
        try ensureClientIsActive()
        if let transport {
            return transport
        }
        let operation: TransportStartOperation
        if let transportStartOperation {
            operation = transportStartOperation
        } else {
            let configuration = configuration
            let newTask = Task { () throws -> any CodexAppServerTransport in
                let resolvedConfiguration = await configuration.resolvingExecutableIfNeeded(
                    for: CodexProviderDefinition.definition
                )
                let transport = resolvedConfiguration.makeTransport(resolvedConfiguration)
                try await transport.start()
                return transport
            }
            let newOperation = TransportStartOperation(id: UUID(), task: newTask)
            transportStartOperation = newOperation
            operation = newOperation
        }
        do {
            let startedTransport = try await operation.task.value
            try ensureClientIsActive()
            transport = startedTransport
            if transportStartOperation?.id == operation.id {
                transportStartOperation = nil
            }
            return startedTransport
        } catch {
            if transportStartOperation?.id == operation.id {
                transportStartOperation = nil
            }
            throw error
        }
    }

    private func finishInitialization(
        _ operation: InitializationOperation
    ) async throws -> any CodexAppServerTransport {
        do {
            let initializedTransport = try await operation.task.value
            try ensureClientIsActive()
            isInitialized = true
            if initializationOperation?.id == operation.id {
                initializationOperation = nil
            }
            return initializedTransport
        } catch {
            if initializationOperation?.id == operation.id {
                initializationOperation = nil
            }
            throw error
        }
    }

    private func ensureClientIsActive() throws {
        guard !isShutdown else {
            throw AgentCLIError.invalidInput("Codex App Server client has shut down.")
        }
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
}

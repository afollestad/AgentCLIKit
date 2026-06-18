import Foundation

extension CodexAppServerClient {
    func handleServerRequest(_ request: CodexAppServerRequest) async {
        guard let threadId = request.threadId,
              let conversationId = conversationByThreadId[AgentSessionID(rawValue: threadId)],
              let binding = bindingsByConversation[conversationId],
              let continuation = binding.continuation else {
            await sendServerErrorResponse(
                request,
                code: -32000,
                message: "Codex App Server request '\(request.method)' could not be routed to an active thread.",
                conversationId: nil
            )
            return
        }
        let mappingContext = CodexServerRequestMappingContext(
            conversationId: conversationId,
            processToken: binding.processToken,
            threadId: binding.threadId,
            permissionMode: binding.spawnConfig.permissionMode
        )
        if let mapped = serverRequestMapper.map(request, context: mappingContext) {
            if await autoResolveSessionApprovalIfAllowed(mapped) {
                return
            }
            pendingServerRequests[mapped.pending.interactionId] = mapped.pending
            continuation.yield(mapped.event)
            return
        }
        if request.method == "item/tool/call" {
            do {
                try await responseTransport().sendResponse(id: request.id, result: serverRequestMapper.unsupportedToolCallResponse)
                continuation.yield(serverRequestMapper.unsupportedToolCallEvent(request, threadId: binding.threadId))
            } catch {
                emitDiagnostic(error, conversationId: conversationId, message: "Could not reject Codex host-defined tool request.")
            }
            return
        }
        await sendUnsupportedServerRequest(request, threadId: threadId, conversationId: conversationId, continuation: continuation)
    }

    func sendUnsupportedServerRequest(
        _ request: CodexAppServerRequest,
        threadId: String,
        conversationId: AgentConversationID,
        continuation: AsyncStream<AgentProviderRuntimeEvent>.Continuation
    ) async {
        await sendServerErrorResponse(
            request,
            code: -32601,
            message: "Codex App Server request '\(request.method)' is not supported by AgentCLIKit.",
            conversationId: conversationId
        )
        continuation.yield(AgentProviderRuntimeEvent(event: .diagnostic(AgentDiagnosticEvent(
            code: .codexAppServerResponseFailure,
            severity: .warning,
            message: "Codex App Server request '\(request.method)' is not supported by AgentCLIKit.",
            metadata: [
                "codex_method": .string(request.method),
                "codex_thread_id": .string(threadId)
            ]
        ))))
    }

    func resolveInteraction(_ resolution: AgentInteractionResolution, context: AgentProviderInputContext) async throws {
        guard let pending = pendingServerRequests.removeValue(forKey: resolution.id) else {
            return
        }
        guard pending.conversationId == context.conversationId,
              pending.processToken == context.processToken else {
            pendingServerRequests[resolution.id] = pending
            return
        }
        let encodedResolution = resolutionEncoder.resolution(resolution, for: pending)
        let transport = try responseTransport()
        do {
            switch encodedResolution {
            case let .result(result):
                try await transport.sendResponse(id: pending.requestId, result: result)
            case let .error(code, message, data):
                try await transport.sendErrorResponse(id: pending.requestId, code: code, message: message, data: data)
            }
        } catch {
            emitDiagnostic(
                error,
                conversationId: pending.conversationId,
                message: "Could not resolve Codex App Server request '\(pending.method)'."
            )
            throw error
        }
    }

    func sendServerErrorResponse(
        _ request: CodexAppServerRequest,
        code: Int,
        message: String,
        conversationId: AgentConversationID?
    ) async {
        do {
            try await responseTransport().sendErrorResponse(id: request.id, code: code, message: message, data: nil)
        } catch {
            guard let conversationId else {
                return
            }
            emitDiagnostic(error, conversationId: conversationId, message: "Could not send Codex App Server error response.")
        }
    }

    func responseTransport() throws -> any CodexAppServerTransport {
        // Server-request replies must use the already-running transport to avoid recursive initialization while handling App Server input.
        guard let transport else {
            throw AgentCLIError.invalidInput("Codex App Server transport is unavailable.")
        }
        return transport
    }

    private func autoResolveSessionApprovalIfAllowed(_ mapped: CodexMappedServerRequest) async -> Bool {
        guard mapped.pending.kind == .commandApproval else {
            return false
        }
        let toolInput = JSONValue.object(mapped.pending.params)
        let request = AgentSessionApprovalRequest(
            providerId: CodexProviderAdapter.providerId,
            conversationId: mapped.pending.conversationId,
            sessionId: mapped.pending.threadId,
            toolName: "Bash",
            toolInput: toolInput,
            approvalIdentityToolInput: configuration.commandApprovalNormalizationPolicy.normalizedApprovalIdentityToolInput(
                toolName: "Bash",
                toolInput: toolInput
            )
        )
        guard await configuration.sessionApprovalPolicyStore.allowsSessionApproval(request) else {
            return false
        }

        do {
            try await responseTransport().sendResponse(id: mapped.pending.requestId, result: .object(["decision": .string("accept")]))
            return true
        } catch {
            emitDiagnostic(
                error,
                conversationId: mapped.pending.conversationId,
                message: "Could not auto-approve Codex App Server command request."
            )
            return false
        }
    }
}

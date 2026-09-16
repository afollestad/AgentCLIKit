import Foundation
import UniformTypeIdentifiers

/// Mutations are submitted once. Reconciliation can confirm acceptance but never replays ambiguous work.
extension OpenCodeClient {
    func send(_ input: AgentInput, context: AgentHarnessInputContext) async throws {
        let state = try requireState(context.processToken)
        switch input {
        case let .userMessage(message): try await sendMessage(message, state: state)
        case .interrupt: try await interrupt(processToken: context.processToken)
        case let .interactionResolution(resolution): try await resolve(resolution, state: state)
        }
    }

    func sendMessage(_ message: AgentMessageInput, state: OpenCodeGeneration) async throws {
        if message.metadata[AgentGoalMetadata.isInitialGoalTransport] == .bool(true) { throw Self.unsupported("native goals") }
        if message.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
            guard message.attachments.isEmpty else { throw AgentCLIError.invalidInput("Compaction cannot include attachments.") }
            try await compact(state)
            return
        }
        let (id, body) = try messageRequest(message, state: state)
        let previousMessageID = state.currentMessageID
        let wasActive = state.active
        state.currentMessageID = id
        state.pendingMessageIDs.insert(id)
        state.active = true
        state.interrupted = false
        if message.metadata[AgentSteeringMetadata.isSteering] == .bool(true) { state.steering[id] = message }
        do {
            _ = try await state.transport.request(method: "POST", path: "/session/\(state.sessionID)/prompt_async", body: body)
        } catch {
            // A timeout may mean the request was accepted. Resolve from history without a second POST.
            let history = try? await state.transport.request(method: "GET", path: "/session/\(state.sessionID)/message", body: nil)
            if let accepted = history?.ocArray?.first(where: { $0[oc: "info"]?[oc: "id"]?.ocString == id })?[oc: "info"] {
                // Confirm acceptance before other recovery reads; their failure must not invite a duplicate host retry.
                observeMessage(accepted, state: state)
                if state.nativeStatus == "idle" { finishIfComplete(state) }
                try? await reconcile(state)
                return
            }
            state.pendingMessageIDs.remove(id)
            state.steering[id] = nil
            if case let OpenCodeTransportError.http(status, _) = error, (400..<500).contains(status), status != 408 {
                state.currentMessageID = previousMessageID
                state.active = wasActive
                // The original turn may have reached idle while this steering submission was rejected.
                try? await reconcile(state)
                throw error
            }
            // Disable further input until explicit resume, avoiding an accidental duplicate retry by the host.
            state.failed = true
            finishTurn(state, error: "Prompt acceptance is unknown. Resume the session and inspect its history before retrying.")
            throw OpenCodeTransportError.unavailable("Prompt acceptance is unknown; it was not resent. Resume and inspect the session.")
        }
    }

    private func messageRequest(_ message: AgentMessageInput, state: OpenCodeGeneration) throws -> (String, JSONValue) {
        let parts = try messageParts(message, state: state)
        // Native history is sorted lexicographically by ID. Match its ascending timestamp prefix;
        // random UUID-only IDs would reorder prompts and break steering and compaction.
        let timestamp = max(UInt64(Date().timeIntervalSince1970 * 1_000), lastMessageTimestamp + 1)
        lastMessageTimestamp = timestamp
        let prefix = String(format: "%012llx", (timestamp * 0x1000) & 0xffffffffffff)
        let id = "msg_" + prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(14)
        var body: [String: JSONValue] = ["messageID": .string(id), "parts": .array(parts)]
        if let model = try modelIdentity(state) {
            body["model"] = .object(["providerID": .string(model.provider), "modelID": .string(model.model)])
        }
        if let variant = state.context.spawnConfig.effort {
            guard let variantInfo = selectedModel(state)?[oc: "variants"]?[oc: variant],
                  variantInfo[oc: "disabled"]?.ocBool != true else {
                throw AgentCLIError.invalidInput("The selected OpenCode model does not support reasoning option \(variant).")
            }
            body["variant"] = .string(variant)
        }
        body["agent"] = .string(state.collaborationMode == .plan ? "plan" : "build")
        let roots = state.context.spawnConfig.additionalWorkspaceRoots.map(\.path)
        var instructions = state.context.spawnConfig.hostToolServer.instructions.map { [$0] } ?? []
        if !roots.isEmpty { instructions.append("Additional workspace directories: " + roots.joined(separator: ", ")) }
        if !instructions.isEmpty { body["system"] = .string(instructions.joined(separator: "\n\n")) }
        return (id, .object(body))
    }

    private func messageParts(_ message: AgentMessageInput, state: OpenCodeGeneration) throws -> [JSONValue] {
        var parts: [JSONValue] = [.object(["type": .string("text"), "text": .string(message.text)])]
        for attachment in message.attachments {
            guard attachment.isLocalImage, selectedModel(state)?[oc: "capabilities"]?[oc: "input"]?[oc: "image"]?.ocBool == true else {
                throw AgentCLIError.unsupportedInputAttachment(
                    harnessId: .opencode, attachmentId: attachment.id, type: attachment.type,
                    reason: "Select an OpenCode model with confirmed image support."
                )
            }
            guard let url = attachment.fileURL, url.isFileURL,
                  let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/") else {
                throw AgentCLIError.invalidInput("OpenCode image attachments must be local image files.")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 20 * 1_024 * 1_024 else { throw AgentCLIError.invalidInput("Image exceeds the 20 MB attachment limit.") }
            parts.append(.object([
                "type": .string("file"), "mime": .string(mime), "filename": .string(url.lastPathComponent),
                "url": .string("data:\(mime);base64,\(data.base64EncodedString())")
            ]))
        }
        return parts
    }

    func compact(_ state: OpenCodeGeneration) async throws {
        guard !state.active else { throw AgentCLIError.invalidInput("Wait for the current OpenCode turn before compacting.") }
        let model = try await compactionModel(state)
        state.priorManualCompactionID = state.translator.compactions[state.sessionID]?.id
        state.lastCompletionError = nil
        state.compacting = true
        state.active = true
        state.interrupted = false
        do {
            _ = try await state.transport.request(method: "POST", path: "/session/\(state.sessionID)/summarize", body: .object([
                "providerID": .string(model.provider), "modelID": .string(model.model), "auto": .bool(false)
            ]))
            try await reconcile(state)
        } catch {
            // A lost summarize response does not prove that native inference stopped. Keep its
            // active state when reconciliation finds work or a completed summary; never resubmit.
            if await recoveredCompaction(state) { return }
            for event in state.translator.finishCompaction(sessionID: state.sessionID, error: "Manual compaction did not complete.") {
                emit(event, state: state)
            }
            state.compacting = false
            finishTurn(state, error: "Manual compaction did not complete.")
            throw error
        }
    }

    private func recoveredCompaction(_ state: OpenCodeGeneration) async -> Bool {
        // SSE can finish the native operation before its HTTP response or a follow-up snapshot arrives.
        if !state.active { return true }
        do {
            try await reconcile(state)
            return !state.active || state.nativeStatus == "busy" || state.nativeStatus == "retry"
        } catch {
            if !state.active { return true }
            state.failed = true
            return false
        }
    }

    func interrupt(processToken: UUID) async throws {
        let state = try requireState(processToken)
        state.interrupted = true
        _ = try await state.transport.request(method: "POST", path: "/session/\(state.sessionID)/abort", body: nil)
        try await reconcile(state)
        finishTurn(state)
    }
}

import AgentCLIKit
import Foundation

final class DemoHookDecisionProvider: ClaudeHookDecisionProviding, @unchecked Sendable {
    private let lock = NSLock()
    @MainActor private weak var model: DemoModel?
    private var continuations: [AgentInteractionID: CheckedContinuation<ClaudeHookDecision, Never>] = [:]

    @MainActor
    func bind(model: DemoModel) {
        self.model = model
    }

    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        guard request.toolName == "AskUserQuestion",
              let toolInput = request.toolInput,
              let prompt = DemoPrompt(id: interactionId, conversationID: request.conversationId, rawInput: toolInput) else {
            return .deferDecision
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                store(continuation, interactionId: interactionId)
                Task { @MainActor [weak self] in
                    self?.model?.present(prompt)
                }
            }
        } onCancel: {
            cancel(interactionId)
        }
    }

    @discardableResult
    func resolve(promptID: AgentInteractionID, decision: ClaudeHookDecision) -> Bool {
        let continuation = lock.withLock {
            continuations.removeValue(forKey: promptID)
        }
        guard let continuation else {
            return false
        }
        continuation.resume(returning: decision)
        return true
    }

    private func store(_ continuation: CheckedContinuation<ClaudeHookDecision, Never>, interactionId: AgentInteractionID) {
        let previous = lock.withLock {
            continuations.updateValue(continuation, forKey: interactionId)
        }
        previous?.resume(returning: .deferDecision)
    }

    private func cancel(_ interactionId: AgentInteractionID) {
        let continuation = lock.withLock {
            continuations.removeValue(forKey: interactionId)
        }
        continuation?.resume(returning: .deferDecision)
    }
}

private extension ClaudeHookRequest {
    var toolName: String? {
        payload.objectValue?["tool_name"]?.stringValue
            ?? payload.objectValue?["toolName"]?.stringValue
    }

    var toolInput: JSONValue? {
        payload.objectValue?["tool_input"] ?? payload.objectValue?["toolInput"]
    }
}

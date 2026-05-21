import AgentCLIKit
import Foundation

extension DemoModel {
    func present(_ prompt: DemoPrompt) {
        guard hasSession(prompt.conversationID) else {
            hookDecisionProvider.resolve(promptID: prompt.id, decision: .deferDecision)
            return
        }
        log("prompt conversation=\(prompt.conversationID.rawValue) id=\(prompt.id.rawValue) questions=\(prompt.questions.count)")
        updateTurnState(for: prompt.conversationID) { state in
            state.isActive = false
            state.streamingText = nil
            state.statusMessage = "Waiting for prompt answer"
        }
        guard !hasPrompt(prompt.id, sessionID: prompt.conversationID) else {
            return
        }
        append(
            DemoChatRow(
                id: Self.promptRowID(prompt.id),
                kind: .prompt(prompt)
            ),
            to: prompt.conversationID
        )
    }

    func submitPromptAnswers(promptID: AgentInteractionID, answers: [DemoPromptAnswer]) {
        guard let (sessionID, prompt) = prompt(promptID: promptID),
              !answers.isEmpty else {
            return
        }
        let decision = ClaudeHookDecision.allow(
            reason: "Answered in AgentCLIKitDemo",
            updatedInput: prompt.updatedInput(answers: answers)
        )
        guard hookDecisionProvider.resolve(promptID: promptID, decision: decision) else {
            appendStatus("Prompt expired before the answer was submitted.", to: sessionID)
            return
        }

        let answeredPrompt = DemoPrompt(
            id: prompt.id,
            conversationID: prompt.conversationID,
            questions: prompt.questions,
            rawInput: prompt.rawInput,
            submittedAnswers: answers
        )
        replacePrompt(answeredPrompt, sessionID: sessionID)
        updateTurnState(for: sessionID) { state in
            state.isActive = true
            state.streamingText = nil
            state.statusMessage = "Working"
        }
    }

    func hasPendingPrompt(_ sessionID: AgentConversationID) -> Bool {
        (rowsBySession[sessionID] ?? []).contains { row in
            guard case let .prompt(prompt) = row.kind else {
                return false
            }
            return prompt.submittedAnswers == nil
        }
    }

    private func prompt(promptID: AgentInteractionID) -> (AgentConversationID, DemoPrompt)? {
        for (sessionID, rows) in rowsBySession {
            guard let prompt = rows.compactMap({ row -> DemoPrompt? in
                guard case let .prompt(prompt) = row.kind, prompt.id == promptID else {
                    return nil
                }
                return prompt
            }).first else {
                continue
            }
            return (sessionID, prompt)
        }
        return nil
    }

    private func replacePrompt(_ prompt: DemoPrompt, sessionID: AgentConversationID) {
        guard var rows = rowsBySession[sessionID],
              let index = rows.firstIndex(where: { row in
                  row.id == Self.promptRowID(prompt.id)
              }) else {
            return
        }
        rows[index] = DemoChatRow(id: Self.promptRowID(prompt.id), kind: .prompt(prompt))
        rowsBySession[sessionID] = rows
    }

    func hasPrompt(_ promptID: AgentInteractionID, sessionID: AgentConversationID) -> Bool {
        (rowsBySession[sessionID] ?? []).contains { row in
            row.id == Self.promptRowID(promptID)
        }
    }

    static func promptRowID(_ promptID: AgentInteractionID) -> String {
        "prompt-\(promptID.rawValue)"
    }
}

# AgentCLIKit Examples

These examples are intentionally small. Use them as building blocks, then look at `AgentCLIKitDemo` for a complete macOS
app implementation.

Examples marked **Complete snippet** include imports and avoid undefined helpers. Examples marked **Skeleton** show the
host integration shape and use placeholders for app-owned UI or persistence.

## One-Off Conversation

**Complete snippet.** Starts one provider, sends one message, prints a few common events, and acknowledges event indexes.

```swift
import AgentCLIKit
import Foundation

func runOneOffConversation(projectURL: URL) async throws {
    let runtime = DefaultAgentRuntime()
    let conversationId = AgentConversationID(rawValue: "one-off-\(UUID().uuidString)")
    let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

    let eventTask = Task {
        for await envelope in subscription.events {
            switch envelope.event {
            case .message(let message):
                print("\(message.role.rawValue): \(message.text)")
            case .messageDelta(let delta):
                print(delta.text, terminator: "")
            case .reasoning(let reasoning):
                print("Reasoning: \(reasoning.text)")
            case .toolCall(let toolCall):
                print("Tool call: \(toolCall.name)")
            case .toolResult(let result):
                print("Tool result: \(result.content)")
            case .lifecycle(let lifecycle):
                print("Lifecycle: \(lifecycle.state.rawValue)")
            default:
                break
            }

            await runtime.markPersisted(
                conversationId: conversationId,
                generation: envelope.generation,
                upTo: envelope.index
            )
        }
    }

    try await runtime.spawn(
        conversationId: conversationId,
        config: AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: projectURL
        )
    )
    try await runtime.send(
        .userMessage(AgentMessageInput(text: "List the main modules in this package.")),
        conversationId: conversationId
    )

    try await Task.sleep(nanoseconds: 2_000_000_000)
    eventTask.cancel()
    await runtime.shutdown()
}
```

Change `providerId: .claude` to `providerId: .codex` to run the same host flow through Codex App Server.

## Persist And Resume Sessions

**Complete snippet.** Uses `JSONFileAgentSessionStore` so provider session IDs can be reused across app launches.

```swift
import AgentCLIKit
import Foundation

func sendWithPersistedSession(projectURL: URL, lastPersistedIndex: Int?) async throws {
    let sessionsURL = projectURL.appendingPathComponent(".agentclikit-sessions.json")
    let sessionStore = JSONFileAgentSessionStore(fileURL: sessionsURL)
    let runtime = DefaultAgentRuntime(sessionStore: sessionStore)
    let conversationId = AgentConversationID(rawValue: "workspace-main")

    let subscription = await runtime.subscribe(
        conversationId: conversationId,
        afterIndex: lastPersistedIndex
    )

    let eventTask = Task {
        for await envelope in subscription.events {
            if case .message(let message) = envelope.event {
                print(message.text)
            }
            await runtime.markPersisted(
                conversationId: envelope.conversationId,
                generation: envelope.generation,
                upTo: envelope.index
            )
        }
    }

    try await runtime.spawn(
        conversationId: conversationId,
        config: AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: projectURL
        )
    )
    try await runtime.send(
        .userMessage(AgentMessageInput(text: "Continue from the previous session.")),
        conversationId: conversationId
    )

    try await Task.sleep(nanoseconds: 2_000_000_000)
    eventTask.cancel()
    await runtime.shutdown()
}
```

`DefaultAgentRuntime` records provider session IDs and usable provider-reported names when providers report them. Hosts
should persist their latest event cursor separately, then pass it as `afterIndex` when subscribing after an app restart.

## Provider Readiness, Models, And Effort

**Complete snippet.** Builds a provider picker model from discovery status.

```swift
import AgentCLIKit
import Foundation

struct ProviderChoice {
    let providerId: AgentProviderID
    let displayName: String
    let isReady: Bool
    let modelLabels: [String]
    let defaultEffort: String?
}

func loadProviderChoices(projectURL: URL) async -> [ProviderChoice] {
    let setups: [any AgentProviderSetup] = [
        ClaudeProviderSetup(configStore: ClaudeConfigStore()),
        CodexProviderSetup()
    ]
    let discovery = DefaultAgentProviderDiscoveryService(
        providerSetups: setups,
        modelOptionSource: DefaultAgentModelOptionSource(
            codexSource: CodexAppServerModelOptionSource()
        )
    )
    let statuses = await discovery.providerStatuses(projectURL: projectURL)
    let ordering = await discovery.stableProviderOrdering()

    return ordering.compactMap { providerId in
        guard let status = statuses[providerId] else {
            return nil
        }
        return ProviderChoice(
            providerId: providerId,
            displayName: status.definition?.displayName ?? providerId.rawValue,
            isReady: status.isReadyInProject,
            modelLabels: status.modelOptions.map(\.label),
            defaultEffort: status.modelOptions.first(where: \.isDefault)?
                .defaultEffortOption?
                .value
        )
    }
}
```

Use the selected `AgentModelOption.model` and effort option value in `AgentSpawnConfig.model` and `AgentSpawnConfig.effort`.
If a model has no `supportedEffortOptions`, hide effort controls for that model.

## Settings And Plan Mode

**Skeleton.** Hosts can update settings for a started conversation by sending a complete replacement `AgentSpawnConfig`.
Use `collaborationMode` for plan/default mode and keep `permissionMode` for approval policy.

```swift
func setPlanMode(
    enabled: Bool,
    currentConfig: AgentSpawnConfig,
    conversationId: AgentConversationID,
    runtime: any AgentRuntime
) async throws {
    let updatedConfig = AgentSpawnConfig(
        providerId: currentConfig.providerId,
        workingDirectory: currentConfig.workingDirectory,
        arguments: currentConfig.arguments,
        environment: currentConfig.environment,
        model: currentConfig.model,
        effort: currentConfig.effort,
        permissionMode: currentConfig.permissionMode,
        collaborationMode: enabled ? .plan : .default,
        forkSession: currentConfig.forkSession,
        initialPrompt: nil
    )

    let result = try await runtime.reconfigure(
        conversationId: conversationId,
        config: updatedConfig
    )

    switch result {
    case .appliedInPlace, .restarted:
        rememberCurrentConfig(updatedConfig)
    case .nextTurnRequired:
        stageConfigForNextTurn(updatedConfig)
    }
}
```

Codex plan/default collaboration settings require a concrete `AgentSpawnConfig.model`; pass the selected
`AgentModelOption.model` before enabling plan mode. Keep `initialPrompt` nil for settings-only reconfigure requests so a
replacement launch does not resend a one-shot prompt. Render plan-mode UI from `AgentRuntimeStatus.collaborationMode` or
`AgentEvent.collaborationMode`, because providers can report collaboration changes after host actions such as
`ExitPlanMode`.

## Project Trust

**Complete snippet.** Checks and updates provider-neutral project trust state.

```swift
import AgentCLIKit
import Foundation

func trustProjectIfNeeded(providerId: AgentProviderID, projectURL: URL) async throws -> AgentProjectTrustStatus {
    let setups: [any AgentProviderSetup] = [
        ClaudeProviderSetup(configStore: ClaudeConfigStore()),
        CodexProviderSetup()
    ]
    let trustService = DefaultAgentProjectTrustService(setups: setups)
    let status = await trustService.status(providerId: providerId, projectURL: projectURL)

    guard status == .notTrusted else {
        return status
    }

    try await trustService.trustProject(providerId: providerId, projectURL: projectURL)
    return await trustService.status(providerId: providerId, projectURL: projectURL)
}
```

Claude trust writes `.claude.json`. Codex trust writes Codex's user-level `config.toml` project trust table. Codex auth
readiness is separate from project trust.

## Approval And Prompt Resolution

**Skeleton.** Runtime interactions are surfaced as `AgentEvent.interaction`. The host renders the request, then resolves it
through the runtime.

```swift
func handleInteraction(
    _ interaction: AgentInteractionEvent,
    conversationId: AgentConversationID,
    runtime: any AgentRuntime
) async throws {
    switch interaction.kind {
    case .approval:
        let approved = await askUserToApprove(interaction.prompt)
        try await runtime.resolveInteraction(
            AgentInteractionResolution(
                id: interaction.id,
                outcome: approved ? .approved : .denied
            ),
            conversationId: conversationId
        )

    case .prompt:
        let answer = await askUserForText(interaction.prompt, options: interaction.promptOptions)
        try await runtime.resolveInteraction(
            AgentInteractionResolution(
                id: interaction.id,
                outcome: .answered,
                responseText: answer
            ),
            conversationId: conversationId
        )

    case .planModeExit:
        let approved = await askUserToApprovePlan(interaction.prompt)
        try await runtime.resolveInteraction(
            AgentInteractionResolution(
                id: interaction.id,
                outcome: approved ? .approved : .denied
            ),
            conversationId: conversationId
        )
    }
}
```

`AgentInteractionInbox` is an optional helper for host-owned pending-action storage. Use it when your provider adapter or
hook configuration shares the same `AgentInteractionStore`; do not assume the inbox is automatically connected to every
runtime interaction.

## Status Updates And Cancellation

**Skeleton.** Status snapshots let UI distinguish an active turn, provider wait states, and whether cancellation is useful.

```swift
func observeStatus(
    conversationId: AgentConversationID,
    runtime: any AgentRuntime
) async {
    let statuses = await runtime.statusUpdates(conversationId: conversationId)

    for await status in statuses {
        updateSendButton(enabled: status.inputAvailability == .available)
        updateCancelButton(enabled: status.canCancel)

        switch status.waitingState {
        case .idle:
            showWaitingMessage(nil)
        case .approval:
            showWaitingMessage("Waiting for approval")
        case .prompt:
            showWaitingMessage("Waiting for an answer")
        case .planModeExit:
            showWaitingMessage("Waiting for plan approval")
        }
    }
}

func cancelConversation(
    conversationId: AgentConversationID,
    runtime: any AgentRuntime
) async {
    await runtime.cancel(conversationId: conversationId)
}
```

`status.isTurnActive` is useful for hosts that support mid-turn steering. A provider can accept input while a tool-backed
turn is still active, so `inputAvailability` alone is not the full turn-state model.

## Where To Look Next

- `Sources/AgentCLIKitDemo/DemoModel.swift` shows runtime ownership, provider discovery, session persistence, and status subscriptions.
- `Sources/AgentCLIKitDemo/DemoModel+Events.swift` shows one event projection strategy.
- `Sources/AgentCLIKitDemo/Interactions` shows demo prompt UI and Claude hook decision handling.

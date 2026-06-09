# AgentCLIKit

AgentCLIKit is a Swift package for macOS apps that run local agent CLIs through one provider-neutral runtime API.

It gives host apps a reusable layer for:

- Launching Claude Code or Codex App Server.
- Sending user messages and steering active turns.
- Receiving provider-neutral events for messages, tools, usage, tasks, session metadata, permission/collaboration state,
  context compaction, lifecycle, and interactions.
- Persisting provider session IDs and provider-reported names so conversations can resume.
- Checking provider readiness, project trust, speed support, model options, and model-scoped effort options.

Host apps still own UI, durable app data, queueing policy, notifications, and product-specific workflow decisions.
AgentCLIKit owns process launch, provider sessions, stdin/stdout coordination, App Server transport, event replay, status,
and interaction resolution.

## Installation

Add AgentCLIKit as a Swift Package dependency. This repository does not currently publish version tags, so use `main`:

```swift
.package(url: "https://github.com/afollestad/AgentCLIKit.git", branch: "main")
```

Then add the library product to your macOS target:

```swift
.product(name: "AgentCLIKit", package: "AgentCLIKit")
```

For local app development, prefer a path dependency pointed at this checkout:

```swift
.package(path: "../AgentCLIKit")
```

Host machines also need the provider CLI installed. Built-in adapters support Claude Code and Codex App Server, and resolve
provider executables through the shared provider detector and executable resolver.

## Quick Start

This complete snippet subscribes before spawning, starts a provider, sends one message, handles common events, acknowledges
persisted event indexes, and shuts runtime resources down.

```swift
import AgentCLIKit
import Foundation

func runAgentConversation(
    projectURL: URL,
    providerId: AgentProviderID = .claude
) async throws {
    let sessionsURL = projectURL.appendingPathComponent(".agentclikit-sessions.json")
    let runtime = DefaultAgentRuntime(
        sessionStore: JSONFileAgentSessionStore(fileURL: sessionsURL)
    )
    let conversationId = AgentConversationID(rawValue: "readme-\(UUID().uuidString)")

    let subscription = await runtime.subscribe(
        conversationId: conversationId,
        afterIndex: nil
    )

    let eventTask = Task {
        for await envelope in subscription.events {
            switch envelope.event {
            case .message(let message):
                print("\(message.role.rawValue): \(message.text)")
            case .messageDelta(let delta):
                print(delta.text, terminator: "")
            case .toolCall(let toolCall):
                print("Tool: \(toolCall.name)")
            case .contextCompaction(let compaction):
                print("Compaction \(compaction.id): \(compaction.phase.rawValue)")
            case .sessionMetadata(let metadata):
                if let name = metadata.name {
                    print("Session name: \(name)")
                } else if let preview = metadata.preview {
                    print("Session preview: \(preview)")
                }
            case .interaction(let interaction):
                print("Waiting for \(interaction.kind.rawValue): \(interaction.prompt)")
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
            providerId: providerId,
            workingDirectory: projectURL
        )
    )

    try await runtime.send(
        .userMessage(AgentMessageInput(text: "Summarize this project.")),
        conversationId: conversationId
    )

    try await Task.sleep(nanoseconds: 2_000_000_000)
    eventTask.cancel()
    await runtime.shutdown()
}
```

In a real app, keep the event and status tasks alive for the conversation lifetime, persist envelopes before calling
`markPersisted`, and resolve interaction events from your UI.

## Common Flows

Most apps build around a few reusable flows:

- Create one long-lived `DefaultAgentRuntime` for the app or workspace.
- Subscribe to `AgentEventEnvelope` values with a persisted cursor.
- Start a conversation with `AgentSpawnConfig`.
- Send input through `runtime.send`.
- Resolve provider questions and approvals through `runtime.resolveInteraction`.
- Watch `runtime.statusUpdates` for waiting, active-turn, and cancellation state.
- Use provider discovery and setup services for settings and project readiness UI.

Treat `AgentSpawnConfig` as the host-facing settings source of truth. `permissionMode` is approval policy. Plan/default
collaboration uses `collaborationMode`: pass `.plan` to enter plan mode, `.default` to leave it, and `nil` when the host is
not overriding provider collaboration state. Speed uses `speedMode`: pass `.fast` only when
`AgentProviderCapabilities.supportsSpeedMode` is true, `.standard` to force supported providers back to normal behavior,
and `nil` to preserve provider defaults. Codex plan mode requires a concrete selected `model`.

Use `runtime.reconfigure(conversationId:config:)` to apply changed settings to a started conversation. The result tells
the host what happened:

- `.appliedInPlace`: the provider accepted settings without replacing the process.
- `.restarted`: the runtime restarted or resumed the provider process with the new config.
- `.nextTurnRequired`: the provider has an active turn, so persist or stage the config and pass it before the next turn.

See [docs/examples.md](docs/examples.md) for practical recipes covering:

- One-off conversations.
- Session persistence and resume.
- Provider readiness, model, and effort selection.
- Project trust setup.
- Settings updates and plan/default collaboration mode.
- Approval and prompt resolution.
- Status updates and cancellation.

## Provider Setup

AgentCLIKit includes provider-specific setup services that keep provider details out of generic host code.

Use `DefaultAgentProviderDiscoveryService` to build provider pickers and settings:

```swift
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
```

`AgentProviderStatus` reports installation, enablement, setup readiness, project trust, provider capabilities, selectable
models, model-scoped effort options, and diagnostics. Use `AgentProviderDefinition.capabilities.supportsSpeedMode` before
showing speed controls, and use `AgentModelOption.supportedEffortOptions` and
`AgentModelOption.defaultEffortOption` before showing effort controls.

Use `DefaultAgentProjectTrustService` when the user chooses to trust a project:

```swift
let trustService = DefaultAgentProjectTrustService(setups: setups)
try await trustService.trustProject(providerId: .codex, projectURL: projectURL)
```

Claude setup preserves unrelated `.claude.json` content such as MCP servers. Codex setup writes Codex's user-level project
trust table and can report credential-source readiness without exposing token contents or running `codex login`.

## Provider Notes

Claude and Codex share the host-facing runtime API, but their native transports differ:

| Area | Claude | Codex |
| --- | --- | --- |
| Transport | Claude CLI stream JSON over stdin/stdout | Codex App Server JSON-RPC |
| Provider setup | User `.claude.json` trust and hooks | User `~/.codex/config.toml` trust and auth readiness |
| Interactions | Claude hook requests and stream events | App Server requests and notifications |
| Models | Built-in `ClaudeModelOptionSource` | Static fallback or opt-in live `model/list` |
| Plan mode | `collaborationMode: .plan` maps to Claude's internal `--permission-mode plan` | Idle threads use `thread/settings/update`; plan mode requires a concrete model |
| Speed mode | Not supported; Claude's fast-like `--bare` path disables hooks | `speedMode: .fast` when Codex reports `fast_mode` support |
| Archive | Validated no-op | App Server `thread/archive` and `thread/unarchive` |

Both built-in providers expose provider-neutral events, sessions, provider session metadata, usage, tool events, task
events, permission/collaboration state, prompt/approval interactions, MCP support, and context compaction lifecycle events. Inspect
`AgentProviderDefinition.capabilities` before showing provider-specific UI.

For detailed provider behavior, see [docs/provider-reference.md](docs/provider-reference.md).

## Demo App

Run the macOS demo with:

```sh
./scripts/run-demo.sh
```

The demo builds and launches `AgentCLIKitDemo`. It shows provider readiness, provider/model/effort/speed selection, persisted
session records, live output rendering, status snapshots, cancellation, Claude prompt handling, and Codex live model
loading through App Server.

Useful entry points:

- [Sources/AgentCLIKitDemo/DemoModel.swift](Sources/AgentCLIKitDemo/DemoModel.swift)
- [Sources/AgentCLIKitDemo/DemoModel+Events.swift](Sources/AgentCLIKitDemo/DemoModel+Events.swift)
- [Sources/AgentCLIKitDemo/Interactions](Sources/AgentCLIKitDemo/Interactions)

## Validation

Use the repo scripts from the repository root:

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/lint.sh
./scripts/validate-package-consumer.sh
```

`./scripts/build.sh` and `./scripts/test.sh` pipe `xcodebuild` through `xcsift -f toon -w` when `xcsift` is installed.
`./scripts/validate-package-consumer.sh` builds a temporary package that imports the library product from a fresh
scratch/cache path and validates the demo product.

## Reference

- [Practical examples](docs/examples.md)
- [Provider reference](docs/provider-reference.md)
- [Runtime protocol](Sources/AgentCLIKit/Runtime/AgentRuntime.swift)
- [Provider discovery](Sources/AgentCLIKit/Providers/AgentProviderDiscovery.swift)
- [Provider definitions and capabilities](Sources/AgentCLIKit/Providers/AgentProviderDefinition.swift)
- [Provider-neutral events](Sources/AgentCLIKit/Core/AgentEvents.swift)
- [Provider-neutral interactions](Sources/AgentCLIKit/Interactions/AgentInteractions.swift)

## License

AgentCLIKit is licensed under the [GNU General Public License v3.0](LICENSE.md).

# AgentCLIKit

AgentCLIKit is a Swift package for macOS apps that run local agent CLIs through one harness-neutral runtime API.

Claude Code, Codex, and OpenCode are **harnesses**: they run models and manage agent sessions and tools. Anthropic and OpenAI are
**model providers**. The SDK uses harness terminology for the CLI integration layer.

It gives host apps a reusable layer for:

- Launching Claude Code, Codex App Server, or a private OpenCode HTTP server.
- Running sessionless one-shot prompts for project-level tasks that should not create harness sessions.
- Sending user messages and steering active turns.
- Receiving harness-neutral events for messages, tools, usage, tasks, sub-agent lifecycle, session metadata,
  permission/collaboration state, context compaction, lifecycle, and interactions.
- Persisting harness session IDs and harness-reported names so conversations can resume.
- Checking harness readiness, project trust, speed support, model options, and model-scoped effort options.
- Exposing host-owned MCP tools and additional workspace roots to built-in harnesses without changing global harness config.

Host apps still own UI, durable app data, queueing policy, notifications, and product-specific workflow decisions.
AgentCLIKit owns process launch, harness sessions, stdin/stdout coordination, App Server and HTTP/SSE transports, event replay, status,
interaction resolution, and sessionless one-shot harness prompts.

## Harness Naming Migration

The Swift API now uses `AgentHarness*`, `ClaudeHarness*`, and `CodexHarness*` names, with `harnessId` and `harnessSession*`
properties and parameter labels. Update consumers to the new names; the former provider APIs have no compatibility aliases.

Persisted JSON field names, metadata keys, diagnostic/error raw values, and the `claude`/`codex` identity values remain
unchanged, so existing records require no data migration. Explicit `CodingKeys` map the new Swift properties to their
original `provider*` keys. Upstream model-provider fields and hook-decision provider services retain their names.

## Installation

AgentCLIKit requires Swift 6.1 or newer because its exact Swift MCP SDK dependency uses a Swift 6.1 package manifest.

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

Host machines also need the harness CLI installed. Built-in adapters support Claude Code, Codex App Server, and OpenCode 1.18.31 or newer within 1.x, and resolve
harness executables through the shared harness detector and executable resolver.

## Quick Start

This complete snippet subscribes before spawning, starts a harness, sends one message, handles common events, acknowledges
persisted event indexes, and shuts runtime resources down.

```swift
import AgentCLIKit
import Foundation

func runAgentConversation(
    projectURL: URL,
    harnessId: AgentHarnessID = .claude
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
            case .subAgent(let subAgent):
                print("Sub-agent: \(subAgent.phase.rawValue) \(subAgent.description ?? subAgent.id)")
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
            harnessId: harnessId,
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
- Use `DefaultAgentOneShotPromptRunner` for project-level prompts that need one final answer without a runtime conversation.
- Subscribe to `AgentEventEnvelope` values with a persisted cursor.
- Start a conversation with `AgentSpawnConfig`.
- Send input through `runtime.send`.
- Resolve harness questions and approvals through `runtime.resolveInteraction`.
- Watch `runtime.statusUpdates` for waiting, active-turn, and cancellation state.
- Use harness discovery and setup services for settings and project readiness UI.

For a promptless approval continuation, call `DefaultAgentRuntime.spawn(conversationId:config:resumingTurn:)` with
`resumingTurn: true`. It seeds active-turn status for that launch until terminal output; later launches use their own activity settings.

For reusable approval scopes, use `AgentSessionApprovalRequest` and `AgentSessionApprovalPolicyStore`. Bash approvals carry
raw harness input plus an optional canonical `approvalIdentityToolInput`, derived by
`AgentCommandApprovalNormalizationPolicy`, so transparent wrappers and safe shell `-c` wrappers can share exact/group
approval identities without changing the command the harness executes.

Treat `AgentSpawnConfig` as the host-facing settings source of truth. `permissionMode` is approval policy. Plan/default
collaboration uses `collaborationMode`: pass `.plan` to enter plan mode, `.default` to leave it, and `nil` when the host is
not overriding harness collaboration state. Speed uses `speedMode`: pass `.fast` only when
`AgentHarnessCapabilities.supportsSpeedMode` is true, `.standard` to force supported harnesses back to normal behavior,
and `nil` to preserve harness defaults. To keep an agent from reaching external services except through host tools, pass
`integrationIsolation` options listed in `AgentHarnessCapabilities.supportedIntegrationIsolation`. Local image input
uses `AgentMessageInput.attachments`; setup sends can carry the same data through
`AgentSpawnConfig.initialPromptAttachments` and `initialPromptMetadata`. Show image-attachment UI only when `AgentHarnessCapabilities.supportsLocalImageInput` is true. Harnesses that cannot encode an attachment throw
`AgentCLIError.unsupportedInputAttachment`, so hosts should fall back to visible prompt text such as Markdown image links
before sending. Claude exposes `bypassPermissions` as an explicit dangerous approval policy; AgentCLIKit unlocks that mode
for the launch without using `--dangerously-skip-permissions`. Codex plan mode requires a concrete selected `model`. To
fork harness context into a new host conversation, pass `sessionFork` with the source harness session ID and the target
`workingDirectory`; copied host transcript records are not harness context.

For one final answer without a runtime conversation, use `DefaultAgentOneShotPromptRunner`. It invokes harness CLIs in
read-only mode and does not create AgentCLIKit runtime state. Codex uses `codex exec --ephemeral --json` rather than Codex
App Server; the CLI may still emit a transient `thread.started` id, but the run is not expected to persist a harness
thread. Claude uses `claude -p --safe-mode --no-session-persistence --output-format stream-json` with native read-only
tools restricted to file inspection. OpenCode uses `run --format json` in a disposable profile, copies only the selected
provider connection, and permits native `read`, `glob`, and `grep` tools. It requires an exact `provider/model`; `effort`
is the exact native variant, or `nil` for its default. Its temporary session database is removed after the process exits.
One-shot runs cannot service approvals or harness prompts.

Hosts using their own process runner should call `adapter.prepareOneShotPrompt(request:)`, run its `command`, then call
`cleanup()` after process termination on every exit path. Honor `ShellCommand.inheritsEnvironment`: `false` replaces the
parent environment completely. If `executionDeadline` is present, reject expired preparations and cap execution to the
time remaining. `DefaultAgentOneShotPromptRunner` owns these steps. The command-only adapter API remains
available for harnesses that need no disposable resources; OpenCode requires preparation.

Use `runtime.reconfigure(conversationId:config:)` to apply changed settings to a started conversation. The result tells
the host what happened:

- `.appliedInPlace`: the harness accepted settings without replacing the process.
- `.restarted`: the runtime restarted or resumed the harness process with the new config.
- `.nextTurnRequired`: the harness has an active turn, so persist or stage the config and pass it before the next turn.

Host-owned tools use `AgentSpawnConfig.hostTools` for Codable definitions and an `AgentHostToolHandling` closure injected
into `DefaultAgentRuntime` for execution. Each launch receives an authenticated, process-scoped loopback endpoint;
AgentCLIKit never writes these tools into global Claude or Codex MCP files. Put extra file access in
`additionalWorkspaceRoots`. Tool/root changes restart an idle harness and return `.nextTurnRequired` during an active
turn. A nonempty tool list without injected handling fails with `AgentCLIError.hostToolsUnavailable`.
Codex resumes with explicit roots through a history-preserving fork, including when host tools are disabled. Pass `[cwd]`
to explicitly remove all extra roots; an empty list preserves Codex's native roots.

See [docs/examples.md](docs/examples.md) for practical recipes covering:

- One-off conversations.
- Session persistence and resume.
- Harness readiness, model, and effort selection.
- Project trust setup.
- Settings updates and plan/default collaboration mode.
- Approval and prompt resolution.
- Status updates and cancellation.

## Harness Setup

AgentCLIKit includes harness-specific setup services that keep harness details out of generic host code.

Setup readiness reflects each harness's sign-in state. `CodexHarnessSetup` reads Codex's auth file; `ClaudeHarnessSetup`
needs a `ClaudeAuthProbe`, because Claude keeps its credential in the keychain and only the CLI can report it. Omit the probe
and Claude setup readiness stays `.ready` regardless of sign-in state. An inconclusive probe also reports `.ready`, so a
failed spawn never locks a host out of a working CLI.

Use `DefaultAgentHarnessDiscoveryService` to build harness pickers and settings:

```swift
let setups: [any AgentHarnessSetup] = [
    ClaudeHarnessSetup(configStore: ClaudeConfigStore(), authProbe: ClaudeAuthProbe()),
    CodexHarnessSetup()
]

let discovery = DefaultAgentHarnessDiscoveryService(
    harnessSetups: setups,
    modelOptionSource: DefaultAgentModelOptionSource(
        codexSource: CodexAppServerModelOptionSource()
    )
)

let statuses = await discovery.harnessStatuses(projectURL: projectURL)
```

`AgentHarnessStatus` reports installation, enablement, setup readiness, project trust, harness capabilities, selectable
models, model-scoped effort options, and diagnostics. Use `AgentHarnessDefinition.capabilities.supportsSpeedMode` before
showing speed controls, and use `AgentModelOption.supportedEffortOptions` and
`AgentModelOption.defaultEffortOption` before showing effort controls. Before discovery completes, render
`AgentDefaultModelOptions.staticOptions(for:)` — for Claude it is exactly the list discovery reports, so a cold start
never shows a raw model id.

Claude's catalog includes Opus 5.5 (`claude-opus-5-5`) with `low`, `medium`, `high`, `xhigh`, and `max` effort,
defaulting to `medium`. The `opus` short name selects Opus 5.5; older pinned Opus versions remain selectable with
their existing effort defaults.

Use `DefaultAgentProjectTrustService` when the user chooses to trust a project:

```swift
let trustService = DefaultAgentProjectTrustService(setups: setups)
try await trustService.trustProject(harnessId: .codex, projectURL: projectURL)
```

Claude setup preserves unrelated `.claude.json` content such as MCP servers. Codex setup writes Codex's user-level project
trust table and can report credential-source readiness without exposing token contents or running `codex login`.

## Harness Notes

OpenCode uses an authenticated loopback HTTP server and SSE events. Its model options retain provider/model identity
and native variants. Share an opt-in `OpenCodeDiscoveryProbe` between `OpenCodeHarnessSetup` and
`OpenCodeModelOptionSource` to check the supported server version and connected providers without creating sessions.
OpenCode supports core sessions, native forks, permissions/questions, MCP, planning, compaction, and model-supported
images, and isolated read-only one-shot prompts. Native goals, Fast mode, hooks, unarchiving, and experimental background
agents are not exposed; check `supportsReadOnlyOneShotPrompts` before offering utility generation. OpenCode permission modes are
`configured`, `ask` (the default), and `fullAccess`; these control tool approval and do not provide an OS sandbox.


Claude and Codex share the host-facing runtime API, but their native transports differ:

| Area | Claude | Codex |
| --- | --- | --- |
| Transport | Claude CLI stream JSON over stdin/stdout | Codex App Server JSON-RPC |
| Harness setup | User `.claude.json` trust and hooks | User `~/.codex/config.toml` trust and auth readiness |
| Interactions | Claude hook requests and stream events | App Server requests and notifications |
| Models | Built-in `ClaudeModelOptionSource` | Static fallback or opt-in live `model/list` |
| Plan mode | `collaborationMode: .plan` maps to Claude's internal `--permission-mode plan` | Idle threads use `thread/settings/update`; plan mode requires a concrete model |
| Speed mode | Not supported; Claude's fast-like `--bare` path disables hooks | `speedMode: .fast` when Codex reports `fast_mode` support |
| Integration isolation | `.nativeIntegrations` (`--strict-mcp-config`) and `.shellNetwork` (Bash sandbox, network off) | `.nativeIntegrations` and `.shellNetwork` per thread |
| Native fork | `--resume <source> --fork-session` | App Server `thread/fork` |
| Host tools and extra roots | Inline process MCP config and `--add-dir` | Per-thread MCP config and `runtimeWorkspaceRoots` |
| Archive/delete | Validated no-op | App Server `thread/archive`, `thread/unarchive`, and `thread/delete` |

Claude and Codex expose harness-neutral events, sessions, harness session metadata, usage, tool events, task
events, typed sub-agent lifecycle, permission/collaboration state, prompt/approval interactions, MCP support, and
context compaction lifecycle events. Inspect `AgentHarnessDefinition.capabilities` before showing harness-specific UI.

For detailed harness behavior, see [docs/harness-reference.md](docs/harness-reference.md).

Use `AgentHarnessSessionActionRouter(borrowing: adapterSet)` with the runtime's adapter set for session cleanup.
This reaches the Codex server holding a loaded thread's writer lock and leaves shared adapters running. The default
router and factory initializer own fresh adapters and shut them down after each action.

## Demo App

Run the macOS demo with:

```sh
./scripts/run-demo.sh
```

The demo builds and launches `AgentCLIKitDemo`. It shows harness readiness, harness/model/effort/speed selection, persisted
session records, live output rendering, status snapshots, cancellation, Claude prompt handling, and Codex live model
loading through App Server, plus OpenCode provider discovery.

Useful entry points:

- [Sources/AgentCLIKitDemo/DemoModel.swift](Sources/AgentCLIKitDemo/DemoModel.swift)
- [Sources/AgentCLIKitDemo/DemoModel+Events.swift](Sources/AgentCLIKitDemo/DemoModel+Events.swift)
- [Sources/AgentCLIKitDemo/Interactions](Sources/AgentCLIKitDemo/Interactions)

## Validation

CI uses GitHub's `xcode-27` runner with its default Xcode selection and logs the macOS and compiler versions.

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
- [Harness reference](docs/harness-reference.md)
- [Runtime protocol](Sources/AgentCLIKit/Runtime/AgentRuntime.swift)
- [Harness discovery](Sources/AgentCLIKit/Harnesses/AgentHarnessDiscovery.swift)
- [Harness definitions and capabilities](Sources/AgentCLIKit/Harnesses/AgentHarnessDefinition.swift)
- [Harness-neutral events](Sources/AgentCLIKit/Core/AgentEvents.swift)
- [Harness-neutral interactions](Sources/AgentCLIKit/Interactions/AgentInteractions.swift)

## License

AgentCLIKit is licensed under the [GNU General Public License v3.0](LICENSE.md).

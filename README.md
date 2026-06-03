# AgentCLIKit

AgentCLIKit is a Swift package for macOS apps that run local agent CLIs through a reusable, provider-neutral API.

The runtime owns process launch, stdin/stdout coordination, event replay, provider sessions, and interaction resolution. Provider-specific code lives in folders such as `Claude/`, so future providers can add adapters, decoders, config, and hook support without changing the runtime core.

## Installation

Add AgentCLIKit as a Swift Package dependency:

```swift
.package(url: "https://github.com/afollestad/AgentCLIKit.git", from: "x.y.z")
```

Then add the library product to your macOS target:

```swift
.product(name: "AgentCLIKit", package: "AgentCLIKit")
```

## Architecture

AgentCLIKit is split into provider-neutral subsystems and provider implementations:

- `Core`: events, input, usage, interactions, sessions, errors, and utility types.
- `Runtime`: process lifecycle, streams, event buffering, subscriptions, status, and input serialization.
- `Providers`: provider metadata, registry, detection, adapters, and shell helpers.
- `Sessions`: JSON and in-memory provider session stores.
- `Interactions`: approvals, prompts, hook listener primitives, and interaction persistence.
- `Transcript`: provider-neutral transcript grouping.
- `Context`: context-window cache and handoff prompt helpers.
- `MCP`: provider-agnostic MCP server management.
- `Skills`: provider skill-directory scanning and sync helpers.
- `Claude`: Claude Code adapter, config, hooks, approval policy, MCP bridge, and stream decoding.
- `Codex`: Codex App Server adapter, `.codex` config, App Server protocol decoding, approval handling, MCP bridge, and validation fixtures.

Host apps own UI state, persistence, drafts, notifications, and queueing policy. AgentCLIKit owns runtime mechanics and emits provider-neutral events that hosts can persist or render however they want.

## Create A Runtime

Use one runtime actor per app-level runtime service:

```swift
let runtime = DefaultAgentRuntime(
    sessionStore: JSONFileAgentSessionStore(fileURL: sessionsURL)
)
```

The default adapter set includes Claude and Codex runtime adapters. Codex starts its App Server lazily only when a `.codex`
conversation is spawned; static provider metadata and discovery do not launch it.

Hosts that need custom Claude hook stores, Codex App Server configuration, or test adapters can provide an adapter set:

```swift
let adapterSet = AgentProviderAdapterSet.default(
    claude: ClaudeProviderAdapter.Configuration(
        hookDecisionProvider: hookDecisionProvider
    ),
    codex: CodexProviderAdapter.Configuration()
)
let runtime = DefaultAgentRuntime(adapterSet: adapterSet, sessionStore: sessionStore)
```

Explicit adapters can still override built-ins for tests or custom hosts:

```swift
let adapterSet = AgentProviderAdapterSet(overriding: [customClaudeAdapter])
let runtime = DefaultAgentRuntime(adapterSet: adapterSet, sessionStore: sessionStore)
```

## Spawn A Conversation

Start a provider with a conversation identifier and working directory:

```swift
try await runtime.spawn(
    conversationId: conversationId,
    config: AgentSpawnConfig(
        providerId: .claude,
        workingDirectory: projectPath
    )
)
```

`AgentSpawnConfig` also supports provider arguments, environment overrides, model, effort, permission mode, and an initial prompt:

```swift
let config = AgentSpawnConfig(
    providerId: .claude,
    workingDirectory: projectPath,
    arguments: ["--add-dir", supportPath.path],
    environment: ["CLAUDE_CONFIG_DIR": configPath.path],
    model: "claude-sonnet-4-5",
    effort: "high",
    permissionMode: "plan"
)
```

Provider adapters own native launch ordering. For Claude, AgentCLIKit emits stream JSON flags, then permission mode, model,
effort, session continuity, extra arguments, and optional initial prompt.

## Subscribe And Persist Events

Subscriptions yield indexed event envelopes. Persist what your app needs, then acknowledge events after the save succeeds:

```swift
let subscription = await runtime.subscribe(
    conversationId: conversationId,
    afterIndex: lastPersistedEventIndex
)

for await envelope in subscription.events {
    persist(envelope)
    await runtime.markPersisted(
        conversationId: conversationId,
        generation: envelope.generation,
        upTo: envelope.index
    )
}
```

Output arrives as provider-neutral `AgentEvent` values. Events cover messages, streaming deltas, reasoning, tool calls and results, usage, rate limits, permission mode, task state, session continuity, diagnostics, lifecycle, and interaction requests. Message and tool events include metadata dictionaries for provider details.

## Send Input

Input flows through the runtime:

```swift
try await runtime.send(
    .userMessage(AgentMessageInput(text: "Implement the parser")),
    conversationId: conversationId
)
```

Provider adapters serialize input in their native format. Claude writes stream JSON, while Codex sends turn input and
steering through App Server JSON-RPC while keeping the same host-facing API.

## Observe Status

Runtime status snapshots expose lifecycle, permission mode, waiting state, and input availability:

```swift
for await status in await runtime.statusUpdates(conversationId: conversationId) {
    if case let .blocked(reason) = status.inputAvailability {
        showWaitingState(reason)
    }
}
```

Status snapshots also include `isTurnActive`, the provider process identifier, whether the process is running, and whether
cancellation is currently meaningful. Hosts that support mid-turn steering should use `isTurnActive` to distinguish a
normal message that should queue from an explicit steering action, because `inputAvailability` can remain available while
the provider is still completing a tool-backed turn. Use `cancel`, `reconfigure`, `freshSession`, `destroy`, and `shutdown`
for app-shell lifecycle actions.

## Resolve Interactions

When a provider interaction owns the turn, `send(.userMessage(...))` throws a typed `invalidInput` error. Resolve the interaction instead:

```swift
try await runtime.resolveInteraction(
    AgentInteractionResolution(
        id: interactionId,
        outcome: .answered,
        responseText: "Use the API"
    ),
    conversationId: conversationId
)
```

Resolution is idempotent for a runtime conversation, so duplicate UI actions do not send duplicate provider input.

## Provider Setup

Claude-specific config, setup, MCP bridging, hook approval, and stream decoding live under `Claude/`. Codex-specific App
Server transport, `.codex` config, setup, MCP bridging, approval mapping, and protocol decoding live under `Codex/`.
Generic host code should depend on `AgentRuntime`, `AgentProviderAdapter`, `AgentProviderSetup`, `AgentEventEnvelope`,
`AgentInput`, and provider-neutral store/service protocols.

Provider setup services prepare local provider config before launch. Claude setup can trust a project while preserving unrelated Claude config such as MCP servers:

```swift
let setup: any AgentProviderSetup = ClaudeProviderSetup(configFileURL: claudeConfigURL)
try await setup.trustProject(at: projectPath)
```

Codex setup writes Codex's documented user-level project trust table, separate from auth readiness. AgentCLIKit can report
inspectable credential material, but it does not trigger `codex login`:

```swift
let codexSetup = CodexProviderSetup(codexHomeDirectoryURL: codexHomeURL)
try await codexSetup.trustProject(at: projectPath)
let authReadiness = codexSetup.authReadiness()
```

`CodexConfigStore` can read/write user-level `~/.codex/config.toml` or project-level `.codex/config.toml`. Project config
should be loaded through `loadTrustedProjectConfig(for:)` when a host wants to mirror Codex behavior, because Codex ignores
project `.codex/` layers until the user-level config marks that project trusted.

Use `AgentProjectTrustService` when host UI needs provider-neutral project readiness. Cached status is synchronous and does not touch disk, while refreshed status can perform provider-specific config reads:

```swift
let trustService = DefaultAgentProjectTrustService(setups: [setup])
let cached = trustService.cachedStatus(providerId: .claude, projectURL: projectPath)
let refreshed = await trustService.status(providerId: .claude, projectURL: projectPath)
```

For host persistence, implement the provider-neutral store protocols instead of storing runtime internals. `AgentSessionStore`, `AgentInteractionStore`, and `AgentApprovalPolicyStore` are durable async boundaries that can be backed by SwiftData, SQLite, files, or another store. Session stores support reverse lookup and cleanup by provider session, provider, and canonical working directory. Live hook continuations, launch tokens, listener ports, and in-flight decision races remain internal to the runtime.

Thrown `AgentCLIError` values expose stable `code` and structured `metadata` so hosts can map failures without parsing
provider strings. Diagnostic events similarly include optional `AgentDiagnosticCode` values.

## Claude Hooks

`ClaudeProviderAdapter` can own Claude's local hook listener. `DefaultAgentRuntime` starts the loopback listener lazily, generates per-launch settings files and bearer tokens, invalidates launch tokens on teardown, and stops the listener from `shutdown()`:

```swift
await runtime.shutdown()
```

Claude hook approval state is explicit so hosts can share it with their own approval UI:

```swift
let approvalPolicyStore = ClaudeApprovalPolicyStore()
let hookServer = ClaudeHookServer(
    tokenStore: AgentHookTokenStore(),
    interactionStore: InMemoryAgentInteractionStore(),
    approvalPolicyStore: approvalPolicyStore
)

await approvalPolicyStore.approveForSession(operation: "Edit")
```

Hook policy handles `AskUserQuestion`, Bash/edit tools, MCP tools, `EnterPlanMode`, and `ExitPlanMode`. `EnterPlanMode` is allowed without creating a host interaction; `ExitPlanMode` is surfaced as a plan-mode approval.

Hosts can generate Claude hook settings for a local listener:

```swift
guard let hookEndpointURL = URL(string: "http://127.0.0.1:1234/claude/hooks/pre-tool-use") else {
    throw URLError(.badURL)
}

let settings = ClaudeHookSettings(endpointURL: hookEndpointURL)
let settingsData = try settings.encodedData()
```

Live decision providers are bounded by `decisionTimeout` and fall back to deferred hook responses if the host does not answer in time. `ClaudeProviderAdapter` accepts a live decision provider through `hookDecisionProvider` when hosts want app-native approval or prompt UI.

Claude-specific decisions can also carry response fields such as `updatedInput`:

```swift
let decision = ClaudeHookDecision.allow(updatedInput: .object([
    "questions": .array([
        .object(["question": .string("Proceed?")])
    ]),
    "answers": .object(["Proceed?": .string("Proceed")])
]))
```

## Inbox And Prompts

Pending approvals and prompts can be surfaced through `AgentInteractionInbox`:

```swift
let inbox = InMemoryAgentInteractionInbox(store: interactionStore)

for await actions in await inbox.subscribe(conversationId: conversationId) {
    render(actions)
}
```

Prompt questions support fixed options and custom responses:

```swift
let answer = AgentPromptAnswer(
    interactionId: interactionId,
    responseText: "Use the public API",
    source: .customResponse
)
try await runtime.resolveInteraction(answer.resolution(), conversationId: conversationId)
```

## Provider UI Helpers

Provider readiness and selection UI can observe the registry:

```swift
for await readiness in await providerRegistry.readinessUpdates() {
    updateProviderPicker(readiness)
}
```

`AgentProviderDefinition` exposes executable candidates, version arguments, supported permission modes, effort levels, and
capability metadata for host settings. `AgentProviderDetector` resolves executables through absolute paths, `PATH`, common
shell init files, and standard install locations.

Transcript and metrics helpers provide renderable host projections:

```swift
let projections = AgentTranscriptProjector().project(envelopes)
let metrics = AgentConversationMetricsBuilder().build(from: envelopes)
```

Task-list helpers reduce provider task tools into stable snapshots for apps that render TODO/progress blocks:

```swift
var taskLists = AgentTaskListReducer()
let updatedSnapshots = taskLists.append(contentsOf: envelopes)
```

AgentCLIKit also provides provider-neutral MCP config stores, Claude and Codex MCP bridging, skill scanning/sync helpers,
model context-window caches, and context handoff prompt helpers. These primitives are host-neutral; apps still own settings
UI and project policy.

## Validation

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/lint.sh
./scripts/validate-package-consumer.sh
```

The build and test scripts pipe `xcodebuild` through `xcsift -f toon -w` when `xcsift` is installed.
`validate-package-consumer.sh` builds a temporary package that imports the library product from a fresh scratch/cache path
and also validates the demo product through SwiftPM.

Codex App Server validation fixtures live under `Tests/AgentCLIKitTests/Resources/CodexAppServer/`. They are sanitized
summaries of local `codex app-server` schema output and live protocol probes, not raw captures. Regenerate schema into a
scratch directory with `codex app-server generate-json-schema --out <scratch>` and
`codex app-server generate-ts --out <scratch>`, then run any live probes through the test redactor before committing.

Repo-local agent workflows live under `.agents`: capability skills in `.agents/skills` and flat review, audit, or check workflow files in `.agents/checks`.

## Demo App

Run the live Claude-backed macOS demo with:

```sh
./scripts/run-demo.sh
```

The demo builds and launches `AgentCLIKitDemo`. It lists persisted session records, lets you add sessions, renders live runtime output from Claude, observes runtime status snapshots, exposes cancellation while the provider process is active, and answers `AskUserQuestion` prompts through the live hook decision provider.

## License

AgentCLIKit is licensed under the [GNU General Public License v3.0](LICENSE.md).

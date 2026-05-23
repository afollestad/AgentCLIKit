# AgentCLIKit

AgentCLIKit is a Swift package for macOS apps that need to run local agent CLIs through a reusable, provider-neutral API.

The package is designed around a generic runtime that owns process launch, stdin/stdout coordination, event replay, provider sessions, and interaction resolution. Provider-specific behavior lives in provider folders such as `Claude/`, so future agents like Codex can add their own adapter, decoder, config, and hook support without changing the runtime core.

## Installation

Add AgentCLIKit as a Swift Package dependency:

```swift
.package(url: "https://github.com/afollestad/AgentCLIKit.git", branch: "main")
```

Then add the library product to your macOS target:

```swift
.product(name: "AgentCLIKit", package: "AgentCLIKit")
```

## Architecture

AgentCLIKit is split into provider-neutral subsystems and provider implementations:

- `Core`: shared event, input, usage, interaction, session, error, and utility types.
- `Runtime`: process lifecycle, stream pumping, event buffering, subscriptions, status, and input serialization.
- `Providers`: provider metadata, registry, detection, adapters, and shell helpers.
- `Sessions`: JSON and in-memory provider session stores.
- `Interactions`: approvals, app-native prompts, hook listener primitives, and interaction persistence.
- `Transcript`: provider-neutral transcript grouping driven by injected provider policy.
- `Context`: context-window cache and context-handoff prompt helpers.
- `MCP`: provider-agnostic MCP server management.
- `Skills`: provider skill-directory scanning and sync helpers.
- `Claude`: Claude Code adapter, config, hooks, approval policy, MCP bridge, and stream decoding.

Host apps own UI state, persistence, drafts, notifications, and queueing policy. AgentCLIKit owns the runtime mechanics and emits provider-neutral events that the host can persist or render however it wants.

## Runtime Shape

The intended host integration uses one runtime actor per app-level runtime service:

```swift
let runtime = DefaultAgentRuntime(
    adapters: [
        ClaudeProviderAdapter()
    ],
    sessionStore: JSONFileAgentSessionStore(fileURL: sessionsURL)
)

try await runtime.spawn(
    conversationId: conversationId,
    config: AgentSpawnConfig(
        providerId: "claude",
        workingDirectory: projectPath,
        model: nil,
        effort: nil,
        initialPrompt: nil
    )
)

let subscription = await runtime.subscribe(
    conversationId: conversationId,
    afterIndex: lastPersistedEventIndex
)
```

Subscriptions yield indexed event envelopes. The host persists what it needs and acknowledges only after its own save succeeds:

```swift
for await envelope in subscription.events {
    persist(envelope)
    await runtime.markPersisted(
        conversationId: conversationId,
        generation: envelope.generation,
        upTo: envelope.index
    )
}
```

Output arrives as provider-neutral `AgentEvent` values, including complete messages, streaming `messageDelta` chunks, reasoning/thinking events, tool calls and results, typed usage, rate-limit state, permission mode, task/sub-agent, session-continuity, diagnostics, lifecycle, and interaction requests. Message and tool events include metadata dictionaries for provider details such as parent tool identifiers, sub-agent callers, and tool result flags.

Input also flows through the runtime:

```swift
try await runtime.send(
    .userMessage(AgentMessageInput(text: "Implement the parser")),
    conversationId: conversationId
)
```

Provider adapters serialize input in their native format. Claude writes stream JSON; a future provider can write JSONL, plain text, or use another bridge while sharing the same host-facing API.

Claude-specific config, setup, MCP bridging, hook approval, and stream decoding APIs live under the `Claude` source folder and use names such as `ClaudeConfigStore`, `ClaudeProviderSetup`, `ClaudeMCPBridge`, `ClaudeHookServer`, and `ClaudeStreamDecoder`. Generic host-facing code should depend on `AgentRuntime`, `AgentProviderAdapter`, `AgentProviderSetup`, `AgentEventEnvelope`, `AgentInput`, and the provider-neutral store/service protocols.

Provider setup services prepare local provider config before launch. Claude setup can trust a project while preserving unrelated Claude config such as MCP servers:

```swift
let setup: any AgentProviderSetup = ClaudeProviderSetup(configFileURL: claudeConfigURL)
try await setup.trustProject(at: projectPath)
```

`ClaudeProviderAdapter` owns Claude's local hook listener when hooks are enabled. `DefaultAgentRuntime` drives the provider
lifecycle, so Claude starts a loopback listener lazily, generates per-launch `--settings` files and bearer tokens, invalidates
launch tokens on teardown, and stops the listener from `shutdown()`:

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

Live decision providers are bounded by `decisionTimeout` and fall back to deferred hook responses if the host does not answer in
time. The default decision timeout is shorter than the generated Claude hook transport timeout so a defer response can be returned
before Claude closes the request.

`ClaudeProviderAdapter` accepts the same live decision provider through `hookDecisionProvider` when hosts want the adapter-managed
hook server to hold Claude's `PreToolUse` request open for app-native approval or prompt UI.

Hosts can generate Claude hook settings for their local listener from the same matcher used by the hook APIs:

```swift
guard let hookEndpointURL = URL(string: "http://127.0.0.1:1234/claude/hooks/pre-tool-use") else {
    throw URLError(.badURL)
}

let settings = ClaudeHookSettings(
    endpointURL: hookEndpointURL
)
let settingsData = try settings.encodedData()
```

Live Claude hook decisions can also carry Claude-specific response fields, such as `updatedInput` for tools that need echoed or augmented input:

```swift
let decision = ClaudeHookDecision.allow(updatedInput: .object([
    "questions": .array([
        .object(["question": .string("Proceed?")])
    ]),
    "answers": .object(["Proceed?": .string("Proceed")])
]))
```

## Validation

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/lint.sh
```

The build and test scripts pipe `xcodebuild` through `xcsift -f toon -w` when `xcsift` is installed.

Repo-local agent workflows live under `.agents`: capability skills in `.agents/skills` and flat review, audit, or check workflow files in `.agents/checks`.

## Demo App

Run the live Claude-backed macOS demo with:

```sh
./scripts/run-demo.sh
```

The demo builds and launches the `AgentCLIKitDemo` executable target. It lists persisted AgentCLIKit session records, lets you add sessions, renders live runtime output from Claude, and answers `AskUserQuestion` prompts through AgentCLIKit's live hook decision provider.

## License

AgentCLIKit is licensed under the [GNU General Public License v3.0](LICENSE.md).

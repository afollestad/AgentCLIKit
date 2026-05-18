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
- `Providers`: provider metadata, registry, detection, setup contracts, and shell helpers.
- `Sessions`: JSON and in-memory provider session stores.
- `Interactions`: approvals, app-native prompts, hook listener primitives, and interaction persistence.
- `Transcript`: provider-neutral transcript grouping driven by injected provider policy.
- `Context`: context-window cache and context-handoff prompt helpers.
- `MCP`: provider-agnostic MCP server management.
- `Skills`: provider skill-directory scanning and sync helpers.
- `Claude`: Claude Code adapter, config, hooks, approval policy, MCP bridge, and model metadata.

Host apps own UI state, persistence, drafts, notifications, and queueing policy. AgentCLIKit owns the runtime mechanics and emits provider-neutral events that the host can persist or render however it wants.

## Runtime Shape

The intended host integration uses one runtime actor per app-level runtime service:

```swift
let runtime = DefaultAgentRuntime(...)

try await runtime.spawn(
    conversationId: conversationId,
    config: AgentSpawnConfig(
        providerId: "claude",
        workingDirectory: projectPath,
        permissionMode: "default",
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
        generation: subscription.generation,
        upTo: envelope.index
    )
}
```

Input also flows through the runtime:

```swift
try await runtime.send(
    .userMessage(AgentMessageInput(text: "Implement the parser")),
    conversationId: conversationId
)
```

Provider adapters serialize input in their native format. Claude writes stream JSON; a future provider can write JSONL, plain text, or use another bridge while sharing the same host-facing API.

## Validation

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/lint.sh
```

The build and test scripts pipe `xcodebuild` through `xcsift -f toon -w` when `xcsift` is installed.

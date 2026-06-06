# Provider Reference

This page keeps provider-specific details out of the main README. Host-facing APIs should still be written against the
provider-neutral runtime, event, setup, and discovery protocols wherever possible.

## Runtime Boundaries

Generic runtime, event, session, interaction, transcript, MCP, skills, and provider-detection code lives outside
provider-specific folders. Claude-specific behavior lives under `Sources/AgentCLIKit/Claude/`. Codex-specific behavior
lives under `Sources/AgentCLIKit/Codex/`.

Host apps should generally depend on:

- `AgentRuntime`
- `AgentSpawnConfig`
- `AgentCollaborationMode`
- `AgentEventEnvelope`
- `AgentEvent`
- `AgentInput`
- `AgentInteractionResolution`
- `AgentProviderDiscoveryService`
- `AgentProviderSetup`
- `AgentSessionStore`

Provider adapters own native launch, input encoding, output decoding, session ID extraction, interaction resolution
encoding, and native in-place reconfiguration when a provider can apply an `AgentSpawnConfig` without replacement.

`AgentSpawnConfig` is the host-facing settings source of truth. `permissionMode` represents approval policy only.
Provider-neutral plan/default state lives in `collaborationMode`: `.plan` enters plan mode, `.default` leaves plan mode,
and `nil` means the host is not overriding collaboration state. `runtime.reconfigure(conversationId:config:)` returns
`.appliedInPlace`, `.restarted`, or `.nextTurnRequired`; active turns are never mutated in place and should receive staged
settings before the next turn.

## Capability Summary

Inspect `AgentProviderDefinition.capabilities` before showing provider-specific UI.

| Capability area | Claude | Codex |
| --- | --- | --- |
| Runtime events | Supported | Supported |
| Session resume | Supported | Supported |
| Mid-turn steering | Supported when provider allows it | Supported through App Server `turn/steer` |
| Tool events | Supported | Supported |
| Usage/context reporting | Supported | Supported |
| Task and todo events | Supported | Supported |
| Prompt requests | Supported through hooks and stream events | Supported through App Server requests |
| Approvals | Supported through hooks | Supported through App Server requests |
| Plan/default collaboration | `AgentSpawnConfig.collaborationMode`; Claude maps plan to internal `--permission-mode plan` | `AgentSpawnConfig.collaborationMode`; requires a concrete model |
| Runtime reconfigure | Process replacement or resume path | Idle threads use `thread/settings/update`; active turns require next-turn staging |
| Context compaction | Supported through hooks and stream frames | Supported through App Server notifications and items |
| MCP | Supported | Supported |
| Native archive | No provider-native action; validated no-op | `thread/archive` and `thread/unarchive` |

## Claude

Claude support uses Claude CLI stream JSON over stdin/stdout. `ClaudeProviderAdapter` owns launch flags, input encoding,
stream decoding, hook listener setup, hook-token invalidation, and interaction resolution.

Claude setup uses `ClaudeProviderSetup` and `ClaudeConfigStore` to manage user `.claude.json` project trust while
preserving unrelated config such as MCP servers.

Claude hooks are Claude-specific. Codex does not use the Claude hook listener or hook settings.

Plan mode is enabled through `AgentSpawnConfig.collaborationMode`, not by selecting `"plan"` as a host approval policy.
When `collaborationMode == .plan`, Claude launches or resumes with effective `--permission-mode plan` even if a different
approval `permissionMode` is selected. When collaboration mode is `.default` or `nil`, Claude uses the selected non-plan
permission mode. Claude may still report internal `"plan"` permission status; AgentCLIKit translates that to
`AgentEvent.collaborationMode` so hosts can clear plan UI after `ExitPlanMode` succeeds.

The hook flow covers:

- Tool approvals for Bash/edit tools and MCP tools.
- `AskUserQuestion` prompt requests.
- `EnterPlanMode` and `ExitPlanMode`.
- `PreCompact` and `PostCompact` context compaction lifecycle hooks.
- Optional live decisions through `ClaudeHookDecisionProvider`.
- Deferred responses when the host does not answer before `decisionTimeout`.

Compact hook responses always continue so AgentCLIKit does not block Claude compaction. The runtime correlates hook and
stdout compaction signals so consumers receive stable `AgentEvent.contextCompaction` start and terminal phases.

Claude model options come from `ClaudeModelOptionSource`.

## Codex

Codex support uses Codex App Server JSON-RPC. `CodexProviderAdapter` starts the App Server lazily for Codex runtime work,
initializes it, starts or resumes a thread, persists the Codex thread ID as the provider session ID, and sends user turns
through `turn/start`.

Codex uses the same `AgentSpawnConfig.collaborationMode` API. `turn/start` and idle-thread `thread/settings/update`
share the same sticky settings payload for `cwd`, `model`, `approvalPolicy`, `effort`, and `collaborationMode`. If a
started thread is idle, `runtime.reconfigure` applies those settings in place and updates future turns. If a turn is active,
it returns `.nextTurnRequired` so the host can stage the config for the next turn. During bootstrap or resume, settings that
`thread/start` cannot carry, especially collaboration mode, are applied before an initial prompt turn starts.

Codex collaboration-mode payloads require a concrete `AgentSpawnConfig.model`. Hosts that use live Codex model options
should pass the selected `AgentModelOption.model` before enabling plan mode.

Codex runtime cancellation maps to `turn/interrupt` when Codex reports an active turn. Mid-turn user input uses
`turn/steer`.

Codex setup uses `CodexProviderSetup` and `CodexConfigStore` for user-level `~/.codex/config.toml` project trust. Project
`.codex/config.toml` should be loaded through `loadTrustedProjectConfig(for:)` when a host wants to mirror Codex behavior,
because Codex ignores project `.codex/` layers until the user-level config marks that project trusted.

Codex auth readiness is separate from project trust. `CodexProviderSetup.authReadiness()` and `CodexAuthProbe` report
credential-source presence without exposing token contents and without triggering `codex login`.

Codex App Server requests map into provider-neutral interactions:

- Command execution approvals.
- File-change approvals.
- Permission profile prompts.
- MCP elicitation.
- User-input requests.

Codex emits provider-neutral events for messages, reasoning, tool calls/results, diffs, usage, context-window metadata,
context compaction, tasks/todos, sub-agent activity, permission-mode changes, collaboration-mode changes, diagnostics,
and lifecycle.

Host-defined Codex custom tool execution is not a v1 host API.

## Model Options

`AgentModelOption` is the host-facing model metadata type. Use:

- `model` for the value passed into `AgentSpawnConfig.model`.
- `label` and `description` for UI.
- `contextWindowSize` when available.
- `supportedEffortOptions` to decide whether to show effort controls.
- `defaultEffortOption` for the model-specific default.

`DefaultAgentModelOptionSource` uses `ClaudeModelOptionSource` for Claude. For Codex, it returns a static provider-default
fallback unless the host injects a Codex source:

```swift
let source = DefaultAgentModelOptionSource(
    codexSource: CodexAppServerModelOptionSource()
)
```

`CodexAppServerModelOptionSource` queries App Server `model/list` on demand, caches results briefly, and falls back to
static options when live listing fails or returns no models. It starts a temporary App Server transport only when called
with a missing or expired cache.

## Context Compaction

Both built-in providers expose context compaction as `AgentEvent.contextCompaction`.

`AgentContextCompactionEvent.phase` is one of:

- `.started`
- `.completed`
- `.failed`

The runtime deduplicates repeated `id` plus phase pairs. If a provider reports only a terminal phase, the runtime emits a
synthetic `.started` first. If a provider process is cancelled or exits after a compaction start without a terminal phase,
the runtime emits a synthetic failed compaction so host UI can replace in-progress state.

## Sessions And Archive

`AgentSessionStore` stores provider session mappings keyed by host conversation and provider. `JSONFileAgentSessionStore`
is useful for small apps and examples; production apps can back the protocol with files, SQLite, app databases, or another
durable store.

`AgentProviderSessionActionRouter` pairs host archive UI with provider-native actions. Codex archive/unarchive uses App
Server `thread/archive` and `thread/unarchive`. Claude validates matching session records and no-ops because the Claude
CLI does not expose native archive actions.

## MCP And Skills

AgentCLIKit includes provider-neutral MCP config stores, provider-specific MCP bridges for Claude and Codex, and skill
directory scanning/sync helpers. These primitives are host-neutral. Apps still own settings UI, enablement policy, and how
MCP or skill state is presented to users.

## Diagnostics And Errors

Thrown `AgentCLIError` values expose stable `code` and structured `metadata` so hosts can map failures without parsing
provider strings. Diagnostic events can include `AgentDiagnosticCode` values for provider stderr, decoder failures, setup
problems, and session persistence failures.

Provider-specific metadata remains available on events for hosts that need richer rendering, but generic UI should prefer
provider-neutral fields first.

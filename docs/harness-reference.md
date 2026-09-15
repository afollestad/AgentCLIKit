# Harness Reference

This page keeps harness-specific details out of the main README. Host-facing APIs should still be written against the
harness-neutral runtime, event, setup, and discovery protocols wherever possible.

## Runtime Boundaries

Generic runtime, event, session, interaction, transcript, MCP, skills, and harness-detection code lives outside
harness-specific folders. Claude-specific behavior lives under `Sources/AgentCLIKit/Claude/`. Codex-specific behavior
lives under `Sources/AgentCLIKit/Codex/`.

Host apps should generally depend on:

- `AgentRuntime`
- `AgentSpawnConfig`
- `AgentOneShotPromptRunning`
- `AgentCollaborationMode`
- `AgentSpeedMode`
- `AgentEventEnvelope`
- `AgentEvent`
- `AgentInput`
- `AgentInteractionResolution`
- `AgentHarnessDiscoveryService`
- `AgentHarnessSetup`
- `AgentSessionStore`
- `AgentHostToolDefinition`
- `AgentHostToolHandling`

Harness adapters own native launch, input encoding, output decoding, session ID extraction, interaction resolution
encoding, and native in-place reconfiguration when a harness can apply an `AgentSpawnConfig` without replacement.

Sessionless project-level prompts use `AgentOneShotPromptRunning` instead of `AgentRuntime`. They return one final
assistant message, do not create AgentCLIKit runtime state, and do not service approvals or harness prompts.

Reusable approval scopes are harness-neutral. Hosts can back `AgentSessionApprovalPolicyStore` with app persistence, and
Bash approval requests may include canonical `approvalIdentityToolInput` derived by `AgentCommandApprovalNormalizationPolicy`.
That identity is used for exact/group matching while raw harness input remains available for execution and resolution.

`AgentSpawnConfig` is the host-facing settings source of truth. `permissionMode` represents approval policy only.
Harness-neutral plan/default state lives in `collaborationMode`: `.plan` enters plan mode, `.default` leaves plan mode,
and `nil` means the host is not overriding collaboration state. `runtime.reconfigure(conversationId:config:)` returns
`.appliedInPlace`, `.restarted`, or `.nextTurnRequired`; active turns are never mutated in place and should receive staged
settings before the next turn.

Harness-neutral speed lives in `speedMode`: `.fast` requests faster harness behavior, `.standard` requests normal
behavior, and `nil` means the host is not overriding speed. Inspect
`AgentHarnessCapabilities.supportsSpeedMode` before showing or sending `.fast`.

Harness-neutral local image input lives in `AgentMessageInput.attachments`. Setup sends can carry the same data through
`AgentSpawnConfig.initialPromptAttachments` and `initialPromptMetadata`. Inspect
`AgentHarnessCapabilities.supportsLocalImageInput` before staging image attachments; unsupported harnesses throw
`AgentCLIError.unsupportedInputAttachment` instead of rewriting the prompt. Typed or pasted Markdown image links are
ordinary text from AgentCLIKit's perspective.

Harness-neutral session forks live in `sessionFork`. Hosts create a new conversation with the target
`workingDirectory`, set `sessionFork.sourceSessionId` to the source harness session, and copy host transcript rows only
for UI continuity. Harness context comes from the native fork request, not from replaying copied host records.

## Capability Summary

Inspect `AgentHarnessDefinition.capabilities` before showing harness-specific UI.

| Capability area | Claude | Codex |
| --- | --- | --- |
| Runtime events | Supported | Supported |
| Session resume | Supported | Supported |
| Mid-turn steering | Supported when harness allows it | Supported through App Server `turn/steer` |
| Tool events | Supported | Supported |
| Usage/context reporting | Supported | Supported |
| Task and todo events | Supported | Supported |
| Prompt requests | Supported through hooks and stream events | Supported through App Server requests |
| Approvals | Supported through hooks | Supported through App Server requests |
| Plan/default collaboration | `AgentSpawnConfig.collaborationMode`; Claude maps plan to internal `--permission-mode plan` | `AgentSpawnConfig.collaborationMode`; requires a concrete model |
| Speed mode | Not supported; Claude's fast-like `--bare` path disables hooks | `AgentSpawnConfig.speedMode` when Codex reports `fast_mode` support |
| Local image input | Not supported; send image references as prompt text when desired | Supported through App Server `localImage` user input |
| Runtime reconfigure | Process replacement or resume path | Idle threads use `thread/settings/update`; active turns require next-turn staging |
| Host tools and roots | Inline process-scoped MCP config plus `--add-dir` | Thread-scoped MCP config plus `runtimeWorkspaceRoots` |
| Context compaction | Supported through hooks and stream frames | Supported through App Server notifications and items |
| MCP | Supported | Supported |
| Native fork | `--resume <source> --fork-session`; source artifact must exist | `thread/fork` |
| Native archive/delete | No harness-native action; validated no-op | `thread/archive`, `thread/unarchive`, and `thread/delete` |

## Claude

Claude support uses Claude CLI stream JSON over stdin/stdout. `ClaudeHarnessAdapter` owns launch flags, input encoding,
stream decoding, hook listener setup, hook-token invalidation, and interaction resolution.

Claude one-shot prompts use `claude -p --safe-mode --no-session-persistence --output-format stream-json --input-format text
--verbose` with `--tools Read,Grep,Glob,LS`. The runner normalizes legacy default model values through
`ClaudeModelAliases`, so omitted or `"default"` models launch as `sonnet` rather than whatever the local Claude CLI default
currently is.

Claude setup uses `ClaudeHarnessSetup` and `ClaudeConfigStore` to manage user `.claude.json` project trust while
preserving unrelated config such as MCP servers.

Claude hooks are Claude-specific. Codex does not use the Claude hook listener or hook settings.

Plan mode is enabled through `AgentSpawnConfig.collaborationMode`, not by selecting `"plan"` as a host approval policy.
When `collaborationMode == .plan`, Claude launches or resumes with effective `--permission-mode plan` even if a different
approval `permissionMode` is selected. When collaboration mode is `.default` or `nil`, Claude uses the selected non-plan
permission mode. Claude may still report internal `"plan"` permission status; AgentCLIKit translates that to
`AgentEvent.collaborationMode` so hosts can clear plan UI after `ExitPlanMode` succeeds.

Claude permission modes are `default`, `acceptEdits`, `auto`, and `bypassPermissions`. `bypassPermissions` is a dangerous
mode that bypasses all permission checks; AgentCLIKit launches it with `--allow-dangerously-skip-permissions` plus
`--permission-mode bypassPermissions`. If Claude reports the legacy `dontAsk` alias, AgentCLIKit emits the host-facing
permission mode as `bypassPermissions`.

The hook flow covers:

- Tool approvals for Bash/edit tools and MCP tools.
- `AskUserQuestion` prompt requests.
- `EnterPlanMode` and `ExitPlanMode`.
- `PreCompact` and `PostCompact` context compaction lifecycle hooks.
- Optional live decisions through `ClaudeHookDecisionProviding`.
- Deferred responses when the host does not answer before `decisionTimeout`.

Hosts restarting a deferred approval without a new prompt pass `resumingTurn: true` to
`DefaultAgentRuntime.spawn(conversationId:config:resumingTurn:)` so runtime status stays active until the resumed turn ends.

Compact hook responses always continue so AgentCLIKit does not block Claude compaction. The runtime correlates hook and
stdout compaction signals so consumers receive stable `AgentEvent.contextCompaction` start and terminal phases.

Claude model options come from `ClaudeModelOptionSource`.

Claude speed mode is intentionally unsupported. The Claude CLI exposes `--bare`, but that disables hooks and other host
integration surfaces, so AgentCLIKit does not map it to `AgentSpeedMode.fast`.

Claude input transport is text-only. If a host wants Claude to see a local image path, include that reference in the
prompt text and grant filesystem access through Claude launch arguments when needed; do not send it as an
`AgentInputAttachment`.

Claude forks use `AgentSpawnConfig.sessionFork` to locate the source session artifact and launch the target process with
`--resume <source> --fork-session` from the target `workingDirectory`. Worktree forks should pass the source working
directory when it differs from the target.

## Codex

Codex support uses Codex App Server JSON-RPC. `CodexHarnessAdapter` starts the App Server lazily for Codex runtime work,
initializes it, starts or resumes a thread, persists the Codex thread ID as the harness session ID, and sends user turns
through `turn/start`. When Codex reports `Thread.name` or `Thread.preview` during bootstrap, resume, `thread/started`, or
thread metadata notifications, the adapter emits `AgentEvent.sessionMetadata`; the runtime mirrors normalized values into
`AgentRuntimeStatus.harnessSessionName`, `AgentRuntimeStatus.harnessSessionPreview`, `AgentSessionRecord.harnessSessionName`,
and `AgentSessionRecord.harnessSessionPreview`.

Codex one-shot prompts intentionally do not use Codex App Server. They run `codex exec --ephemeral --json --sandbox
read-only -c 'approval_policy="never"' -C <cwd> -` and parse the final `agent_message` from stdout JSONL. Codex can still
emit a transient `thread.started` event in that stream; the sessionless contract is that no harness thread is persisted.

Codex uses the same `AgentSpawnConfig.collaborationMode` API. `turn/start` and idle-thread `thread/settings/update`
share the same sticky settings payload for `cwd`, `model`, `approvalPolicy`, `effort`, `collaborationMode`, and
`speedMode`. If a
started thread is idle, `runtime.reconfigure` applies those settings in place and updates future turns. If a turn is active,
it returns `.nextTurnRequired` so the host can stage the config for the next turn. During bootstrap or resume, settings that
`thread/start` cannot carry, especially collaboration mode, are applied before an initial prompt turn starts.

Codex collaboration-mode payloads require a concrete `AgentSpawnConfig.model`. Hosts that use live Codex model options
should pass the selected `AgentModelOption.model` before enabling plan mode.

Codex fast mode is gated by `codex features list`. `DefaultAgentHarnessDiscoveryService` overlays
`supportsSpeedMode == true` for Codex only when the configured executable reports a `fast_mode` row. Discovery uses this
short-lived CLI probe rather than starting App Server. Runtime requests use per-thread config
`config.features.fast_mode`; AgentCLIKit does not call App Server `experimentalFeature/enablement/set` and does not launch
App Server with global `--enable fast_mode`.

Codex runtime cancellation maps to `turn/interrupt` when Codex reports an active turn. Mid-turn user input uses
`turn/steer`.

Codex local image attachments encode as App Server `localImage` user input items after the text item on both `turn/start`
and `turn/steer`. Mark app-shot inputs with `CodexInputMetadata.isAppshot`; AgentCLIKit reads
`configRequirements/read.requirements.allowAppshots` before sending those marked inputs and blocks only when the managed
requirement is explicitly `false`. Ordinary local image attachments are not blocked by app-shot policy.

Codex forks use App Server `thread/fork` with the source `threadId` plus target settings accepted by `ThreadForkParams`,
including `cwd`, `model`, approval policy, and config. Failed fork cleanup can delete unbound target threads with
`thread/delete`.

Codex setup uses `CodexHarnessSetup` and `CodexConfigStore` for user-level `~/.codex/config.toml` project trust. Project
`.codex/config.toml` should be loaded through `loadTrustedProjectConfig(for:)` when a host wants to mirror Codex behavior,
because Codex ignores project `.codex/` layers until the user-level config marks that project trusted.

Codex auth readiness is separate from project trust. `CodexHarnessSetup.authReadiness()` and `CodexAuthProbe` report
credential-source presence without exposing token contents and without triggering `codex login`.

Codex App Server requests map into harness-neutral interactions:

- Command execution approvals.
- File-change approvals.
- Permission profile prompts.
- MCP elicitation.
- User-input requests.

Codex emits harness-neutral events for messages, reasoning, tool calls/results, diffs, usage, context-window metadata,
session metadata, context compaction, tasks/todos, typed sub-agent lifecycle, permission-mode changes,
collaboration-mode changes, diagnostics, and lifecycle.

Host-defined Codex custom tool execution is not a v1 host API.

## Usage Accounting

`AgentUsageEvent.cacheReadInputTokens` and `cacheCreationInputTokens` are additive input-side token counts, used by
harnesses such as Claude when those token classes are reported separately from `inputTokens`.

`AgentUsageEvent.cachedInputTokens` is different: it is a non-additive subset of `inputTokens`. Codex App Server reports
`cachedInputTokens` this way, so host apps should display it as cache detail but should not add it to `inputTokens` when
computing context-window occupancy.

## Model Options

`AgentModelOption` is the host-facing model metadata type. Use:

- `model` for the value passed into `AgentSpawnConfig.model`.
- `label` and `description` for UI.
- `shortName` for typed input such as a host slash command; it is a harness-defined alias (`opus`, `sol`) that falls back
  to `id` when the harness has no unambiguous alias. Do not derive short names host-side.
- `contextWindowSize` when available.
- `supportedEffortOptions` to decide whether to show effort controls.
- `defaultEffortOption` for the model-specific default.

`DefaultAgentModelOptionSource` uses `ClaudeModelOptionSource` for Claude. For Codex, it returns a static harness-default
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

Both built-in harnesses expose context compaction as `AgentEvent.contextCompaction`.

`AgentContextCompactionEvent.phase` is one of:

- `.started`
- `.completed`
- `.failed`

The runtime deduplicates repeated `id` plus phase pairs. If a harness reports only a terminal phase, the runtime emits a
synthetic `.started` first. If a harness process is cancelled or exits after a compaction start without a terminal phase,
the runtime emits a synthetic failed compaction so host UI can replace in-progress state.

## Task Lists

Harnesses that report `supportsTaskLists` can emit task-list state through `AgentTaskListSnapshot`.
`AgentTaskListItem.Status` values are `pending`, `in_progress`, `completed`, and `interrupted`. `interrupted` is terminal
for the stopped work, but later harness updates may move the same task back to another status if work restarts.

## Sessions And Archive

`AgentSessionStore` stores harness session mappings keyed by host conversation and harness. `JSONFileAgentSessionStore`
is useful for small apps and examples; production apps can back the protocol with files, SQLite, app databases, or another
durable store. Harnesses may also report a user-facing session name or preview through `AgentEvent.sessionMetadata`; when
usable, the runtime stores them in `AgentSessionRecord.harnessSessionName` and `AgentSessionRecord.harnessSessionPreview`
and publishes them in `AgentRuntimeStatus.harnessSessionName` and `AgentRuntimeStatus.harnessSessionPreview`. A harness
name is the authoritative visible title; preview is a fallback for sessions that do not yet have a name. For harnesses that
do not report a native preview, AgentCLIKit generates one from a usable initial prompt with
`AgentSessionPreviewGenerator.preview(fromInitialPrompt:)`.

`AgentHarnessSessionActionRouter` pairs host archive UI with harness-native actions. Codex archive/unarchive uses App
Server `thread/archive` and `thread/unarchive`. Claude validates matching session records and no-ops because the Claude
CLI does not expose native archive actions.

Hosts with a running harness runtime should construct the router with `init(borrowing:)` and pass the same adapter set
used by the runtime. Session actions then reach the server holding the thread's writer lock without shutting down shared
adapters. The default and factory initializers own fresh adapters and shut them down after each action.

## MCP And Skills

AgentCLIKit includes harness-neutral MCP config stores, harness-specific MCP bridges for Claude and Codex, and skill
directory scanning/sync helpers. These primitives are host-neutral. Apps still own settings UI, enablement policy, and how
MCP or skill state is presented to users.

Host-owned runtime tools are separate from persisted harness MCP configuration. A host supplies Codable
`AgentHostToolDefinition` values through `AgentSpawnConfig.hostTools`, a configurable generic server name/instructions
through `hostToolServer`, and an `AgentHostToolHandling` dispatcher when constructing `DefaultAgentRuntime`. Calls receive
trusted conversation, harness, process, and JSON-RPC request identity from the runtime; model arguments never supply
those fields. The SDK advertises input schemas, but host handlers remain responsible for strict argument decoding and
product authorization.

Each host-tool harness launch gets a unique bearer token and opaque route on one IPv4 loopback listener. Claude receives inline
HTTP MCP configuration and token environment interpolation for its individual process. Codex receives a dotted
`mcp_servers.<server>` override and static authorization header on its App Server thread because the App Server process is
shared. Neither path rewrites the user's global MCP config. Empty tools preserve prior launch behavior; configured tools
without handling fail explicitly. Additional roots are canonicalized and launch-only. Reconfiguration restarts an idle
process or returns `.nextTurnRequired` while work is active.

If the loopback listener stops after launch, the runtime retires every affected registration and emits an
`.hostToolServerUnavailable` error diagnostic with `replacement_required` metadata for each affected conversation.

For Codex, an empty `additionalWorkspaceRoots` list omits the experimental App Server override and preserves Codex's
native workspace roots. A nonempty list is an exact replacement containing canonical `cwd + grants`; it intentionally
supersedes roots from the user's Codex configuration and requires Codex 0.144.0 or newer with experimental APIs enabled.
Pass only the working directory in the list to opt into a `cwd`-only replacement that clears user-configured extra roots.
Resuming with an explicit root override forks the prior thread to preserve history while applying the roots, even without
host tools. This also applies after suspension; an ordinary resume could leave the loaded thread's previous grants active.

## Diagnostics And Errors

Thrown `AgentCLIError` values expose stable `code` and structured `metadata` so hosts can map failures without parsing
harness strings. Diagnostic events can include `AgentDiagnosticCode` values for harness stderr, decoder failures, setup
problems, and session persistence failures.

Harness-specific metadata remains available on events for hosts that need richer rendering, but generic UI should prefer
harness-neutral fields first.

## Codex Provider

- Keep Codex App Server launch details, JSON-RPC/App Server wire formats, `.codex` config behavior, permission-profile handling, model-list parsing/cache behavior, and Codex-specific policies here.
- Keep provider-neutral runtime, session, event, interaction, transcript, MCP, usage, diagnostics, and discovery APIs outside this folder.
- Use the Codex App Server protocol fixture before adding or changing request, notification, or approval behavior.
- Do not start a Codex App Server process from provider discovery or static provider metadata.
- Keep live Codex `model/list` usage behind explicit model option sources; default provider discovery must not launch App Server unless a host injects a live Codex source.
- `CodexProviderAdapter` owns one shared App Server transport per adapter instance; keep startup lazy and stop it from provider resource shutdown.
- Surface Codex `Thread.name` and `Thread.preview` from bootstrap/resume and thread metadata notifications as provider-neutral `AgentEvent.sessionMetadata`.
- Keep `turn/start` and `thread/settings/update` sticky settings in one shared builder for `cwd`, `model`, `approvalPolicy`, `effort`, `collaborationMode`, and `speedMode`.
- Probe fast-mode support with `codex features list`; do not start App Server from discovery and do not use App Server process-wide feature enablement for per-thread speed.
- Apply collaboration-mode bootstrap settings before an initial prompt turn; `thread/start` cannot carry every sticky setting.
- After successful in-place `thread/settings/update`, update the binding `spawnConfig` so later turns use the same settings.
- Return `.nextTurnRequired` instead of sending `thread/settings/update` while a turn is active.
- Require a concrete model before sending Codex collaboration-mode settings.
- Treat Codex permission-profile denial semantics as live-validated behavior; do not invent a decline enum for `item/permissions/requestApproval`.
- Treat `thread/compact/start` as a client request only; map `thread/compacted`, `contextCompaction` items, and raw response compaction aliases to `AgentEvent.contextCompaction`.
- Do not expose encrypted Codex compaction payloads as transcript summaries.
- Map Codex `cachedInputTokens` to `AgentUsageEvent.cachedInputTokens`, not `cacheReadInputTokens`; it is a subset of `inputTokens` and must not be added again for context-window occupancy.

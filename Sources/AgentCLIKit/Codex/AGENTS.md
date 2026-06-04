## Codex Provider

- Keep Codex App Server launch details, JSON-RPC/App Server wire formats, `.codex` config behavior, permission-profile handling, model-list defaults, and Codex-specific policies here.
- Keep provider-neutral runtime, session, event, interaction, transcript, MCP, usage, diagnostics, and discovery APIs outside this folder.
- Use the Phase 3 protocol fixture before adding or changing Codex App Server request, notification, or approval behavior.
- Do not start a Codex App Server process from provider discovery or static provider metadata.
- Keep Codex `model/list` usage behind explicit model option sources; default provider discovery must stay cache/static and not launch App Server.
- `CodexProviderAdapter` owns one shared App Server transport per adapter instance; keep startup lazy and stop it from provider resource shutdown.
- Treat Codex permission-profile denial semantics as live-validated behavior; do not invent a decline enum for `item/permissions/requestApproval`.
- Treat `thread/compact/start` as a client request only; map `thread/compacted`, `contextCompaction` items, and raw response compaction aliases to `AgentEvent.contextCompaction`.
- Do not expose encrypted Codex compaction payloads as transcript summaries.

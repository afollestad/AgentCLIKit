## Claude Provider

- Keep Claude launch arguments, stream wire decoding, settings/trust config, hook server behavior, model defaults, and approval policies here.
- Keep provider-neutral runtime, session, event, hook-token, and interaction APIs outside this folder.
- Keep `--verbose` with `--output-format stream-json`; Claude structured streaming depends on it.
- Resume with `--resume` only when the canonical Claude session file exists; otherwise preserve continuity with `--session-id`.
- When invalidating a launch hook token, release live hook decision waits for that token with a deferred decision so teardown never waits for Claude's hook timeout.
- Seed generated-hook launches with the launch permission mode, and clear stale cached mode when a launch has no mode.
- Register `PreCompact` and `PostCompact` hooks independently from approval-hook gating; do not model compaction as a tool-use hook.
- If generated hook listener/settings prep fails, keep launching Claude without `--settings` instead of failing provider spawn solely because hooks are unavailable.
- `AskUserQuestion` deferred events should surface as `.prompt`, and `ExitPlanMode` deferred events as `.planModeExit`.
- Correlate Claude compact stdout and hook events with the process token so consumers see stable `contextCompaction` IDs for start and terminal phases.
- Keep live hook continuations, listener state, launch tokens, and decision races internal; persist only durable interaction/session/policy records through generic stores.
- `EnterPlanMode` should not create a host approval; `ExitPlanMode` should remain a host-resolved plan-mode approval.
- Hook approval interaction IDs must reuse Claude's `tool_use_id` / `toolUseId` / `toolUseID` when available; missing IDs need a stable fallback so retries can consume the same host decision.

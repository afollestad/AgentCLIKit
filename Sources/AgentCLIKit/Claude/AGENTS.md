## Claude Provider

- Keep Claude launch arguments, stream wire decoding, settings/trust config, hook server behavior, model defaults, and approval policies here.
- Keep provider-neutral runtime, session, event, hook-token, and interaction APIs outside this folder.
- Keep `--verbose` with `--output-format stream-json`; Claude structured streaming depends on it.
- Resume with `--resume` only when the canonical Claude session file exists; otherwise preserve continuity with `--session-id`.
- When invalidating a launch hook token, release live hook decision waits for that token with a deferred decision so teardown never waits for Claude's hook timeout.
- `AskUserQuestion` deferred events should surface as `.prompt`, and `ExitPlanMode` deferred events as `.planModeExit`.
- Keep live hook continuations, listener state, launch tokens, and decision races internal; persist only durable interaction/session/policy records through generic stores.
- `EnterPlanMode` should not create a host approval; `ExitPlanMode` should remain a host-resolved plan-mode approval.
- Hook approval interaction IDs must reuse Claude's `tool_use_id` / `toolUseId` / `toolUseID` when available; missing IDs need a stable fallback so retries can consume the same host decision.

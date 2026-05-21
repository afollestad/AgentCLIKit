## Claude Provider

- Keep Claude launch arguments, stream wire decoding, settings/trust config, hook server behavior, model defaults, and approval policies here.
- Keep provider-neutral runtime, session, event, hook-token, and interaction APIs outside this folder.
- Keep `--verbose` with `--output-format stream-json`; Claude structured streaming depends on it.
- Resume with `--resume` only when the canonical Claude session file exists; otherwise preserve continuity with `--session-id`.
- When invalidating a launch hook token, release live hook decision waits for that token with a deferred decision so teardown never waits for Claude's hook timeout.

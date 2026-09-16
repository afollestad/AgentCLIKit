## Documentation

- Keep documentation focused on durable behavior and usage; omit work tracking, validation histories, and commit hashes.
- Keep human-facing docs here synchronized with public runtime, config, event, harness capability, and validation behavior.
- Keep `README.md`, `docs/examples.md`, and `docs/harness-reference.md` aligned when documenting host-facing flows.
- Document plan mode through `AgentSpawnConfig.collaborationMode`; do not present `"plan"` as a host-selectable `permissionMode`.
- Document speed mode through `AgentSpawnConfig.speedMode`; describe fast support as harness-reported and currently Codex-only.
- Keep examples marked **Complete snippet** copy-paste safe without hidden harness preconditions.
- Prefer harness-neutral host guidance first, then isolate native harness differences where native behavior differs.

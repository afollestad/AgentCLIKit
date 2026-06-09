## Documentation

- Keep human-facing docs here synchronized with public runtime, config, event, provider capability, and validation behavior.
- Keep `README.md`, `docs/examples.md`, and `docs/provider-reference.md` aligned when documenting host-facing flows.
- Document plan mode through `AgentSpawnConfig.collaborationMode`; do not present `"plan"` as a host-selectable `permissionMode`.
- Document speed mode through `AgentSpawnConfig.speedMode`; describe fast support as provider-reported and currently Codex-only.
- Keep examples marked **Complete snippet** copy-paste safe without hidden provider preconditions.
- Prefer provider-neutral host guidance first, then isolate Claude and Codex differences where native behavior differs.

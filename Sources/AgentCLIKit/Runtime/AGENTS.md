## Runtime Replay

- **Suppress deferred-approval replay:** Non-fresh resumes after a deferred tool stop can replay provider transcript frames. Keep already-retained provider output from being emitted again to subscribers.
- **Treat replayed interaction IDs as volatile:** Deferred-approval resumes may replay approval, prompt, or plan-mode interaction frames with fresh `AgentInteractionID` values. Replay fingerprints should match on transcript-visible identity such as kind, prompt, session/tool metadata, tool input, and plan content; keep `resolvedInteractions` ID-based for live resolution/idempotence.
- **Preserve new output:** Replay suppression must end at the first genuinely new provider event, and matching content after that point must still be emitted.
- **Preserve compaction lifecycle:** Runtime compaction guards should deduplicate by `id` plus phase, synthesize a `started` event before terminal compaction events when providers omit the start, and synthesize a failed terminal event when a process is cancelled or exits with an open compaction.
- **Do not hide runtime events:** Lifecycle, session-continuity, diagnostics, and fresh-session output must remain visible.
- **Do not reopen resolved interactions:** Late or replayed provider interaction frames whose IDs already resolved must not emit new pending interaction events or return the runtime to a waiting state.
- **Tear down deferred stops gracefully:** On a deferred-tool stop, close stdin and let the provider exit on its own; force kill only after `deferredStopKillGraceNanoseconds`. An immediate kill races the provider's deferred-tool transcript writes, and a resume without that marker never re-runs the deferred tool.

## Reconfigure And Collaboration Mode

- **Keep `AgentSpawnConfig` authoritative:** Runtime reconfigure should pass the desired config to the provider hook first, then update `ConversationState.spawnConfig` only after in-place success or process replacement.
- **Respect active turns:** Providers that cannot mutate the current turn should return `.nextTurnRequired`; host apps are expected to stage the new config for the next turn.
- **Track collaboration separately:** Keep `collaborationMode` in runtime state/status and events separate from `permissionMode`, which is approval policy.
- **Keep speed provider-reported:** Hosts choose `AgentSpawnConfig.speedMode`, but provider support comes from `AgentProviderCapabilities.supportsSpeedMode`; do not add runtime speed status unless a provider starts reporting it natively.

## Process-Scoped Resources

- **Register before launch:** Create host-tool routes before context-aware provider launch so launch arguments never reference an unregistered endpoint.
- **Preserve cancellation ownership:** Destruction and shutdown may invalidate a suspended start early, but keep its tombstone until it resumes and performs final idempotent cleanup.
- **Detach before awaiting teardown:** Remove conversation state and finish subscribers before cleanup awaits so input, status, and output cannot reenter a conversation being destroyed.

## Validation

- Add or update focused runtime tests when changing process replacement, replay buffers, event cursors, deferred-tool stop handling, or interaction resolution.

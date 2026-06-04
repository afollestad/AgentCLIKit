## Runtime Replay

- **Suppress deferred-approval replay:** Non-fresh resumes after a deferred tool stop can replay provider transcript frames. Keep already-retained provider output from being emitted again to subscribers.
- **Preserve new output:** Replay suppression must end at the first genuinely new provider event, and matching content after that point must still be emitted.
- **Preserve compaction lifecycle:** Runtime compaction guards should deduplicate by `id` plus phase, synthesize a `started` event before terminal compaction events when providers omit the start, and synthesize a failed terminal event when a process is cancelled or exits with an open compaction.
- **Do not hide runtime events:** Lifecycle, session-continuity, diagnostics, and fresh-session output must remain visible.
- **Do not reopen resolved interactions:** Late or replayed provider interaction frames whose IDs already resolved must not emit new pending interaction events or return the runtime to a waiting state.

## Validation

- Add or update focused runtime tests when changing process replacement, replay buffers, event cursors, deferred-tool stop handling, or interaction resolution.

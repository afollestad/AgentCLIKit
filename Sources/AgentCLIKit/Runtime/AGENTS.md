## Runtime Replay

- **Suppress deferred-approval replay:** Non-fresh resumes after a deferred tool stop can replay harness transcript frames. Keep already-retained harness output from being emitted again to subscribers.
- **Treat replayed interaction IDs as volatile:** Deferred-approval resumes may replay approval, prompt, or plan-mode interaction frames with fresh `AgentInteractionID` values. Replay fingerprints should match on transcript-visible identity such as kind, prompt, session/tool metadata, tool input, and plan content; keep `resolvedInteractions` ID-based for live resolution/idempotence.
- **Preserve new output:** Replay suppression must end at the first genuinely new harness event, and matching content after that point must still be emitted.
- **Preserve compaction lifecycle:** Runtime compaction guards should deduplicate by `id` plus phase, synthesize a `started` event before terminal compaction events when harnesses omit the start, and synthesize a failed terminal event when a process is cancelled or exits with an open compaction.
- **Do not hide runtime events:** Lifecycle, session-continuity, diagnostics, and fresh-session output must remain visible.
- **Do not reopen resolved interactions:** Late or replayed harness interaction frames whose IDs already resolved must not emit new pending interaction events or return the runtime to a waiting state.
- **Tear down deferred stops gracefully:** On a deferred-tool stop, close stdin and let the harness exit on its own; force kill only after `deferredStopKillGraceNanoseconds`. An immediate kill races the harness's deferred-tool transcript writes, and a resume without that marker never re-runs the deferred tool.

## Background Tasks

- **Count background tasks separately from `isTurnActive`:** `BackgroundTaskTracking` owns the live set behind `AgentRuntimeStatus.liveBackgroundTaskCount`. Hosts use it to keep a process alive after a turn ends, so never fold it into turn state or clear it on turn end.
- **Keep a dropped task counted until its notification arrives:** Claude announces the shrunken live set before the notification and the follow-up turn; clearing on the announcement alone reopens the teardown gap the count exists to close.
- **Start harness-initiated turns only for announced tasks:** a `dequeued` notification whose `task_id` this process never announced (a resume drain of an earlier process's orphans) must stay inert.

## Harness Session Lineage

- **Treat a launch-returned session that differs from the resumed one as new:** seed `harnessSessionCreatedAt` as `nil` so `harnessSessionStateUpdate` persists it. Inheriting the resumed record's date makes the replacement look already-saved, so the conversation stays bound to the session it just replaced and keeps resuming — and re-replacing — that one.
- **Record every replaced session in `AgentSessionRecord.supersededHarnessSessionIds`:** launch-time replacements in `harnessSessionSeed`, mid-stream ones where `isSessionChange` fires. Archive and delete fan out over that lineage, so a session missing from it can never be cleaned up.
- **Retire superseded sessions once, best effort:** archive them only after the replacement record saves, track them in `ConversationState.retiredSupersededSessionIds` because metadata events repeat, and leave a failed one in the lineage for a later archive or delete to retry.

## Reconfigure And Collaboration Mode

- **Keep `AgentSpawnConfig` authoritative:** Runtime reconfigure should pass the desired config to the harness hook first, then update `ConversationState.spawnConfig` only after in-place success or process replacement.
- **Respect active turns:** Harnesses that cannot mutate the current turn should return `.nextTurnRequired`; host apps are expected to stage the new config for the next turn.
- **Track collaboration separately:** Keep `collaborationMode` in runtime state/status and events separate from `permissionMode`, which is approval policy.
- **Keep speed harness-reported:** Hosts choose `AgentSpawnConfig.speedMode`, but harness support comes from `AgentHarnessCapabilities.supportsSpeedMode`; do not add runtime speed status unless a harness starts reporting it natively.

## Process-Scoped Resources

- **Register before launch:** Create host-tool routes before context-aware harness launch so launch arguments never reference an unregistered endpoint.
- **Preserve cancellation ownership:** Destruction and shutdown may invalidate a suspended start early, but keep its tombstone until it resumes and performs final idempotent cleanup.
- **Detach before awaiting teardown:** Remove conversation state and finish subscribers before cleanup awaits so input, status, and output cannot reenter a conversation being destroyed.

## Validation

- Add or update focused runtime tests when changing process replacement, replay buffers, event cursors, deferred-tool stop handling, or interaction resolution.

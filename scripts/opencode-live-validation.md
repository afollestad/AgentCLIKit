# OpenCode V1 live validation

Run the actual pinned OpenCode executable against a deterministic local model:

```sh
python3 scripts/validate-opencode-live.py --binary /absolute/path/to/opencode
```

The script requires version `1.18.31`, creates an isolated home and XDG trees,
and uses temporary Git worktrees. It never reads user credentials or calls a
paid model. `--record PATH` writes sanitized HTTP responses and source-session
SSE events. The checked-in recording is
`Tests/AgentCLIKitTests/Resources/OpenCode/live-v1.18.31.json`.

The macOS arm64 release asset used for validation was
`opencode-darwin-arm64.zip`, SHA-256
`caf7f31fa1aec2353ea859d4ef9ab824c6273d941b016e88d51193fa3028d34e`.
The script does not download or update a binary.

For adapter integration tests, `--serve-provider-only` starts only the fake model
server and prints a JSON object with `baseURL`, `stateURL`, and `releaseURL` on
stdout. `FIXTURE_QUESTION` asks a question once, `FIXTURE_PERMISSION` requests a
shell approval once, and `FIXTURE_STEER` holds the model response until a GET to
`releaseURL` (or a 15-second timeout). `stateURL` reports `slowStarted` and the
number of model requests. Terminating the process ends the fixture server.
`FIXTURE_TASK` calls the ordinary native `task` tool once with a `general` subagent;
the child replies `Fixture child complete.` and the parent then replies
`Fixture task complete.`. `FIXTURE_IMAGE` replies `Fixture image complete.` and
`stateURL` reports `imageRequestCount` so tests can verify that image parts
actually reached the provider.
`FIXTURE_OVERFLOW` returns one `context_length_exceeded` HTTP 400 for a tool-enabled
model request; tool-free title requests leave it untouched. Summary and subsequent
requests succeed, allowing the real server to exercise automatic compaction.
`stateURL` reports `overflowCount` to confirm that the error was injected.

Run the Swift adapter integration checks against that same executable:

```sh
AGENTCLIKIT_OPENCODE_BINARY=/absolute/path/to/opencode swift test --filter OpenCodeLiveAdapterTests
```

These checks cover the adapter's typed events and lifecycle as well as native HTTP behavior, using the same isolated local fixture provider.

## Verified protocol details

- `x-opencode-directory` accepts percent-encoded absolute paths. Existing-session
  routes prefer the saved session directory; the header is not an access boundary.
- Native fork remaps message IDs and assistant parent IDs. To fork into an existing
  Git worktree, fork first, then call
  `POST /experimental/control-plane/move-session` with
  `{"sessionID":"ses_...","destination":{"directory":"/canonical/target"},"moveChanges":false}`.
  This preserves the full native history and supports subsequent forks. Resolve
  the target path before sending it. The destination must belong to the same project.
  Neither the experimental-workspaces nor runtime-V2 flag is required.
- Prompt model selection uses `modelID`; session-creation model selection uses `id`.
- Questions reply with `answers: [["selected label"]]`; permissions reply with
  `reply: "once"`, `"always"`, or `"reject"`.
- Compaction emits a compaction part, a `summary: true` assistant message, and
  `session.compacted`. The assistant can report `finish` before `time.completed`.
- A second asynchronous prompt is accepted while the first model call is active.
  It is processed after that call; this is not an in-flight model-generation edit.
- Native archive clearing is unavailable through V1 PATCH in this release:
  `time: {}` and `time: {archived: null}` leave the prior timestamp unchanged;
  `time: {archived: 0}` stores zero and still excludes the session from the native
  unarchived list. The probe reports this limitation rather than claiming restore
  succeeded.

The recording contains only synthetic model content, fixture tool calls and
temporary paths. Other sessions' fork-replay events are excluded so event tests
can use `responses.created.id` as their single session identity.

## Native startup maintenance

AgentCLIKit discovery issues only health/provider reads and never calls a config
mutation endpoint. Starting OpenCode can still perform upstream maintenance:
1.18.31 adds a missing `$schema` to loaded config, may migrate a legacy config
file, and prepares plugin dependencies. The adapter preserves user permission
and provider settings and injects host MCP credentials only through process
environment. The isolated validation trees contain these native maintenance
writes; discovery does not disable user configuration to suppress them.

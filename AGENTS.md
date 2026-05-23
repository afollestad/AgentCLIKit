## Keep Guidance Current

- Keep `AGENTS.md` information concise to minimize token usage.
- Keep `AGENTS.md` accurate when changes create useful future-agent context.
- Put new rules in the narrowest `AGENTS.md` that covers the affected files.
- When adding a nested `AGENTS.md`, also add sibling `CLAUDE.md` as `ln -s AGENTS.md CLAUDE.md`, then list the new scope below.
- Update `README.md` plus scoped guidance when dependencies, project structure, public APIs, or validation rules change.

## Scoped Guidance

Read the nearest `AGENTS.md` before editing. Current scopes:

- `AGENTS.md`: repo-wide workflow.
- `.agents/AGENTS.md`: repo-local agent workflows.
- `.agents/checks/AGENTS.md`: repo-local review, audit, and check workflows.
- `Sources/AgentCLIKit/Claude/AGENTS.md`: Claude provider adapter, config, stream decoding, and hook server behavior.
- `Sources/AgentCLIKit/Claude/Hooks/AGENTS.md`: Claude hook transport.
- `Sources/AgentCLIKitDemo/AGENTS.md`: macOS demo app.
- `Sources/AgentCLIKitDemo/Interactions/AGENTS.md`: demo prompt and hook-decision UI.

## Architecture

- Keep generic runtime, event, session, interaction, transcript, MCP, skills, and provider-detection code outside provider-specific folders.
- Put Claude-specific launch details, wire formats, config files, hook behavior, model defaults, and policies under `Sources/AgentCLIKit/Claude/`.
- Future providers, such as Codex, should use their own sibling provider folders rather than adding provider-specific branches to generic runtime code.
- Public APIs must use generic names and avoid host-app concepts such as SwiftData, view models, drafts, notifications, and keep-awake services.
- Additive public `Codable` changes should decode older persisted values with defaults.
- Compatibility tests live under `Tests/AgentCLIKitTests/Compatibility/` and should prove host-mappable behavior without importing host app code.

## Build And Test

- First-time setup: `./scripts/setup.sh`.
- Build: `./scripts/build.sh`.
- Test: `./scripts/test.sh`, or pass focused test identifiers as arguments.
- Lint: `./scripts/lint.sh`.
- Demo app: `./scripts/run-demo.sh` builds and launches the `AgentCLIKitDemo` executable.
- Ordered workflows must stay serial, never via `multi_tool_use.parallel`: build-then-test, lint-then-commit, self-review-then-commit.

### `xcsift` Output

- Build/test wrappers should pipe `xcodebuild` through `xcsift -f toon -w` when installed; treat TOON `status` and `summary` as the concise result.
- Inspect TOON sections such as `errors`, `warnings`, `failed_tests`, `linker_errors`, `slow_tests`, `build_info`, and `executables` when present.

## Lint

- Use SwiftLint from the repo root without `--config` so nested configs apply.
- Install repo hooks with `./scripts/setup.sh`.
- New Swift should follow `.swiftlint.yml`: no force unwraps outside tests, no force casts, prefer `let`, max line length 150.
- If a change introduces lint warnings or errors, tell the user before committing.

## Documentation And Comments

- Add doc comments for public protocols, structs, enums, methods, and provider extension points.
- Add concise implementation comments for non-obvious concurrency, process teardown, stream pumping, hook timeout, replay-buffer eviction, approval replay, and session continuity logic.
- Avoid comments that restate what the next line of code already says.

## Repo-Local Workflows

- For release bumps or release dry runs, follow `.agents/skills/create-release/SKILL.md`.
- For self reviews or audits, follow `.agents/checks/self-review/SKILL.md`.

## Commits

When creating commits, use an appropriate trailer in the message.

- If you are Claude: `Co-authored-by: Claude <noreply@anthropic.com>`
- If you are Codex: `Co-authored-by: Codex <noreply@openai.com>`

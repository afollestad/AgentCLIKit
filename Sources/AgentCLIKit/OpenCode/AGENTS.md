## OpenCode Harness

- Keep HTTP/SSE wire formats, model-provider discovery, permission mapping, and native configuration here; keep the generic runtime harness-neutral.
- Register process-scoped host tools through launch configuration only; explicit MCP settings edits belong to `OpenCodeConfigStore` and must preserve unrelated JSON/JSONC content.
- Keep provider-qualified model identity intact; a model name shared by two providers is not an alias. Preserve variant IDs as effort values and expose image support from model metadata.
- Validate server versions through `OpenCodeVersionSupport` before using the protocol; unknown major versions must not silently enable capabilities.
- Keep native goals, Fast mode, and hooks unsupported until their complete host-facing contracts are implemented and verified.
- Prepare read-only one-shot commands with disposable profiles; never route them through the command-only API or copy executable provider extensions.
- `.nativeIntegrations` probes `opencode debug config` with the server's own environment for MCP server names and disables each with a partial `enabled: false` entry, which OpenCode deep-merges; pair it with `serve --pure`. OpenCode has no shell sandbox, so never advertise `.shellNetwork`.

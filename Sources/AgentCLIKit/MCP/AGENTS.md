## MCP And Host Tools

- Keep persisted provider MCP configuration separate from process-scoped host tools; host tools must never rewrite global provider files.
- Keep host tool definitions Codable and handlers separately injected into the runtime.
- Bind host endpoints to IPv4 loopback with opaque per-process routes and credentials, strict limits, and defense-in-depth validation.
- Validate route, Host, Origin, and bearer authentication before handing a request to the MCP SDK or dispatching MCP JSON.
- Preserve trusted conversation, provider, process, and request identity from runtime context; never accept them from model arguments.
- Keep tool handlers cancellation-cooperative and enforce bounded request and response sizes.
- Invalidate each registration's invocation lifetime before stopping its route so cooperative handlers receive cancellation.

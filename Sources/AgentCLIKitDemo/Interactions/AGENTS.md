## Demo Interactions

- Keep `AskUserQuestion` UI and hook decisions demo-scoped; transport and Claude wire behavior stay in AgentCLIKit.
- Return `allow` with the original tool input plus an `answers` object keyed by question text.
- Keep pending prompts as the only outbound action until submitted or cancelled.
- Prefer `AgentInteractionInbox`, runtime status updates, and demo-support projections over ad hoc hook/store stitching for new interaction UI.
- Preserve fixed-option and custom-response prompt paths in demo flows.

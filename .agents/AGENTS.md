## Repo-Local Agent Workflows

- **Keep `.agents` canonical.** Store project-local workflows under `.agents`; expose them to individual agents through symlinks like `.claude/skills`, `.codex/skills`, `.claude/checks`, and `.codex/checks`.
- **Use `.agents/skills` for capabilities.** Store repo-local capability workflows under `.agents/skills`.
- **Use `.agents/checks` for audits.** Store review, audit, and check workflows under `.agents/checks`.
- **Keep workflows concise.** Put only agent-facing workflow details in workflow Markdown files; keep human-facing docs in `README.md`.
- **Use release skill.** For release bumps or release dry runs, follow `.agents/skills/create-release/SKILL.md`.
- **Use self-review check.** For self reviews or audits, follow `.agents/checks/self-review.md`.
- **Protect secrets.** Never commit signing keys, tokens, passwords, or base64 secret values.
- **Validate changes.** Run the workflow validator after editing `.agents/skills/*/SKILL.md` or `.agents/checks/*.md` when one is available.

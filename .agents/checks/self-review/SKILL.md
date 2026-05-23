---
name: self-review
description: Perform an AgentCLIKit self review or audit of current changes. Use when the user asks for a self review, audit, review of uncommitted changes, or a final quality pass before commit or PR in the AgentCLIKit repo.
---

# Self Review

## Overview

Perform a repo-aware quality audit of the current AgentCLIKit changes before they are committed or handed off. Prioritize concrete bugs, regressions, stale guidance, missing validation, and low-risk fixes.

## Steps

1. First say exactly: `Performing a self review...`
2. Inspect `git status --short` and the relevant diffs.
3. Read the nearest `AGENTS.md` files for changed paths when they were not already read in the current turn.
4. Review changes for:
   - Bugs.
   - Edge cases.
   - Regressions, especially accidental provider-specific behavior in generic code.
   - Provider boundary leaks between generic runtime code and provider folders.
   - Future provider feasibility, including Codex-style adapters that may not use Claude stream JSON.
   - Performance risks in process streaming, replay buffers, or transcript grouping.
   - Dead or stale code.
   - File-size pressure.
   - Missing unit or integration-style test coverage.
   - Missing doc comments on public APIs and extension points.
   - Missing implementation comments for non-obvious invariants.
   - Missing or stale `AGENTS.md` guidance.
   - Lint risks and Swift style issues.
5. Confirm validation for every subsystem touched.
6. Fix low-risk issues directly. If a specific commit SHA was given to the skill, amend directly into the commit.
7. Ask before risky or broad changes.
8. After fixing anything, automatically start another pass from step 2 with fresh status and diffs.
9. Report findings first, ordered by severity and grounded in file/line references.

## Looping Requirement

Treat every fixed issue as a reason to run the skill again automatically. Continue the inspect, review, fix, and validate cycle until a complete fresh pass finds nothing else worth addressing, the user interrupts or redirects the work, or the remaining changes are risky or broad enough to require approval.

## Output

Use the normal code-review shape:

- Findings first, with tight file and line references.
- Then open questions or assumptions.
- Then a brief summary of any fixes made and validation run.

If there are no findings, say that clearly and mention residual validation gaps.

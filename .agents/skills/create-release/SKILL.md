---
name: create-release
description: Prepare, dry-run, and publish AgentCLIKit Swift package releases. Use when the user asks to release AgentCLIKit, run a release dry run, create a patch/minor/major release, push a version tag, or prepare GitHub release notes.
---

# Create Release

## Overview

Release AgentCLIKit as a Swift Package by validating `main`, creating a semantic version tag, and publishing GitHub release notes. The package is SPM-first; do not use app signing, notarization, app ZIP, `project.yml`, or XcodeGen release flow here.

## Workflow

1. Start from the repo root and read `AGENTS.md`.
2. Confirm `git status --short --branch` is clean. Stop if unrelated changes exist.
3. Confirm the local branch is `main` and up to date with `origin/main`.
4. Ask which release bump to make when the user did not specify one: `patch`, `minor`, or `major`.
5. Determine the latest `vX.Y.Z` tag from Git.
6. Compute the next semantic version.
7. Run validation commands.
8. Confirm the target tag does not already exist locally or remotely.
9. Create an annotated tag for the release.
10. Push `main` and the new tag.
11. Create or update the GitHub Release for the tag, including concise release notes.

## Commands

```sh
git fetch origin main --tags
git status --short --branch
./scripts/build.sh
./scripts/test.sh
./scripts/lint.sh
git diff --check
git tag --list 'v*' --sort=-version:refname
git ls-remote --tags origin 'vX.Y.Z'
git tag -a vX.Y.Z -m "Release AgentCLIKit vX.Y.Z"
git push origin main
git push origin vX.Y.Z
gh release create vX.Y.Z --title "AgentCLIKit vX.Y.Z" --generate-notes
```

## Rules

- Keep releases tag-driven.
- Do not create app archives, DMGs, PKGs, notarized ZIPs, or Developer ID artifacts for this package release flow.
- Do not print, commit, or rewrite secrets.
- Stop if the target release tag already exists.
- Stop if validation fails.
- Commit release-preparation file changes, if any, with the appropriate trailer from the root `AGENTS.md`.

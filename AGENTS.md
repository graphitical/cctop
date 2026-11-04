# AGENTS.md - Development Guide for cctop

## Scope and Sources

cctop is a macOS menu bar app that monitors AI coding sessions and jumps to them.

Use this file for rules that apply to most cctop work. Use these sources for detailed decisions:

- Read [PRODUCT.md](PRODUCT.md) for product intent, feature fit, UX principles, and user-facing language.
- Read [DESIGN.md](DESIGN.md) for visual design rules.
- Read [docs/session-files.md](docs/session-files.md) for session identity, visibility, and focus-routing contracts.
- Read [docs/session-lifecycle.md](docs/session-lifecycle.md) for lifecycle, persistence, archive, and cleanup rules.
- Read [site/README.md](site/README.md) for website deployment and synchronization rules.
- Read [video/framework.md](video/framework.md) for the video build, quality verification, and publication workflow.

Keep canonical repository guidance in this file. Pointer files, such as `CLAUDE.md`, must point to this file instead of copying it.
Repository work does not require additional workflow skills.
Follow the instructions and commands documented here directly.

## Required Development Rules

- Do not change the user's tool configuration without explicit consent. This includes plugins, hooks, and settings files.
- Do not make a compatibility break that requires running sessions to restart before they can reconnect.
- New features can remain unavailable to an existing session until that session restarts.
- Treat `~/.cctop/sessions/*.json`, cctop logs, and client state as debugging evidence. A UI screenshot is only a symptom.
- Keep app liveness, client liveness, visibility, archive state, hidden state, subagent state, and hook provenance separate.
- If a shared source changes, update all owners in the same change. Shared sources include schemas, hook versions, install paths, and release tooling.
- For every version change, run `scripts/bump-version.sh <version>`. Do not edit version values separately.
- Preserve canonical identity and order in `SessionManager.userSessions`. Derive `SessionData` only at the final presentation or direct-action boundary. A direct row action must use the exact `SessionData` value that the row shows.
- Keep Stream Deck downstream of the app. It reads `~/.cctop/display-state.json` and must not recreate session policy.

## Driver Workflow

- Before starting any new work, run `git pull --ff-only origin master` in the main repository checkout so it is up to date.
- Start each independent change in an isolated worktree created from the updated `origin/master`.
- Make all task edits in the worktree, keeping the main repository checkout clean.
- For a stacked child, start from the exact approved parent head and target the parent branch.
- Until GitHub retargets the child after the parent merges, keep the parent branch as the target.
- The active driver owns edits, tests, commits, merges, pushes, CI fixes, and any PR follow-through.
- Keep exactly one active writer for a branch or PR.
- Make the smallest change that satisfies the approved behavior.
- Keep unrelated lifecycle, UI, release, and documentation work separate.
- Do not add flags, configuration, abstractions, or explicit default values without a current need.
- The developer has given standing authorization to implement requested work, run the required checks, commit the changes, squash-merge them into `master`, and push `master` to GitHub without separate publication approval.
- Continue through those steps unless the developer explicitly asks for a review checkpoint or tells you to stop.
- For a UI change, show a screenshot or rendered preview before merging.
- Do not commit scratch scripts, investigation pages, screenshots, or generated debugging files. Commit only intentional project assets.
- After you open or update a PR, check CI and review feedback, address consequential defects, and continue through merge and push.

## GitHub and PR Rules

- Squash-merge completed work into `master` and push `master` to GitHub.
- A PR is optional unless the developer requests one.
- Never post PR replies, comments, issue comments, or reviews. Leave all GitHub text to the developer.
- Independent review must verify that each eligible bot-authored thread is fixed, deliberately dismissed, or outdated.
- Before reporting the PR ready, the active driver must resolve each verified thread. This requirement includes unknown bot authors.
- Require explicit developer authorization before you resolve a human-authored thread.
- Before final PR closeout, verify the title, body, changed files, current head, CI, and review-thread state.
- Follow the developer's PR description guidance.

## Code Review Rules

- **Consequential defects:** Report only reachable defects that cause material harm or materially wrong visible behavior.
- Exclude style concerns, theoretical races, speculative hardening, mechanical CI results, and missing tests without a concrete regression.
- **Scope and proportionality:** Review the approved behavior instead of an adjacent redesign.
- If the smallest safe correction needs extra machinery, require only the necessary part.
- **Evidence and safe path:** Name the trigger, affected users or data, concrete harm, and smallest safe correction.
- Review non-trivial changes against the approved behavior and repository rules before publication.

## Runtime and Test Safety

Keep runtime actions serial so builds, tests, and app restarts do not interfere with one another.
Check for an active build or test run before starting another, and verify the running app's worktree before replacing it.

Runtime actions include:

- A cctop app build, run, restart, or termination.
- An Xcode app or test-host run, including snapshot tests.
- A `cctop-hook` installation or replacement.
- A Launch Services change or custom URL test.
- A Computer Use pass against cctop.
- A fixture app or end-to-end test that can publish shared display state.

Choose runtime checks that exercise the affected behavior.
For a local restart, install the worktree's hook before relaunching the app and verify both identities afterward.

- For app, hook, and integration source changes, use `make all`.
- For documentation-only changes, run focused documentation verification; the required end-of-task rebuild and restart below still apply.
- For hook-contract changes, run `make contract`. The schema, fixtures, validators, and sources own hook-event inventories.
- If feasible, add a failing regression test before you correct a bug.
- If a test replaces a persisted input, isolate every writable companion store that can react to that input.
- Never combine a fixture session inventory with real developer preferences or files.
- A test must not prune, migrate, or rewrite real developer state.
- For an affected public UI image, run `make snapshots` and inspect the output.

Before marking any task complete, including documentation tasks:

1. Read `.local/README.md` and `.local/build-and-install.command` in the main repository checkout to confirm the intended source worktree.
2. Run that `.local/build-and-install.command` helper to rebuild, reinstall, and restart cctop, passing the intended source worktree as its first argument when needed.
   The helper handles stopping the running app.
3. Verify the running app path.
4. Verify the installed hook version and binary hash against the source worktree's bundled build.
5. Report the app path, hook version, and identity evidence.

Leave the verified app running when the task is finished.
If the rebuild or restart is blocked, report the blocker instead of claiming the task is complete.
Stop the app only after a developer request or blocked relaunch.

## Architecture and Agent Integration Map

The Swift menu bar app and `cctop-hook` share models. The hook receives client events and writes local session JSON. The app classifies those records and publishes the visible projection.

All supported agent integrations call `cctop-hook`. Do not add a second session-state path inside a plugin.

| Agent or host | Source and file key | Design rule |
| --- | --- | --- |
| Claude Code | `source: "cc"`, PID-keyed file | Process generation controls CLI liveness. Finished sessions enter Recent Projects before removal. |
| Claude Desktop | `source: "cc"`, PID-keyed file | Trust `com.anthropic.claudefordesktop` only with `cc`. Use desktop archive and retention evidence. |
| Codex CLI and Desktop | `source: "codex"`, session-ID-keyed file | Use the shared Codex lifecycle. Persisted desktop bundle metadata is not host evidence. |
| opencode | `source: "opencode"`, PID-keyed file | Explicit source wins over inherited desktop bundle metadata. Process liveness controls lifecycle. |
| pi | `source: "pi"`, PID-keyed file | Skip non-interactive sessions. Explicit source wins over inherited desktop bundle metadata. |

Keep hook-event and client-event mappings out of this file. Update the contract sources and run `make contract` instead.

## Session Debugging

For wrong source, grouping, status, visibility, or cleanup behavior, inspect the session JSON before you change display logic.

- If `created_by_hook_version` is missing or null, treat the original writer as unknown.
- Inspect for an outdated or pre-metadata hook. Never infer or backfill the original writer.
- A current `last_written_by_hook_version` proves only the most recent writer. It does not identify the original writer.
- If provenance is current, inspect the resolved source, event delivery, liveness, visibility, archive state, and lifecycle separately.
- Trust desktop bundle metadata only for the supported source and host pairing in the integration map.
- Apply lifecycle and hook corrections to all supported clients. If evidence proves a client-specific fault, limit the correction to that client.

Use `~/.cctop/logs/<session-id>.log` and `~/.cctop/logs/_errors.log` to locate hook-delivery failures. Use the session documents for the persistence and lifecycle contracts.

## Focused Workflow Triggers

- For video story or storyboard work, follow [video/framework.md](video/framework.md).
- After approval of a video render, follow [video/DELIVERABLES.md](video/DELIVERABLES.md) for publication.
- For a release request, verify the release, signing, appcast, and publication using the repository's release tooling.
- For website changes, follow [site/README.md](site/README.md).
- For SwiftUI debugging, follow [DESIGN.md](DESIGN.md) and inspect the relevant state and view ownership.
- For build and test commands, use the `Makefile` instead of duplicating its command inventory here.

# Changelog

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html), with the development policy in [AGENTS.md](AGENTS.md#semantic-versioning).
A version entry records the source changes assigned to that version; it does not imply a published binary or GitHub Release.
Version numbers identify `graphitical/cctop` independently of upstream `st0012/cctop`.

## 0.22.0 — 2026-11-04

This is the fork's first versioned baseline, not a published release.
It retrospectively groups the 19 fork commits from upstream base [`4ee2258`](https://github.com/graphitical/cctop/commit/4ee225821cd4951e379f907a517b3a35a2a9b1fc) through [`f958577`](https://github.com/graphitical/cctop/commit/f9585775cb3062237f45b51602fab48067fe696f), which all retained the inherited `0.21.4` version.
The added features warrant a minor bump from `0.21.4` to `0.22.0`; the fixes are included in that bump.
Existing commits and upstream release tags retain their original identities.

### Added and changed

- Sort sessions by their most recent activity, keeping equal-time ordering stable (`bc16ad5`, November 3).
- Read Codex runtime and Desktop question status through local sockets so blocked questions and ready sessions can be distinguished (`a6d1078`, `fd51b6d`, `56a7426`, November 4).
- Add compact session rows and a vertically resizable panel that remembers its height (`517124f`, `3761cae`, November 4).
- Add a Codex theme, cooler Ready status colors, and Codex as the default theme while preserving saved theme choices (`157b30e`, `f958577`, November 4).
- Move idle conversations into the Idle tab immediately, add a Mark Idle context-menu action, and make the automatic idle delay configurable in Settings (`8ca3661`, `cecfafd`, `84c93cc`, November 4).

### Fixed

- Suppress attention states and permission notifications while Codex handles its automatic permission review (`014f45a`, November 3; `3de93a9`, November 4).

### Development

- Clarify the pull, isolated-worktree, squash-merge, publication, reinstall, and cleanup workflow; remove mandatory workflow-skill dependencies; and use `main` as the fork's default branch (`13147ba`, `bf457a5`, `b686e26`, `f8e879a`, `19b0029`, `8b6cf6f`, November 4).
- Start keeping app, hook, integration, and packaging versions synchronized for each independent shipped-code change, with an accompanying changelog entry.

### Publication notes

No fork releases or release tags existed when this baseline was recorded.
No historical release tags are being added: those commits still contain `0.21.4` metadata, and pushing `v*` tags would start the release workflow with mismatched versions.
Future changes continue from `0.22.0`; there is no need to reconstruct past binaries or rewrite Git history.

Before publishing the fork, review the inherited upstream destinations and credentials:

- `menubar/CctopMenubar/Info.plist` still points Sparkle to the upstream update feed and public key.
- `appcast.xml`, `packaging/homebrew-cask.rb`, the site, and release installation instructions still reference upstream downloads.
- `.github/workflows/release.yml` needs the fork's intended signing/notarization credentials, Sparkle signing key and appcast destination, and Homebrew tap destination checked before use.

These publication settings are separate from recording the fork's source versions.

## 0.21.4 — inherited upstream baseline

The fork starts at upstream commit `4ee2258`, following upstream tag [`v0.21.4`](https://github.com/st0012/cctop/releases/tag/v0.21.4) at `e199738`.
Earlier versions belong to the upstream release history and are not renumbered here.

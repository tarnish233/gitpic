# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Breaking:** `gitpic doctor` now exits non-zero when a check fails, using the
  most specific code available — `CONFIG_MISSING` (3) for a missing token or
  repo, `AUTH_FAILED` (4) or `NETWORK` (5) as returned by the GitHub probe, and
  `PERMISSION_DENIED` (7) when the token authenticates but lacks push. It
  previously always exited 0, so `gitpic doctor && gitpic <file>` would proceed
  with a broken config. Scripts that relied on `doctor` always succeeding need
  updating, though they were not detecting failures before either.
- `doctor --json` gained a `code` field carrying the same stable `ErrorCode`
  string as the exit status, so the failure cause is machine-readable instead of
  only present as prose in `detail`. `doctor` still prints just the report and
  never a second error envelope, so `--json` stdout remains exactly one object.
- `doctor`'s `detail` for a missing config now names the specific missing field
  (token vs repo) instead of the generic "run `gitpic init` or set
  GITPIC_TOKEN and GITPIC_REPO".

### Added
- `PERMISSION_DENIED` error code (exit 7): authenticated but not permitted.
  Uploads that receive a 403 still report `AUTH_FAILED`, since GitHub also uses
  403 for rate limiting.

### Fixed
- `doctor` no longer reports a repo as un-writable-because-denied when GitHub
  simply did not return a `permissions` block. That case was indistinguishable
  from an actual refusal; it now surfaces as `GENERAL` with an explicit message,
  so users are not sent to fix permissions that may be fine.

### Tests
- Pinned the full exit-code table so reordering `ErrorCode` cannot silently
  renumber it, and covered the permission classifier including the
  absent-permissions regression.

### Docs
- `SKILL.md` dropped two error codes it documented that `ErrorCode` never
  defined: `REMOTE_NOT_FOUND` (8) and `RATE_LIMITED` (9). An agent matching on
  them would never hit them. Missing-repo failures arrive as `NOT_FOUND` and
  rate limiting as `NETWORK`, distinguished by `error.message`.
- `SKILL.md` documents the `paste` subcommand, `--no-copy` on the `--stdin`
  example, the `GITPIC_OWNER` env var, and the `doctor` JSON schema, all of
  which were missing.
- `README.md` lists exit code 7 and notes that `doctor` reports failures through
  the exit status.


## [0.1.4] - 2026-07-25

### CI
- Bump `actions/checkout` to v5 and `softprops/action-gh-release` to v3
  (Node 24 runtimes) to clear the Node 20 deprecation warnings.

## [0.1.3] - 2026-07-25

### Changed
- `gitpic config set upload.quality` now rejects values outside `1-100`
  instead of silently storing an out-of-range value (it was clamped at
  compression time anyway).

## [0.1.2] - 2026-07-23

### Fixed
- Upload options (`--link`, `--format`, `--no-copy`, `--name`, `--stdin`,
  `--path`, `--repo`, `--compress`, `--max-width`, `--quality`) are now global,
  so they work after a subcommand too, e.g. `gitpic paste --name shot.png --link raw`.
- `--verbose`/`-v` now emits progress diagnostics to stderr (was a no-op).
- `--max-width` resize is honored even when the re-encoded file is not smaller
  (resize intent no longer silently discarded).
- Non-ASCII filenames no longer all collapse to `image`; the remote name falls
  back to the content hash so distinct images stay unique.

### Tests
- Added CLI parsing tests (options after subcommand), a non-ASCII naming test,
  and an image-resize test.

## [0.1.1] - 2026-07-23

### Changed
- Config now lives at `~/.config/gitpic/config.toml` (honors `$XDG_CONFIG_HOME`);
  upload history at `~/.local/share/gitpic/history.jsonl` (honors `$XDG_DATA_HOME`).
- Dropped the `directories` dependency in favor of XDG-style path resolution.

### Packaging
- Homebrew formula now auto-installs shell completions (bash, zsh, fish).
- Added a Chinese README (default) with an English version at `README.en.md`.

## [0.1.0] - 2026-07-22

### Added
- Upload local images to a GitHub repo (image host) and print a Markdown link.
- Sources: file paths, `--stdin`, and clipboard (`gitpic paste`).
- Output: Markdown / HTML / plain URL, with jsDelivr CDN or GitHub raw links.
- Auto-copy result to the clipboard (human mode).
- Content hashing with dedup, and a configurable remote path template.
- Image compression / resizing (`--compress`, `--max-width`, `--quality`).
- Upload history (`gitpic list`) stored as JSONL.
- Shell completion generator (`gitpic completion <shell>`).
- `gitpic doctor` health check, `gitpic init`, and `gitpic config` management.
- Agent-friendly mode: `--json` output with a stable schema and exit codes;
  bundled `SKILL.md`.
- GitHub Actions CI (fmt / clippy / build / test on Linux, macOS, Windows) and a
  tag-triggered multi-platform release workflow.

[0.1.4]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.4
[0.1.3]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.3
[0.1.2]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.2
[0.1.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.1
[0.1.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.0

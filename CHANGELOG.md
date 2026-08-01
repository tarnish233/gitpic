# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Docs
- `SKILL.md` no longer documents `PERMISSION_DENIED` (7), `REMOTE_NOT_FOUND` (8),
  or `RATE_LIMITED` (9) — `ErrorCode` only defines codes 1-6, so an agent
  matching on those would never hit them. The table now notes that permission,
  missing-repo, and rate-limit failures surface as `AUTH_FAILED`, `NOT_FOUND`,
  or `NETWORK`, and that `error.message` distinguishes them.
- `SKILL.md` no longer claims `doctor` exits non-zero on an unhealthy report; it
  always exits 0, so the preflight section now tells agents to read the
  `config_ok`/`token_valid`/`repo_writable` JSON fields and never the exit
  status. Trusting the exit code meant a broken config read as healthy.
- `SKILL.md` documents the `paste` subcommand, `--no-copy` on the `--stdin`
  example, and the `GITPIC_OWNER` env var, all of which were missing.

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

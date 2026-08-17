# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Credentials no longer need to live in the config file

`config.toml` stored the GitHub token in plaintext, which made the file unsafe to
keep in a synced dotfiles repo — and a classic PAT with `repo` scope grants
read/write on every repository the account can reach, with no expiry.

### Changed
- The credential is resolved from, in order: `GITPIC_TOKEN`, `github.token` in
  the config file, then `gh auth token`. With `gh` logged in, `config.toml` needs
  no secret at all and is safe to sync.
- A `github.token` left in the config keeps working and still takes priority over
  `gh`, so upgrading never silently switches which account uploads. Delete that
  line to switch over.
- `gitpic doctor` reports `token_source` (`env` / `config` / `gh`), so which
  credential is actually in use can be confirmed.
- The credential is resolved lazily, immediately before a request is made, so it
  is never stored in `Config` — whose derived `Debug` could otherwise print it.
  An unavailable credential now surfaces as `token_valid: false` rather than
  `config_ok: false`.
- `gitpic init` no longer asks for a token first; leaving the prompt blank uses
  `gh`.

Note: `gh`'s OAuth token typically carries `gist, read:org, repo, workflow` —
*broader* than writing to one image repo requires. This change keeps the secret
out of a syncable file; it does not narrow the token's scope. For least
privilege, pass a fine-grained token limited to the one repo via `GITPIC_TOKEN`.

### Fixed
- `gitpic paste --name shot.jpg` no longer publishes PNG bytes at a `.jpg` path.
  Clipboard captures are always encoded as PNG, so the extension is now derived
  from that rather than taken from `--name`; GitHub and jsDelivr were serving
  those uploads as `image/jpeg`.
- `gitpic config set upload.link_kind` and the `gitpic init` prompt now reject
  anything other than `cdn`/`raw`. A typo previously reported success and then
  silently produced CDN links forever, because the reader falls back to `cdn`.
- A blank `GITPIC_OWNER`, `GITPIC_BRANCH`, `GITPIC_LINK`, or `GITPIC_REPO` now
  falls through to the config file instead of overriding it with whitespace.
  `GITPIC_OWNER=" "` used to pass the config check and then produce a request
  against `/repos/%20/repo` — a confusing 404 rather than an actionable error.
- `gitpic list` now labels a deduplicated upload `(deduped)`, matching the word
  the upload output already used.

### Removed
- Dropped the unused `anyhow` and `thiserror` dependencies, along with the
  unreachable `image/webp` and the unused `tokio/fs`, `tokio/io-std`, and
  `clap/env` cargo features. Three crates leave the build graph.

### CI
- The release workflow now uploads `gitpic-<target>.*` with
  `fail_on_unmatched_files: true`. Listing four archive names of which two never
  exist on any given platform forced that check off, which meant a release that
  uploaded *nothing* still passed as green.
- `cargo fmt --check` runs on Linux only, since rustfmt's verdict is
  platform-independent, and the redundant `cargo build` step is gone —
  `clippy --all-targets` type-checks the same cfg and `cargo test` links a real
  executable, exercising every native dependency.

## [0.1.8] - 2026-08-14

### Fixed
- Pin `SKILL.md` to LF via `.gitattributes`. A Windows checkout was embedding
  CRLF through `include_str!`, so `gitpic skill install` always treated an
  already-installed copy as outdated.

## [0.1.7] - 2026-08-14

### An install path for the agent skill

`SKILL.md` previously just sat in the repository root with no way to install it —
but Claude Code and Codex both discover skills only at
`<skills-dir>/<name>/SKILL.md`, so the root copy was never loaded. Users had to
copy it by hand, and hand-copies drift: one was found stuck at 0.1.5, missing the
partial-success semantics for multi-image uploads.

### Added
- New `gitpic skill` subcommand: `install` / `print` / `path`. The document is
  embedded with `include_str!`, so an installed copy always matches the version of
  `gitpic` that wrote it.
- `gitpic skill install` detects `~/.claude/skills` and `~/.codex/skills`
  (honouring `CLAUDE_CONFIG_DIR` / `CODEX_HOME`) and prompts before writing;
  `--agent`, `--dir`, and `--yes` skip the prompt. Agents whose skills
  directories are symlinked to one place collapse into a single target instead of
  being written twice. Without a terminal (scripts, CI, agent calls) it returns a
  `USAGE` error rather than hanging or writing unasked.
- Claude Code marketplace manifest, installable with
  `/plugin marketplace add tarnish233/gitpic-cli`.
- Codex plugin manifest, installable with
  `codex plugin marketplace add tarnish233/gitpic-cli`.

### Changed
- Moved `SKILL.md` to `skills/gitpic/SKILL.md`. That is where both plugin formats
  look, so all three distribution channels share one source file with no copies.
  CI now asserts the manifest versions still match `Cargo.toml`.

## [0.1.6] - 2026-08-04

### Link correctness and credential safety
- Fix path and filename handling that produced links which did not resolve.
- Add network timeouts so the command can no longer hang indefinitely.
- Stop mixing terminal colour codes into redirected output.
- Keep links for images that already uploaded when a later one fails.

### Fixed
- Sanitize the `{ext}` placeholder like `{name}`: a filename such as `a.p#ng` no
  longer produces a truncated remote path or a broken link.
- Add request and connect timeouts to the GitHub client. A stalled connection
  previously hung the CLI indefinitely instead of reporting a retryable
  `NETWORK` error.
- Strip ANSI colour codes when stdout/stderr is not a terminal, and honour
  `NO_COLOR` / `CLICOLOR_FORCE`.
- Keep links for images that already uploaded when a later image in the same
  invocation fails. `--json` reports these under a new envelope carrying both
  `results` and `error`. When nothing uploaded, the existing error envelope is
  used unchanged.
- Percent-encode remote paths in API requests and generated URLs, so templates
  containing spaces or non-ASCII characters produce valid links.
- Escape alt text in Markdown and HTML output; `a]b.png` no longer emits broken
  Markdown, and quotes can no longer escape the HTML `alt` attribute.
- Reject a repo spec with extra path segments (`a/b/c`) instead of silently
  setting the repo to `b/c`.
- Reject `--quality` outside 1-100 at parse time, matching
  `config set upload.quality`. `--quality 0` was previously clamped to 1.
- Reject `--stdin` combined with file arguments, and `--stdin` combined with
  `paste`, instead of silently ignoring an input.
- Warn when a branch containing `/` is used with jsDelivr CDN links, where the
  branch/path boundary is ambiguous.

### Changed
- Report a warning when an upload cannot be recorded in local history, at `-v`.

### Performance
- Avoid copying image bytes when compression is disabled.
- Build the upload request body without an intermediate `serde_json::Value`,
  removing one full copy of the base64 payload.
- Hash to hex without a per-byte allocation.

## [0.1.5] - 2026-07-28

### Safer credentials and reliable agent workflows
- Protect configured GitHub tokens from accidental terminal or agent output.
- Make health checks and JSON errors deterministic for scripts and agents.

### Fixed
- Redact configured GitHub tokens from `config get` and interactive prompts.
- Preserve malformed configurations instead of silently replacing them with defaults.
- Compare Git blob hashes before treating an existing remote path as deduplicated.
- Emit JSON for argument errors when `--json` is requested, and make unhealthy
  `doctor` reports exit non-zero.
- Distinguish authentication, permission, remote-not-found, rate-limit, and
  retryable GitHub server errors.

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

[Unreleased]: https://github.com/tarnish233/gitpic-cli/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.6
[0.1.5]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.5
[0.1.4]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.4
[0.1.3]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.3
[0.1.2]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.2
[0.1.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.1
[0.1.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.0

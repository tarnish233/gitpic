# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] - 2026-08-17

### Input that cannot take effect is now refused

> **Upgrade note**: calls like `gitpic list --compress` now report a USAGE error
> (exit 2) instead of exiting 0. Only scripts that pass upload options to a
> non-upload subcommand are affected — those options never took effect, so such a
> script was not doing what it appeared to.

### Fixed
- A path template that escapes the repository is rejected instead of producing a
  bare 404. `upload.path_template = "../../../etc/{name}.{ext}"` was accepted and
  then sent to the Contents API, which answers with an unexplained "Not Found".
  The check runs on the *rendered* path — the one point all three template sources
  funnel into (`config set`, `--path`, a hand-edited file) — and `config set` also
  renders a sample so a bad template fails when it is set.
- Upload-only options are refused by the subcommands that ignore them.
  `gitpic list --compress --max-width 99` parsed, exited 0, and quietly did none
  of it; the same held for `completion`, `config`, `skill` and `init`. They stay
  `global = true` so `gitpic paste --no-copy` keeps working, but `dispatch` now
  reports the ones the chosen subcommand cannot act on. `--json`, `--quiet` and
  `--verbose` mean something everywhere and are unaffected; `--repo` is still
  accepted by `doctor`, which resolves a target.
- `history.jsonl` no longer grows without bound. Past 2 MB it is trimmed to the
  newest half, written to a temp file and renamed so an interrupted trim cannot
  leave a partial history. The trim runs only when a cheap metadata check says the
  file is over the ceiling, so an ordinary append does not read the file at all.
  **This drops the oldest records**, which contain links to old uploads.

### CI
- The release workflow no longer has four jobs racing to create the same Release.
  Each build now uploads an artifact and a single `publish` job downloads all of
  them, verifies four archives and four sidecars are present, and makes one
  `action-gh-release` call. The Release can no longer appear half-populated while
  other platforms are still building, and the four build jobs run with a read-only
  token — only `publish` can write.
- The Windows checksum sidecar matches `shasum -a 256` byte for byte (lowercase
  hash, two spaces, filename, LF, no BOM). `(Get-FileHash).Hash | Out-File` wrote
  an uppercase hash with no filename, which `shasum -c` cannot read at all. Every
  sidecar is now verified in CI, on the platform that produced it and again before
  publishing — the Windows format is not something a maintainer on macOS can check
  locally.
- `check_manifests.py` requires both changelogs to carry a section for the version
  in `Cargo.toml`. `release.yml` only ever read the Chinese one, so a release could
  ship with `CHANGELOG.md` left at `## [Unreleased]` and CI would stay green, even
  though AGENTS.md requires the two to stay aligned.

## [0.2.1] - 2026-08-17

### `doctor` can tell a broken credential from a GitHub hiccup

### Fixed
- `gitpic doctor` no longer gates the repository check on the credential check.
  The two answer different questions — `/user` asks "is this credential
  accepted", `/repos/{owner}/{repo}` asks "can it write here" — and an upload
  only ever calls the second kind. Because the repository probe ran only after
  `/user` succeeded, a transient 503 on `/user` reported
  `repo_writable: false` as well, which is indistinguishable from a bad
  credential. Observed live: `gh api user` returned 503 while
  `gh api repos/...` returned `push: true`, and `doctor` still reported
  everything red. Both probes now run concurrently and report independently, so
  that fault reads as `token_valid: false, repo_writable: true` with a
  retryable `NETWORK` code.
- When both probes fail, a definite answer now outranks `NETWORK`, which only
  ever means "could not tell". A 503 on `/user` no longer masks a 401 from the
  repository endpoint, so a genuinely bad credential is still reported as
  `AUTH_FAILED` rather than as something to retry forever.
- The agent skill told agents to send the user to `gh auth login` whenever
  `token_valid` was false. It now says to read the two checks together and
  retry instead when `repo_writable` is true and the code is `NETWORK` — the
  case where `gh auth login` cannot help.

## [0.2.0] - 2026-08-17

### Credentials no longer need to live in the config file

`config.toml` stored the GitHub token in plaintext, which made the file unsafe to
keep in a synced dotfiles repo — and a classic PAT with `repo` scope grants
read/write on every repository the account can reach, with no expiry.

### Breaking
- Config file keys are now validated strictly. A misspelled key or section
  (`dedupe`, `[uplaod]`) previously loaded fine and was silently ignored; it now
  makes every command that reads the config fail with `CONFIG_INVALID` (exit `10`)
  until the file is corrected. **If this error appears right after upgrading, the
  config has been carrying a typo that never took effect** — the message names the
  file and the offending line, and `gitpic config path` / `gitpic config edit`
  keep working so it can be repaired.
- Exit code `10` is new, so the published exit-code contract widens from `1-9` to
  `1-10`. It is purely additive and no existing code changed meaning, but a script
  that exhaustively matches `1-9` needs one more arm.

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
- The `gitpic init` token prompt can be left blank to use `gh`, and its label says
  so. (It is still the first field.)

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
  Surrounding whitespace is now trimmed too: the blank check looked at the
  trimmed value but stored the untrimmed one, so `GITPIC_OWNER=" me "` requested
  `/repos/%20me%20/repo`.
- A misspelled key or section in `config.toml` is now rejected instead of being
  silently ignored. `dedupe = false` or `[uplaod]` parsed fine and did nothing,
  with `gitpic config get` then showing the default as if the file had never been
  edited — the same class of failure as the two above, on the one input that is
  meant to be hand-edited (`gitpic config edit`). The error names the file and the
  offending line; `gitpic config path` and `gitpic config edit` keep working so the
  file can be repaired.
- A branch name is percent-encoded before it goes into a URL. Git allows `&`, `#`,
  `+`, `%` and `=` in a ref, and each one silently changed what the request meant:
  `#` made the rest of the URL a fragment, `&` started another parameter, `+`
  decoded to a space. The lookup then read the *wrong* ref, which looks like
  "nothing uploaded here yet" — losing deduplication and omitting the sha from the
  upload, so overwriting an existing file failed with a 409. The generated
  Markdown links were affected the same way.
- `gitpic list` now labels a deduplicated upload `(deduped)`, matching the word
  the upload output already used.

### Added
- Exit code `10` / `CONFIG_INVALID`, for a config file that exists but cannot be
  read or parsed. It was previously exit `1` / `GENERAL`, the catch-all that also
  covers clipboard and encoding failures, so nothing could act on it. `3` /
  `CONFIG_MISSING` still means "nothing configured yet" (`gitpic init`); `10` means
  "configured, but the file is broken" (`gitpic config edit`).
- Exit code `1` / `GENERAL` is now documented in both READMEs and the agent skill.
  It was always reachable — clipboard init, PNG encoding, launching `$EDITOR` — but
  the tables started at `2`, so a script built from them mis-classified it.

### Removed
- Dropped the unused `anyhow` and `thiserror` dependencies, along with the
  unreachable `image/webp` and the unused `tokio/fs`, `tokio/io-std`, and
  `clap/env` cargo features. Three crates leave the build graph.

### Docs
- Both READMEs claimed environment variables had the "highest priority". CLI flags
  override them — `GITPIC_LINK=raw gitpic a.png --link cdn` produces a cdn link —
  which is what `src/config.rs` documented all along.
- `GITPIC_OWNER` is documented (it was implemented but appeared in neither README).
- The English README's Install section only offered `cargo install --path .`, which
  cannot work outside a clone, while later sections referred to Homebrew and release
  archives it never mentioned. It now mirrors the Chinese one.
- The demo transcripts showed a `📋 copied to clipboard` line the binary never
  prints (a successful copy is silent; only failure is reported), and abbreviated
  `gitpic init` down to its final line.

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

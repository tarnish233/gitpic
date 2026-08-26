# Repository Guidelines

## Project Structure & Module Organization
`gitpic` is a Rust CLI. Source lives in `src/`:
- `main.rs` — entry point, subcommand dispatch, exit codes.
- `cli.rs` — clap argument/subcommand definitions.
- `config.rs` — config model + XDG path resolution (`~/.config/gitpic/config.toml`).
- `auth.rs` — the credential: reads/writes the 0600 `auth.toml` that `gitpic auth login` produces, and is the only source there is. No secret is held in `Config`.
- `oauth.rs` — GitHub device flow: the wire protocol behind `gitpic auth login`.
- `github.rs` — GitHub Contents API client (upload, dedup, health checks).
- `naming.rs`, `link.rs`, `imageproc.rs`, `output.rs`, `error.rs` — path/hash, URL/markdown, compression, human/JSON output, error types.
- `history.rs` — the upload log the app's 历史 pane reads.
- `release.rs` — the update check behind `gitpic update check`: version parsing and comparison, the `releases/latest` fetch, and the release's assets (name, size, download URL, GitHub's `digest`) that the app installs an update from. The feed is a compile-time constant on purpose, pinned by a test — its text is rendered inside GitPic's own window, so nothing configurable may choose its origin, and download URLs come from the API rather than a template for the same reason.
- `testutil.rs` — `#[cfg(test)]` only: the loopback stub server, a canned response, and the request reader shared by `github`'s and `release`'s tests. One `sock.read` is not a whole request; the module says what that cost twice.
- `commands/` — one module per action (`upload`, `auth_cmd`, `repos`, `branches`, `doctor`, `list`, `config_cmd`, `completion`, `skill`, `update`).

Docs: `README.md` (中文, default), `README.en.md`, `skills/gitpic/SKILL.md` (agent
usage), `CHANGELOG.zh-CN.md` (中文, Release source), and `CHANGELOG.md` (English). Keep
both changelogs aligned for every release. CI lives in `.github/workflows/`.
Homebrew lives in the separate `tarnish233/homebrew-tap` repo, as **two entries with
different names on purpose**. The cask is **`gitpic`** (`Casks/gitpic.rb`) and installs
the app; the formula is **`gitpic_cli`** (`Formula/gitpic_cli.rb`) and installs only the
binary. The bare name belongs to the cask because that is what most people want, and
`cask_renames.json` maps the old `gitpic_app` onto it so an installed keg migrates on
`brew upgrade`; don't remove it. There is no `formula_renames.json` any more — it was
deleted in 0.11.5 because keeping it made `gitpic` ambiguous between a formula and a
cask, which Homebrew resolves silently and in favour of the formula.

The app asset is `GitPic-<version>-macos-arm64.dmg` — a disk image with an
`/Applications` symlink beside the app, so a manual install is the usual drag-across. It
was a `.zip` up to 0.13.1; the tap's updater reads whichever of the two a release
actually shipped and writes that extension into the cask's `url`, which is what let the
format change without the cask and the release having to be edited in one breath.

The cask also provides the *command*: it links the CLI inside the bundle to
`bin/gitpic` and generates the three completions, so the app and the terminal share one
file and cannot be at different versions. The two entries therefore compete for
`bin/gitpic` — install one, not both — and the formula exists for Linux, Intel, CI, and
anyone who wants no app.

**How the tap learns about a release.** Two paths, and the second one exists because the
first cannot be trusted alone:

1. `release.yml`'s `publish` job fires a `repository_dispatch` (`gitpic-released`) at
   the tap the moment the release is up, carrying the version in `client_payload`. With
   a valid token the tap follows within seconds. It needs `secrets.TAP_DISPATCH_TOKEN` —
   a fine-grained PAT limited to the tap with Contents: write, because `GITHUB_TOKEN`
   cannot reach another repository. The step is guarded on the secret being non-empty
   and is `continue-on-error`, so a missing or expired token cannot fail a release that
   has already published.
2. The tap's six-hourly cron (`17 */6 * * *`) still polls `releases/latest`. **Keep it.**
   It is what catches whatever the dispatch missed, and it does not alarm on failure —
   so renaming a release asset here breaks the tap silently, with up to six hours before
   anyone notices.

The tap asserts that `releases/latest` matches the version the dispatch named, and fails
loudly when they disagree: publishing and `latest` moving are not one atomic act, and a
run that started a moment early would pin the tap to the *previous* release and report
success.

**The token expires, and path 1 dies quietly when it does — so check the tap after every
release.** Measured: the dispatch worked for eleven releases and then returned `Bad
credentials (HTTP 401)` on every one from 0.20.0 on, the token having stopped working
between 09:32 and 14:41 on 2026-08-24. `continue-on-error` did exactly what it is there
for and the release runs stayed green, so three releases fell back to the cron with
nothing anywhere saying so. The step now tells the two cases apart — no token versus a
token the tap refused — and raises a `::warning::` plus a step-summary line for either,
which shows on the run page rather than two clicks down. That helps only if someone
looks, so confirm the tap moved:

```bash
gh api repos/tarnish233/gitpic/releases/tags/vX.Y.Z \
  --jq '.assets[]|select(.name|endswith(".dmg")).digest'
gh api repos/tarnish233/homebrew-tap/contents/Casks/gitpic.rb --jq .content \
  | base64 -d | grep -E 'version |sha256'
```

Disagreeing means the dispatch did not land. Push it by hand with `gh workflow run
update-gitpic.yml --repo tarnish233/homebrew-tap`, and fix the cause: a new fine-grained
PAT scoped to `tarnish233/homebrew-tap` alone with Contents: write, then `gh secret set
TAP_DISPATCH_TOKEN --repo tarnish233/gitpic`.

`apps/GitPic/` is a macOS menu-bar app (SwiftUI) that drives the CLI over its
`--json` contract; `scripts/build-app.sh` builds the bundle with the `gitpic`
binary embedded. It is **not** a separate product with its own version: the app and
the CLI share `Cargo.toml`'s version and ship in the same GitHub Release. App
changes go in each version's `### App` subsection of the two root changelogs;
`apps/GitPic/CHANGELOG.md` is frozen at 0.1.2 as history. The app must never be
added to the plugin manifests — `check_manifests.py` asserts exactly one plugin
entry, and that entry is the CLI's skill.

Its two targets are a boundary, not a layout preference: `GitPicApp` is an
`executableTarget` and **cannot be imported by tests**, so anything worth testing
belongs in `GitPicCore` — which is also where process spawning lives, because
`ChildProcess` is internal to that module. The self-update feature is the clearest
case: `SelfUpdate*.swift` in `GitPicCore` holds the routing decision, the download
and verification, the staging and the generated swap script, all of which are
tested; `Updater.swift` in `GitPicApp` is only the wiring that gathers facts off the
main actor and quits at the end.

The skill at `skills/gitpic/SKILL.md` is the single source shipped three ways:
embedded into the binary via `include_str!` for `gitpic skill install`, and
referenced by the Claude Code marketplace (`.claude-plugin/marketplace.json`) and
the Codex plugin (`.codex-plugin/plugin.json` + `.agents/plugins/marketplace.json`).
Never copy it — `.github/scripts/check_manifests.py` (run in CI) asserts the
manifests still agree with `Cargo.toml` and with the skill itself.

## Build, Test, and Development Commands
- `cargo build` — debug build.
- `cargo build --release` — optimized binary at `target/release/gitpic`.
- `cargo run -- <args>` — run locally, e.g. `cargo run -- doctor --json`.
- `cargo test` — run all unit tests.
- `cargo fmt` / `cargo fmt --check` — format / verify formatting.
- `cargo clippy --all-targets -- -D warnings` — lint; warnings fail.

## Coding Style & Naming Conventions
Use rustfmt defaults (4-space indent). Types are `CamelCase`, functions/modules `snake_case`, constants `SCREAMING_SNAKE_CASE`. Keep clippy clean. Return `AppError` with a stable `ErrorCode`; write results to stdout (human/JSON) and diagnostics to stderr.

## Testing Guidelines
Unit tests are inline `#[cfg(test)] mod tests` per module. Add regression tests for parsing and logic changes (see `cli.rs`, `naming.rs`, `imageproc.rs`). Name tests descriptively, e.g. `upload_options_work_after_subcommand`. Run `cargo test` before pushing.

`tests/json_contract.rs` is the exception: it spawns the built binary because the
`--json` and broken-pipe contracts live in the wiring between `dispatch` and each
renderer, which a unit test cannot reach. It runs against a temporary
`XDG_CONFIG_HOME`/`XDG_DATA_HOME` and never touches the network. `cargo test` picks
it up with everything else.

**The app's update path has its own gate: `scripts/check-self-update.sh`.**
It installs a deliberately-old build, runs a *real* in-app update against the
published release, and asserts that the old process exits and a new one comes back
running the new version from the installed path. No release that changes
`Updater.swift`, `SelfUpdate*.swift`, `UpdateSheet.swift` or the quit goes out
until it has passed on a real machine. It exists because 0.20.0 shipped an updater
that downloaded, verified, staged and handed off correctly and then **did not
quit**: 243 unit tests, a full dry run and a code review were all green, because
`GITPIC_APP_DRY_RUN=1` returns before the quit, `GitPicApp` is an executableTarget
tests cannot import, and AppKit refused the termination ("App termination blocked
by modal sheet") without consulting our code at all. A real install is the only
thing that sees that, so a real install is what the gate runs. It touches only
`~/Applications`, refuses to run if `/Applications/GitPic.app` (this machine's own,
usually Homebrew's) moves, and needs this terminal to hold an Accessibility grant.

## Working in Parallel (one agent, one worktree)

Several agents work this repo at once, and `git checkout` is per-*directory* state:
in a shared checkout, one agent switching branches changes the files under all the
others. **Never `git checkout` / `git switch` in a directory you did not create.**
Run `git status -sb` before any git write and confirm the branch is yours, and stage
by explicit path — `git add -A` or `git commit -a` in a shared checkout sweeps in
whatever another agent had in flight.

Get your own directory instead:

```bash
scripts/new-worktree.sh feat/my-thing        # sibling dir, own branch, own HEAD and index
cd ../gitpic-feat-my-thing && . .local/env.sh
```

`git worktree list` shows who holds which branch, and git refuses to check out one
branch in two worktrees — so once every agent has its own, the collision is
impossible rather than merely discouraged. Clean up with `git worktree remove
--force <dir>`; `--force` is needed because `.local/` is untracked.

A worktree isolates the tree, not the machine. `.local/env.sh` redirects gitpic's
config and history (`XDG_CONFIG_HOME` / `XDG_DATA_HOME`) and points every worktree
at one shared `CARGO_TARGET_DIR`. What stays global no matter what:

- **The image-host repo** — any successful upload is a real commit in it. The
  scratch config starts empty, so `gitpic` reports `CONFIG_MISSING` instead of
  uploading; pass `--seed-config` only when you mean to write for real. Since 0.16.0
  the **credential is per-worktree too** — `auth.toml` sits beside `config.toml` under
  `XDG_CONFIG_HOME`, where it used to come from `gh`'s machine-wide keyring — so
  `--seed-config` seeds the target but not the token, and a real upload from a fresh
  worktree needs one `gitpic auth login` of its own.
- The skills directory that `gitpic skill install` writes to.
- `/Applications/GitPic.app` and `~/Library/Logs/GitPic.log` — one per machine.
- **`$TMPDIR`** — per *user*, not per worktree, which bites Swift tests specifically.
  Swift Testing has no suite-level teardown, so a fixture built once per suite must use
  a fixed name or it accumulates a copy per run (measured: four runs, four leaked signed
  bundles). But a *globally* fixed name is a landmine as soon as two agents run
  `swift test` at once — measured, two worktrees sharing
  `$TMPDIR/gitpic-install-test-image` gave `NSCocoaErrorDomain Code=4 "dmgroot couldn't
  be removed"` and five failures indistinguishable from a regression in the code under
  test. The two constraints pull opposite ways, so satisfy both: derive such a name from
  `#filePath`, which is fixed per checkout and distinct between worktrees. Never from a
  PID or a clock — that brings the per-run leak back.

`cargo test` is safe regardless: `tests/json_contract.rs` builds its own temporary
XDG directories and never reaches the network. `swift test` is not — run it in one
worktree at a time.

## Commit & Pull Request Guidelines
Follow Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`. PRs need a clear description, linked issues, and green CI (fmt, clippy, test on Linux/macOS/Windows). Releases are cut by pushing a `vX.Y.Z` tag, which builds the four platform binaries **and** GitPic.app and publishes them in one Release. The tag must equal `v` plus `Cargo.toml`'s version — the release workflow asserts it. The `app-v*` tags are historical, from when the app versioned separately; do not create new ones.

## Security & Configuration Tips
Never commit tokens. The credential comes from `gitpic auth login` and nowhere else: a 0600 `~/.config/gitpic/auth.toml`, written through the same atomic-private helper as the config, so nothing secret reaches `~/.config/gitpic/config.toml` and neither `gitpic config get` nor `config edit` can show a token. `auth.toml` is the one file in that directory that must never go into dotfiles sync. `gh auth token`, `--with-token`, `GITPIC_TOKEN` and the `github.token` key have all been removed — do not reintroduce a second source; each of them meant either a second identity or a secret travelling by hand, and `github.token` is still reported as `CONFIG_INVALID`. **`gitpic auth login` is interactive and cannot run unattended**, so CI that uploads needs a machine that has logged in once, and an agent must hand the command to the user rather than run it. `Debug` is hand-written on every type that holds a token (`auth::Stored`, `oauth::Granted`) so a panic or an `expect` cannot print one.

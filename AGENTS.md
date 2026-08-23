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
- `commands/` — one module per action (`upload`, `auth_cmd`, `repos`, `branches`, `doctor`, `list`, `config_cmd`, `completion`, `skill`).

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
   the tap the moment the release is up, carrying the version in `client_payload`. The
   tap follows within seconds. It needs `secrets.TAP_DISPATCH_TOKEN` — a fine-grained
   PAT limited to the tap with Contents: write, because `GITHUB_TOKEN` cannot reach
   another repository. The step is guarded on the secret being non-empty and is
   `continue-on-error`, so a missing or expired token cannot fail a release that has
   already published.
2. The tap's six-hourly cron (`17 */6 * * *`) still polls `releases/latest`. **Keep it.**
   It is what catches whatever the dispatch missed, and it does not alarm on failure —
   so renaming a release asset here breaks the tap silently, with up to six hours before
   anyone notices.

The tap asserts that `releases/latest` matches the version the dispatch named, and fails
loudly when they disagree: publishing and `latest` moving are not one atomic act, and a
run that started a moment early would pin the tap to the *previous* release and report
success.

`apps/GitPic/` is a macOS menu-bar app (SwiftUI) that drives the CLI over its
`--json` contract; `scripts/build-app.sh` builds the bundle with the `gitpic`
binary embedded. It is **not** a separate product with its own version: the app and
the CLI share `Cargo.toml`'s version and ship in the same GitHub Release. App
changes go in each version's `### App` subsection of the two root changelogs;
`apps/GitPic/CHANGELOG.md` is frozen at 0.1.2 as history. The app must never be
added to the plugin manifests — `check_manifests.py` asserts exactly one plugin
entry, and that entry is the CLI's skill.

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
  uploading; pass `--seed-config` only when you mean to write for real.
- The skills directory that `gitpic skill install` writes to.
- `/Applications/GitPic.app` and `~/Library/Logs/GitPic.log` — one per machine.

`cargo test` is safe regardless: `tests/json_contract.rs` builds its own temporary
XDG directories and never reaches the network.

## Commit & Pull Request Guidelines
Follow Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`. PRs need a clear description, linked issues, and green CI (fmt, clippy, test on Linux/macOS/Windows). Releases are cut by pushing a `vX.Y.Z` tag, which builds the four platform binaries **and** GitPic.app and publishes them in one Release. The tag must equal `v` plus `Cargo.toml`'s version — the release workflow asserts it. The `app-v*` tags are historical, from when the app versioned separately; do not create new ones.

## Security & Configuration Tips
Never commit tokens. The credential comes from `gitpic auth login` and nowhere else: a 0600 `~/.config/gitpic/auth.toml`, written through the same atomic-private helper as the config, so nothing secret reaches `~/.config/gitpic/config.toml` and neither `gitpic config get` nor `config edit` can show a token. `auth.toml` is the one file in that directory that must never go into dotfiles sync. `gh auth token`, `--with-token`, `GITPIC_TOKEN` and the `github.token` key have all been removed — do not reintroduce a second source; each of them meant either a second identity or a secret travelling by hand, and `github.token` is still reported as `CONFIG_INVALID`. **`gitpic auth login` is interactive and cannot run unattended**, so CI that uploads needs a machine that has logged in once, and an agent must hand the command to the user rather than run it. `Debug` is hand-written on every type that holds a token (`auth::Stored`, `oauth::Granted`) so a panic or an `expect` cannot print one.

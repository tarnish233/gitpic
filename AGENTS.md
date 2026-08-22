# Repository Guidelines

## Project Structure & Module Organization
`gitpic` is a Rust CLI. Source lives in `src/`:
- `main.rs` — entry point, subcommand dispatch, exit codes.
- `cli.rs` — clap argument/subcommand definitions.
- `config.rs` — config model + XDG path resolution (`~/.config/gitpic/config.toml`).
- `auth.rs` — obtains credentials exclusively from `gh auth token`; no secret is held in `Config`.
- `github.rs` — GitHub Contents API client (upload, dedup, health checks).
- `naming.rs`, `link.rs`, `imageproc.rs`, `output.rs`, `error.rs` — path/hash, URL/markdown, compression, human/JSON output, error types.
- `commands/` — one module per action (`upload`, `init`, `doctor`, `list`, `config_cmd`, `completion`, `skill`).

Docs: `README.md` (中文, default), `README.en.md`, `skills/gitpic/SKILL.md` (agent
usage), `CHANGELOG.zh-CN.md` (中文, Release source), and `CHANGELOG.md` (English). Keep
both changelogs aligned for every release. CI lives in `.github/workflows/`.
The Homebrew formula lives in the separate `tarnish233/homebrew-tap` repo and is
called **`gitpic_cli`**, not `gitpic`: the formula names the CLI so it cannot be
read as the app. What it installs is unchanged — the binary, the completions and
`/opt/homebrew/bin/gitpic` are all still `gitpic`, which is also how GitPic.app
finds a system CLI. The tap's `formula_renames.json` maps the old name onto the
new one, so `brew install tarnish233/tap/gitpic` still resolves and an installed keg
migrates on `brew update` / `brew upgrade` (or `brew migrate gitpic`); don't remove it.
The app is in the same tap, as the cask **`gitpic_app`** built from the Release's
`GitPic-<version>-macos-arm64.zip`. That cask also provides the *command*: it links
the CLI inside the bundle to `bin/gitpic` and generates the completions, so the app
and the terminal share one binary and cannot be at different versions. The two entries
therefore compete for `bin/gitpic` — install one, not both — and the formula exists for
Linux, Intel, and anyone who wants no app. The tap's six-hourly updater bumps the
formula and the cask together off `releases/latest`, and does not alarm on failure — so
renaming a release asset here breaks both of them silently.

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
Never commit tokens. Credentials come exclusively from `gh auth token`, so nothing secret is written to `~/.config/gitpic/config.toml`. `GITPIC_TOKEN` and the removed `github.token` key are not accepted; CI must authenticate GitHub CLI before invoking gitpic.

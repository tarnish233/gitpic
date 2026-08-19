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
The Homebrew formula lives in the separate `tarnish233/homebrew-tap` repo.

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

## Commit & Pull Request Guidelines
Follow Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`. PRs need a clear description, linked issues, and green CI (fmt, clippy, test on Linux/macOS/Windows). Releases are cut by pushing a `vX.Y.Z` tag, which triggers multi-platform binaries.

## Security & Configuration Tips
Never commit tokens. Credentials come exclusively from `gh auth token`, so nothing secret is written to `~/.config/gitpic/config.toml`. `GITPIC_TOKEN` and the removed `github.token` key are not accepted; CI must authenticate GitHub CLI before invoking gitpic.

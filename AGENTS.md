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
- `release.rs` — the update check behind `gitpic update check`: version parsing and comparison, the `releases/latest` fetch, and the release's assets (name, size, download URL, GitHub's `digest`) that the app installs an update from. The origin is a compile-time constant on purpose, pinned by a test — its text is rendered inside GitPic's own window, so nothing configurable may choose it, and download URLs come from the API rather than a template for the same reason.
- `install_source.rs` — which of the three ways this binary was installed (inside GitPic.app, `cargo install`, or unknown), so `gitpic update` prints the one upgrade command that install actually wants instead of two to choose between. Canonicalises `current_exe()` first: the app links `~/.local/bin/gitpic` into the bundle, so the commonest install of all is invoked through a symlink, and on Apple platforms the un-canonicalised path is that symlink — which classifies it as neither an app nor a cargo bin and prints "download it again" for the one install that updates itself.
- `testutil.rs` — `#[cfg(test)]` only: the loopback stub server, a canned response, and the request reader shared by `github`'s and `release`'s tests. One `sock.read` is not a whole request; the module says what that cost twice.
- `commands/` — one module per action (`upload`, `auth_cmd`, `repos`, `branches`, `doctor`, `list`, `config_cmd`, `completion`, `skill`, `update`).

Docs: `README.md` (中文, default), `README.en.md`, `skills/gitpic/SKILL.md` (agent
usage), `CHANGELOG.zh-CN.md` (中文, Release source), and `CHANGELOG.md` (English). Keep
both changelogs aligned for every release. CI lives in `.github/workflows/`.

**The `release-notes-end` marker splits two audiences, and the half above it is for
people deciding whether to upgrade.** Everything above becomes the GitHub Release body
*and* the app's update sheet; everything below stays in the file. So above the marker:
one theme heading and **two or three bullets of roughly one line each** — what changed,
in the user's terms, no mechanism. Aim for ~40 characters of 中文 or ~100 of English per
bullet; a released 0.20.3 bullet ran to 246 characters, which is a paragraph pretending
to be a summary. Everything that made it worth doing — the measurement, the design that
was rejected, the test that was wrong — goes *below* the marker and into the commit
message, which is where someone reading the code will look for it. Nothing is lost by
being brief up top; it is only moved to the reader who wants it.

**Distribution is one path: the DMG, then the app updates itself.** There is no Homebrew
cask, no `gitpic_cli` formula and no `tarnish233/homebrew-tap` — all three were retired
together, and nothing transitional was left behind because the only user is the author. Do
not reintroduce a brew install path without first saying why the in-app updater is not
enough.

The app asset is `GitPic-<version>-macos-arm64.dmg` — a disk image with an `/Applications`
symlink beside the app, so installing is the usual drag-across. It was a `.zip` up to 0.13.1.

**The quarantine flag is the one manual step, and it is not optional.** The app is ad-hoc
signed and not notarised, so a freshly downloaded copy refuses to open *at all* until
`xattr -dr com.apple.quarantine /Applications/GitPic.app`. The cask's `preflight` used to do
this silently and nothing does it now, which is why the release notes and both READMEs say it
immediately after the drag rather than as a footnote. Self-update is unaffected —
`SelfUpdateInstall` copies with `ditto --noqtn` and strips the attribute itself — so only a
fresh manual install ever needs the command.

**`releases/latest` is the single thread the whole thing hangs from.** It is what the app's
own update check polls, so a release flagged prerelease is a release no installed app can
see, silently and indefinitely. See constraint 3 in `release.yml`'s header.

**The terminal `gitpic` command comes from the app, on request.** 设置 ▸ 通用 ▸ 命令行 links
`~/.local/bin/gitpic` at the copy inside the bundle and writes three completions
(`~/.zfunc/_gitpic`, `~/.local/share/bash-completion/completions/gitpic`,
`~/.config/fish/completions/gitpic.fish`). Linking rather than copying is what keeps the
command and the app from ever being at different versions — the one property the cask
genuinely provided. `~/.local/bin` rather than `/usr/local/bin` because it is user-owned:
no privileged helper, and no authorisation prompt out of an unnotarised bundle. Two rules
for anything touching `GitPicCore/CommandLineTool.swift`:

- **It never edits a shell rc file.** `Shell.setUp` returns the lines for the user to paste
  and no writer for them exists in either target; a source scan in `CommandLineToolTests`
  fails if `.zshrc`, `.bash_profile`, `.bashrc` or `config.fish` appears anywhere under
  `Sources/` outside that one literal.
- **Reachability is measured with a login shell, never with `ProcessInfo.environment["PATH"]`.**
  A Finder-launched app inherits only `/usr/bin:/bin:/usr/sbin:/sbin`, so the environment
  reports "not on PATH" for everybody, including machines where it plainly is.
  `ToolDiscovery.loginShellProbe` returns the *unresolved* winning PATH entry, which is the
  spelling the link has to be compared against.

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

**Do not run `scripts/check-self-update.sh` as part of cutting a release.** A
release that touches `Updater.swift`, `SelfUpdate*.swift`, `UpdateSheet.swift` or
the quit is covered by `QuitPathContractTests` and `SelfUpdateInstallTests`
(including `quitDuringStagingLeavesNothing`). The live-install script still
exists, and it is how 0.20.0's "downloaded then did not quit" was caught after
the fact: 243 unit tests, a full dry run and a code review were all green,
because `GITPIC_APP_DRY_RUN=1` returns before the quit, `GitPicApp` is an
`executableTarget` tests cannot import, and AppKit refused the termination
("App termination blocked by modal sheet") without consulting our code at all.
Reach for it only when deliberately debugging the quit/handoff on a real
machine. It is not a ship gate: it needs an Accessibility grant, rewrites
`Cargo.toml` to `0.0.1` for the length of the run, hits GitHub's unauthenticated
rate limit from a worktree with no credential, and the confirmation-alert click
is not reliable from an agent session. It touches only `~/Applications`, refuses
to run if `/Applications/GitPic.app` (this machine's own installed copy)
moves, and drives the three quits separately when it does run: 「退出 GitPic」 in
the status menu (our code), and the `terminate:` AppKit synthesises for a
Dock-menu Quit and for the Apple Event a logout or restart sends. ⌘Q is not
driven, because making the app frontmost poisons the accessibility tree for the
rest of the run; it shares one selector with the menu item, which
`QuitPathContractTests` holds.

Every `InFlightWork` slot — mount, staging, download, **and the writing child** —
registers through `claimSlot(epoch)`. The child used to be a plain setter: a `ditto`
spawned in the `UserDefaults.synchronize()` window between drain and `exit(0)` was
reparented to launchd and recreated the staging directory just deleted. `false` from
`holdWritingChild` is SIGKILL immediately and ``InstallFailure.cancelled``. Do not add
a fifth registration shape.

**The other AppKit-only property with a suite of its own: opening the window has to *show*
it.** `WindowFocusContractTests` is a source scan for the same reason the quit contract is
one — `GitPicApp` is an `executableTarget` tests cannot import, and the answer comes from
AppKit's treatment of a real window in an app that is not frontmost. What it holds is that
raising the policy and coming to the front are two calls, only the first of them guarded:
`AppActivationPolicy.enter()` is reference-counted so that closing the window gives the Dock
icon back, and `comeForward()` is not, because it has to happen on every open. They were one
call until 0.20.6, so the guard skipped the activation whenever the window was already open,
and every route in that can be taken while the app is in the background — the status menu's
打开设置, 连通性测试 and 检查更新/有新版本… — then did nothing the user could see.
`makeKeyAndOrderFront` does not cover it: an app that is not active puts none of its windows
in front of the active app's. (`MainMenu`'s ⌘, and 关于 were never affected; a main-menu key
equivalent only fires while the app is frontmost.)

Measured rather than reasoned about, by driving both builds through the accessibility tree
with the window already open behind Finder, five trials each, every trial checking that
Finder really had the screen first: shipped 0.20.5 came forward **0/5**, the fix **5/5**.
Two things that harness taught, worth knowing before writing another one: a human at the
keyboard steals focus, so a trial that cannot confirm its own precondition has to be
discarded rather than counted; and clicking one GitPic's status item while a *second* GitPic
is frontmost left the first sitting `.regular` with zero windows and refusing to open one —
not reproducible on a fresh process, so it is an artifact of driving two instances at once
and not a defect, but it will waste an hour if you meet it without knowing.

## Known defects

These are listed here so a later change does not "fix" half of the invariant and
ship the other half, which is how several of them formed. Do not close one by
adding a special-case branch in an unrelated path; the surrounding comments
already record what that costs.

None currently. Closed items live in the comments next to the code that holds
the other half.

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
Never commit tokens. The credential comes from `gitpic auth login` and nowhere else: a 0600 `~/.config/gitpic/auth.toml`, written through the same atomic-private helper as the config, so nothing secret reaches `~/.config/gitpic/config.toml` and neither `gitpic config get` nor `config edit` can show a token. `auth.toml` is the one file in that directory that must never go into dotfiles sync. `gh auth token`, `--with-token`, `GITPIC_TOKEN` and the `github.token` key have all been removed — do not reintroduce a second source; each of them meant either a second identity or a secret travelling by hand, and `github.token` is still reported as `CONFIG_INVALID`. **`gitpic auth login` is interactive and cannot run unattended**, so CI that uploads needs a machine that has logged in once, and an agent must hand the command to the user rather than run it. `Debug` is hand-written on every type that holds a token (`auth::Stored`, `oauth::Granted`, `oauth::Device`) so a panic or an `expect` cannot print one. `GitHub` holds the same token and currently has no `Debug` at all — do not derive one.

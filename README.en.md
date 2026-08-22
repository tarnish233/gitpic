# gitpic

[简体中文](./README.md) | **English**

Upload local or clipboard images to a GitHub repository (used as an image host)
and get a Markdown link — instantly copied to your clipboard.

Human-friendly on the terminal, machine-friendly (`--json`) for scripts and AI
agents. The program is a single binary; authentication is delegated to GitHub CLI (`gh`).

## Demo

```console
$ gitpic init
gitpic init — configure your GitHub image host

Credentials come from `gh auth token`.
Run `gh auth login` once if you have not already.

Target repo (owner/name): your-name/img
Branch [main]:
Link kind (cdn|raw) [cdn]:

✓ saved config to /Users/you/.config/gitpic/config.toml

$ gitpic ~/Desktop/shot.png
✓ uploaded shot
![shot](https://cdn.jsdelivr.net/gh/your-name/img@main/images/2026/07/a1b2c3d4-shot.png)

$ gitpic list
2026-07-23  shot
  https://cdn.jsdelivr.net/gh/your-name/img@main/images/2026/07/a1b2c3d4-shot.png
```

## Install

The CLI and the menu-bar app are two names in Homebrew but you only need **one** of
them: the cask **`gitpic_app`** (app *and* the terminal command, below) or the formula
**`gitpic_cli`** (command line only). Same version, same source, and the command is
`gitpic` either way.

**Homebrew (macOS/Linux — adds it to `PATH` and installs shell completions)**

```bash
brew install tarnish233/tap/gitpic_cli
```

Use this if you want the command line only. If you install GitPic.app you already have
`gitpic` in the terminal (see below) and do not need this — installing both makes them
compete for the same `bin/gitpic`.

> The formula used to be called `gitpic`. The old name still installs (the tap
> carries a rename map), and an existing install is migrated by `brew update` /
> `brew upgrade`, or by `brew migrate gitpic` on demand. The migration only renames
> the directory in the Cellar — the command, the completion scripts and the
> `/opt/homebrew/bin/gitpic` symlink are unchanged.

**Prebuilt binary**

Download the archive for your platform from the
[releases page](https://github.com/tarnish233/gitpic-cli/releases). On macOS,
clear the quarantine flag on first run:

```bash
tar -xzf gitpic-aarch64-apple-darwin.tar.gz     # Apple Silicon
xattr -d com.apple.quarantine ./gitpic 2>/dev/null
chmod +x ./gitpic && mv ./gitpic ~/.local/bin/  # ensure ~/.local/bin is on PATH
```

> Intel Mac: `x86_64-apple-darwin`. Linux: `x86_64-unknown-linux-gnu`. Windows is
> a `.zip` containing `gitpic.exe`.

**From source** (needs Rust 1.88 or newer)

```bash
cargo install --git https://github.com/tarnish233/gitpic-cli
```

### GitPic.app (optional macOS menu-bar app)

```bash
brew install --cask tarnish233/tap/gitpic_app   # then: brew upgrade --cask gitpic_app
```

It carries the same version as the CLI and embeds that same `gitpic` build, and the
cask links that copy to `$(brew --prefix)/bin/gitpic` and generates the bash, zsh and
fish completions — so **installing the app installs the command line too**: `gitpic` is
in the terminal, the formula is not needed, and the command cannot be a different
version from the app (upgrading one upgrades both).

The config file and the upload history are shared: change the repository in the app and
the terminal follows, and vice versa.

Install the formula instead if you want the command line only, or you are on Linux or an
Intel Mac. **Do not install both** — they compete for the same `bin/gitpic` and the same
three completions, and whichever arrived first keeps them: the formula added second ends
with a failed `brew link` (installed but unlinked), the cask added second prints
`skipping link` and `Will not overwrite`. Uninstall one before switching, and after
switching *from* the formula run `brew reinstall --cask gitpic_app` so the links it
skipped get made.

Upload the clipboard image or pick files from the menu-bar icon; the link lands on
your clipboard. The settings window edits the image-host repository and the upload
options, and browses history.

Or take `GitPic-<version>-macos-arm64.zip` from a
[release](https://github.com/tarnish233/gitpic-cli/releases) and install it yourself.
The app is ad-hoc signed and not notarised by Apple, so a manual install has to clear
the quarantine flag before it will open (the cask does this step for you):

```bash
unzip GitPic-<version>-macos-arm64.zip -d /Applications/
xattr -dr com.apple.quarantine /Applications/GitPic.app
```

> Apple Silicon only. Still needs GitHub CLI, logged in:
> `brew install gh && gh auth login`.

## Setup

Credentials come only from the [GitHub CLI](https://cli.github.com), so
**no secret is stored in the config file**:

```bash
gh auth login          # once; the token lives in your system keyring
gitpic init            # asks for repo/branch/link kind only, never a token
```

Whenever GitHub access is needed, `gitpic` runs
`gh auth token --hostname github.com`. `GITPIC_TOKEN` is no longer read and the
`github.token` config key is no longer supported. When upgrading, remove any
legacy `token` line and run `gh auth login`; otherwise strict config validation
reports `CONFIG_INVALID`.

> **Scope caveat**: `gh`'s OAuth token may be broader than what writing to one
> image repo needs. Use `gh auth status` to inspect the active account and login.

Config lives at `~/.config/gitpic/config.toml` (honors `$XDG_CONFIG_HOME`).
You can hand-write it or generate it with `gitpic init`. Note there is no `token`
key, so this file is safe to keep in a synced dotfiles repo:

```toml
[github]
owner  = "your-name"
repo   = "img"
branch = "main"

[upload]
path_template = "images/{year}/{month}/{hash8}-{name}.{ext}"
format        = "md"    # md | html | url — the default for `--format`
link_kind     = "cdn"   # cdn (jsDelivr) | raw — the default for `--link`
dedup         = true
auto_copy     = true    # copy the link after an upload; the app honours it too
                        # (never written in --json / --quiet)
compress      = false
max_width     = 0        # 0 = keep original
quality       = 82       # JPEG quality when compressing (1-100)
```

The upload target and preferences can also be overridden with environment
variables (credentials cannot; CLI flags still take priority):

```bash
export GITPIC_REPO="your-name/img"     # owner/name (or just name, keeping the owner)
export GITPIC_OWNER="your-name"        # optional: override only the owner
export GITPIC_BRANCH="main"            # optional (default: main)
export GITPIC_LINK="cdn"               # optional: cdn (jsDelivr) | raw
```

Precedence is **CLI flags > environment variables > config file** — so
`GITPIC_LINK=raw gitpic a.png --link cdn` produces a cdn link. A variable that is
blank is ignored (falling through to the config file), and surrounding whitespace
is trimmed.

Upload history is stored at `~/.local/share/gitpic/history.jsonl`
(honors `$XDG_DATA_HOME`).

## Usage

```bash
gitpic screenshot.png            # upload, print markdown, copy to clipboard
gitpic a.png b.png               # batch upload
gitpic paste                     # upload the image on your clipboard
cat img.png | gitpic --stdin          # extension comes from the bytes
gitpic doctor                    # verify gh authentication + repo access
gitpic list                      # show recent uploads (local history)
gitpic completion zsh            # print shell completion script
gitpic skill install             # install the agent skill (see below)

# output control
gitpic photo.jpg -q -f url       # only print the URL
gitpic photo.jpg --json          # structured JSON (for scripts / agents)
gitpic photo.jpg --link raw      # use raw.githubusercontent.com

# compression / resizing
gitpic big.png --compress                    # compress before upload
gitpic big.png --compress --max-width 1600   # resize so width <= 1600
gitpic big.jpg --compress --quality 80       # JPEG quality
```

## Config keys

```bash
gitpic config path
gitpic config get                        # show all settings
gitpic config set github.repo owner/name
gitpic config set upload.link_kind raw
gitpic config set upload.compress true
gitpic config set upload.max_width 1600
gitpic config set upload.quality 82
gitpic config edit                       # open the file in $EDITOR
```

`path_template` placeholders: `{year} {month} {day} {hash} {hash8} {name} {ext}`

`--json` answers with an `ok`-bearing envelope on every subcommand, failures
included, with three exceptions: the interactive `gitpic init` **rejects** it;
`gitpic completion <shell>` ignores it and prints the raw shell script; and
`gitpic config edit` ignores it and hands stdout to `$EDITOR`, whose output is not
JSON. `--quiet` only changes the output of the upload path and `gitpic list` (one
link per line); `gitpic doctor` and `gitpic skill install` still print human check
marks and prose under it (`config get`, `config path` and `skill path` already emit
machine-usable output).

Key names in the config file are validated strictly: a misspelled key or section
(`dedupe`, `[uplaod]`) is a `CONFIG_INVALID` error naming the file and the rejected
key rather than a value that is silently ignored (no line number, so a source line
that might hold a credential is never echoed). `gitpic config path` and
`gitpic config edit` keep working in that state so you can fix the file.

## Shell completion

Installed automatically when you use Homebrew (`bash`, `zsh`, `fish`). For manual
installs, generate the script yourself:

```bash
gitpic completion zsh  > ~/.zfunc/_gitpic     # then autoload
gitpic completion bash > /etc/bash_completion.d/gitpic
gitpic completion fish > ~/.config/fish/completions/gitpic.fish
```

## Downloads

Prebuilt binaries for macOS (Apple Silicon + Intel), Linux, and Windows are
attached to each [GitHub Release](../../releases) (built by CI on `v*` tags).

## Exit codes

`0` ok · `1` other error · `2` usage · `3` config missing · `4` auth failed ·
`5` network · `6` local file not found · `7` permission denied ·
`8` remote resource not found · `9` rate limited · `10` config file unusable

`3` means "nothing configured yet" (run `gitpic init`); `10` means "configured,
but the file is broken" (run `gitpic config edit`). They need different fixes, so
they get different codes.

## Agent integration

`gitpic` ships an [Agent Skill](./skills/gitpic/SKILL.md) that teaches Claude Code,
Codex, and other agents how to call it. Install it one of these ways.

**From the CLI (any agent)**

The skill is embedded in the binary, so the installed copy always matches the
`gitpic` version you are running — re-run this after `brew upgrade gitpic_cli` to
resync:

```bash
gitpic skill install                 # pick from the detected agents
gitpic skill install --agent codex   # or name one
gitpic skill install --dir DIR       # or an explicit skills directory
gitpic skill path                    # show where it would be written
gitpic skill print                   # dump the document to stdout
```

It detects `~/.claude/skills` and `~/.codex/skills` (honouring
`CLAUDE_CONFIG_DIR` / `CODEX_HOME`), and prompts before writing. Pass `--yes`,
`--agent`, or `--dir` in scripts and CI — without a terminal it errors instead
of guessing.

**As a Claude Code plugin**

```
/plugin marketplace add tarnish233/gitpic-cli
/plugin install gitpic@gitpic
```

**As a Codex plugin**

```bash
codex plugin marketplace add tarnish233/gitpic-cli
codex plugin add gitpic@gitpic
```

Always call `gitpic` with `--json` from an agent, plus `--no-copy` on the upload
commands. `--no-copy` is meaningful only on the upload path (`gitpic <files>`,
`--stdin`, `paste`); every other subcommand rejects it as a `USAGE` error (exit 2),
so `gitpic doctor --json --no-copy` fails.

`gitpic doctor` exits non-zero when any check fails; scripts should still parse
`config_ok`, `token_valid`, and `repo_writable` from its JSON report. An unhealthy
report also carries an `error` object in the same shape as every other subcommand
(present exactly when `ok` is false), so "branch missing" (8) and "no write
permission" (7) can be told apart from stdout alone — no need to depend on the exit
status, which piping to a parser (`… | jq`) replaces with the parser's own. Argument
parsing failures also use the standard `{ "ok": false, "error": ... }` envelope when
`--json` is present.

## Changelog

See [CHANGELOG.md](./CHANGELOG.md).

## License

MIT

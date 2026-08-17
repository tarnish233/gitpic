# gitpic

[简体中文](./README.md) | **English**

Upload local or clipboard images to a GitHub repository (used as an image host)
and get a Markdown link — instantly copied to your clipboard.

Human-friendly on the terminal, machine-friendly (`--json`) for scripts and AI
agents. Single static binary, no runtime required.

## Demo

```console
$ gitpic init
gitpic init — configure your GitHub image host

Credentials come from `gh auth token`, or from GITPIC_TOKEN.
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

**Homebrew (macOS/Linux, recommended — adds it to `PATH` and installs shell completions)**

```bash
brew install tarnish233/tap/gitpic
```

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

**From source** (needs Rust)

```bash
cargo install --git https://github.com/tarnish233/gitpic-cli
```

## Setup

Credentials come from the [GitHub CLI](https://cli.github.com) by default, so
**no secret is stored in the config file**:

```bash
gh auth login          # once; the token lives in your system keyring
gitpic init            # asks for repo/branch/link kind only, never a token
```

`gitpic` takes the first credential it can get, in this order:

| Order | Source | For |
|---|---|---|
| 1 | `GITPIC_TOKEN` env var | CI, containers, machines without `gh` |
| 2 | `github.token` in the config file | Legacy; still supported |
| 3 | `gh auth token` | Default; keeps the config file secret-free |

A `token` in the config wins over `gh`: explicit configuration beats
auto-detection, so upgrading gitpic never silently changes which account
uploads. To switch to `gh`, delete that line — `gitpic doctor` reports which
source is actually in use.

> **Scope caveat**: `gh`'s OAuth token typically carries
> `gist, read:org, repo, workflow` — *broader* than what writing to one image
> repo needs. This keeps the secret out of a syncable file; it does not narrow
> the token's scope. For least privilege, use a fine-grained token limited to the
> one repo with `Contents: Read/Write` and pass it via `GITPIC_TOKEN`.

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
link_kind     = "cdn"   # cdn (jsDelivr) | raw
dedup         = true
auto_copy     = true
compress      = false
max_width     = 0        # 0 = keep original
quality       = 82       # JPEG quality when compressing (1-100)
```

Or via environment variables (nothing written to disk; they override the config
file, but CLI flags override them):

```bash
export GITPIC_TOKEN="github_pat_xxx"   # fine-grained token, Contents: Read/Write
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
cat img.png | gitpic --stdin --name shot.png
gitpic doctor                    # verify token + repo access
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
gitpic config get                        # token is redacted
gitpic config set github.repo owner/name
gitpic config set upload.link_kind raw
gitpic config set upload.compress true
gitpic config set upload.max_width 1600
gitpic config set upload.quality 82
gitpic config edit                       # open the file in $EDITOR
```

`path_template` placeholders: `{year} {month} {day} {hash} {hash8} {name} {ext}`

Key names in the config file are validated strictly: a misspelled key or section
(`dedupe`, `[uplaod]`) is a `CONFIG_INVALID` error pointing at the offending line
rather than a value that is silently ignored. `gitpic config path` and
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
`gitpic` version you are running — re-run this after `brew upgrade gitpic` to
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

Always call `gitpic` with `--json --no-copy` from an agent.

`gitpic doctor` exits non-zero when any check fails; scripts should still parse
`config_ok`, `token_valid`, and `repo_writable` from its JSON report. Argument
parsing failures also use the standard `{ "ok": false, "error": ... }` envelope
when `--json` is present.

## Changelog

See [CHANGELOG.md](./CHANGELOG.md).

## License

MIT

<p align="center">
  <img src="./docs/assets/icon.png" alt="GitPic" width="128">
</p>

<h1 align="center">gitpic</h1>

<p align="center">
  Upload a local or clipboard image to a GitHub repository used as an image host, get a
  Markdown link, and have it copied to your clipboard.
</p>

<p align="center">
  <a href="./README.md">简体中文</a> · <strong>English</strong>
</p>

The menu-bar app and the command line are two faces of one thing: same version, same
config, same upload history. Credentials come from the GitHub CLI (`gh`), and **no secret
is ever stored in the config file**.

## GitPic.app (macOS menu bar)

```bash
brew install gh && gh auth login        # prerequisite, once
brew install tarnish233/tap/gitpic      # the app, plus the terminal command
```

Use the menu to pick a file, or upload whatever is on the clipboard — the link goes
straight to the clipboard, and both success and failure are reported as system
notifications. The settings window has four panes: 图床
(repository, connectivity test), 上传 (path template, link form, compression), 历史
(history, with thumbnails and one-click copy), and 关于.

To get started, open the settings window and fill in owner / repo / branch — or run
`gitpic init` in a terminal.

> Apple Silicon only, macOS 14+. The app is locally signed and not notarised by Apple —
> installing with brew clears the quarantine attribute for you. If you install by hand
> from the [releases page](https://github.com/tarnish233/gitpic/releases), open
> `GitPic-<version>-macos-arm64.dmg`, drag GitPic across to Applications, and then clear
> the quarantine yourself or it will not open:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/GitPic.app
> ```

## Command line

**Installing the app already gives you the command line.** The cask links the `gitpic`
embedded in the app to `$(brew --prefix)/bin/gitpic` and generates bash, zsh and fish
completions — the terminal and the app run the same file, so upgrading the app *is*
upgrading the command and the two cannot be at different versions. Config and history are
shared too: change the repository in the app and the terminal sees it immediately, and
the other way round.

For the command line alone, or on Linux / Intel Mac / CI:

```bash
brew install tarnish233/tap/gitpic_cli
```

**Do not install both.** They compete for the same `bin/gitpic` and the same three
completions, and whichever goes second skips linking (a formula installed second ends
with `brew link` failing). Uninstall one before switching.

Other ways: download the archive for your platform from the
[releases page](https://github.com/tarnish233/gitpic/releases) and unpack `gitpic`
(macOS, Linux and Windows are all built by CI on `v*` tags; on macOS run
`xattr -d com.apple.quarantine ./gitpic`), or build from source with
`cargo install --path .` (needs Rust 1.88+).

Homebrew installs all three completions for you (reopen the terminal for zsh). For a
manual install, generate them yourself: `gitpic completion zsh > ~/.zfunc/_gitpic`, and
likewise for bash and fish.

### Usage

```bash
gitpic screenshot.png            # upload → print Markdown → copy to clipboard
gitpic a.png b.png               # several at once
gitpic paste                     # upload the image on the clipboard
cat img.png | gitpic --stdin     # extension decided from the bytes
gitpic list                      # recent uploads (local history)
gitpic doctor                    # check gh auth and repository permissions
gitpic completion zsh            # print a completion script
gitpic skill install             # install the agent skill (below)

gitpic photo.jpg -q -f url       # print the URL only
gitpic photo.jpg --json          # structured output (scripts / agents)
gitpic photo.jpg --link raw      # raw.githubusercontent.com instead of jsDelivr

gitpic big.png --compress                    # compress before uploading
gitpic big.png --compress --max-width 1600   # resize to width <= 1600
gitpic big.jpg --compress --quality 80       # JPEG quality
```

### Config

```bash
gitpic init                              # interactive setup
gitpic config get                        # show everything
gitpic config set github.repo owner/name # one key, or several KEY VALUE pairs
gitpic config path                       # where the file is
gitpic config edit                       # open it in $EDITOR
```

Config lives at `~/.config/gitpic/config.toml` (honours `$XDG_CONFIG_HOME`), history at
`~/.local/share/gitpic/history.jsonl` (honours `$XDG_DATA_HOME`). There is no token key
in the config, which is what makes the file safe to keep in a dotfiles repo:

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
auto_copy     = true    # copy after upload; the app honours it too (`--json` / `--quiet` never copy)
compress      = false
max_width     = 0       # 0 = no resizing
quality       = 82      # JPEG quality when compressing (1-100)
```

`path_template` placeholders: `{year} {month} {day} {hash} {hash8} {name} {ext}`

The upload target can also be overridden by environment variables (never credentials):
`GITPIC_REPO`, `GITPIC_OWNER`, `GITPIC_BRANCH`, `GITPIC_LINK`. Precedence is
**flags > environment > config file**.

Key names are validated strictly: a misspelled key or table (`dedupe`, `[uplaod]`) is
reported as `CONFIG_INVALID` naming the rejected key, rather than being ignored in
silence. `gitpic config path` and `config edit` still work in that state, so you can fix
the file.

### Credentials

`gitpic` calls `gh auth token` every time it needs GitHub; the token lives in the system
keyring. `GITPIC_TOKEN` and a `github.token` config key are both unsupported — upgrading
from an older version, delete the `token` line and run `gh auth login` once, or you will
get `CONFIG_INVALID`.

> A `gh` OAuth token may be broader than "write files to one image-host repo" needs. Use
> `gh auth status` to see which account is in play.

### Exit codes and `--json`

`0` ok · `1` other error · `2` usage · `3` config missing · `4` auth failed · `5` network
· `6` local file not found · `7` permission denied · `8` remote resource not found ·
`9` rate limited · `10` config file unusable.

`3` means "nothing configured yet" (run `gitpic init`); `10` means "configured, but the
file is broken" (run `gitpic config edit`). They need different fixes, so they get
different codes.

`--json` returns an envelope carrying `ok` on every subcommand, failures included, with
three exceptions: interactive `gitpic init` **refuses** it; `gitpic completion <shell>`
ignores it and prints the shell script; `gitpic config edit` hands stdout to `$EDITOR`.
Argument-parsing errors also come back as `{ "ok": false, "error": … }` under `--json`.

## Agent skill

`gitpic` ships an [Agent Skill](./skills/gitpic/SKILL.md) telling Claude Code, Codex and
others how to drive it. The skill document is compiled into the binary, so the version you
install always matches the `gitpic` you are running.

```bash
gitpic skill install                 # choose among the agents it detects
gitpic skill install --agent codex   # or name one
gitpic skill install --dir DIR       # or any skills directory
gitpic skill print                   # write it to stdout
```

It detects `~/.claude/skills` and `~/.codex/skills` (honouring `CLAUDE_CONFIG_DIR` /
`CODEX_HOME`) and asks before writing. In scripts and CI pass `--yes`, `--agent` or
`--dir` — with no terminal it errors rather than guessing for you.

It can also be installed as a plugin:

```
/plugin marketplace add tarnish233/gitpic      # Claude Code
/plugin install gitpic@gitpic
```

```bash
codex plugin marketplace add tarnish233/gitpic  # Codex
codex plugin add gitpic@gitpic
```

**Two rules for agents**: always pass `--json`, and add `--no-copy` to uploads.
`--no-copy` only means something on the upload paths (`gitpic <file>`, `--stdin`,
`paste`); every other subcommand rejects it as `USAGE` (exit 2) — `gitpic doctor --json
--no-copy` does fail.

`gitpic doctor` exits non-zero when any check fails, but a script should still parse
`config_ok`, `token_valid` and `repo_writable` out of the JSON: an unhealthy report
carries the same shape of `error` object as every other subcommand, so "branch does not
exist" (8) and "no write permission" (7) are distinguishable from stdout alone, without
relying on the exit code — pipe into `jq` and the exit code becomes `jq`'s own.

## Changelog

See [CHANGELOG.md](./CHANGELOG.md); the Chinese version is
[CHANGELOG.zh-CN.md](./CHANGELOG.zh-CN.md).

## License

MIT

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
config, same upload history. There is one way to authenticate — `gitpic auth login`
(browser authorisation) — and **no secret is ever stored in the config file**.

## GitPic.app (macOS menu bar)

```bash
brew install tarnish233/tap/gitpic      # the app, plus the terminal command
```

Use the menu to pick a file, or upload whatever is on the clipboard — the link goes
straight to the clipboard, and both success and failure are reported as system
notifications. **You can also select images in Finder and right-click 「GitPic
上传至图床」** (the app is launched if it is not running; the 「Finder 右键」 switch on the
上传 pane takes the item back out of the menu). The settings window has four panes: 图床
(account, repository, connectivity test), 上传 (path template, link form, compression, Finder
right-click), 历史 (history, with thumbnails and one-click copy), and 关于.

**Nothing needs a terminal to get started.** Open the settings window → 图床 → 「使用
GitHub 登录」: the one-time code appears in the window and the browser opens on its own.
Once authorised, the dropdown below lists the repositories you can upload to — pick one and
press 保存 to write it. The list is the only way in, and the branch comes with the
repository (GitHub's default, not an assumed `main`), so neither a misspelled repository
name nor a `master` repository configured for `main` is reachable any more.

The terminal route is the same thing, in one command: `gitpic auth login` ends by listing
the repositories you can upload to. Both share one credential and one config.

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
gitpic auth login                # authorise in the browser
gitpic doctor                    # check auth and repository permissions
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
gitpic config get                        # show everything
gitpic config set github.repo owner/name # one key, or several KEY VALUE pairs
gitpic config path                       # where the file is
gitpic config edit                       # open it in $EDITOR
```

The image host is chosen at the end of `gitpic auth login` (in the app: the dropdown on
the 图床 pane). To change it later, `gitpic config set github.repo owner/name` —
`gitpic repos` lists the candidates with each one's default branch. **Changing the
repository does not change `github.branch`**: if the new target's default branch is not
the one already configured, set `github.branch` in the same breath, or every upload will
target a ref that does not exist. `gitpic branches` is what shows that:

```bash
$ gitpic branches --repo tarnish233/GitPic-legacy
  master
  tmp-verify-sha
  note: `main` is configured but not in this list, so every upload will fail on a ref
        that does not exist — `gitpic config set github.branch <one of the above>`
```

Uploads go through the Contents API, which **cannot create a branch** — the target ref
has to exist already. So the legal values for `github.branch` are exactly that list,
which is why the app's 图床 pane makes the branch a dropdown too. Protected branches are
labelled but never filtered out: protected does not mean unwritable, and the rules may
well permit this account.

Config lives at `~/.config/gitpic/config.toml` (honours `$XDG_CONFIG_HOME`), history at
`~/.local/share/gitpic/history.jsonl` (honours `$XDG_DATA_HOME`). There is no token key
in the config, which is what makes the file safe to keep in a dotfiles repo — but
**`auth.toml` in the same directory is not**: that one holds the token `gitpic auth login`
stored (see below):

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

```bash
gitpic auth login              # authorise in the browser (GitHub device flow)
gitpic auth login --scope repo # only needed for a private image host
gitpic auth status             # whose credential this is
gitpic auth logout             # remove it
gitpic repos                   # which repositories this credential can upload to
gitpic branches                # which branches the configured repository has
```

**That is the only way in.** The token lives in `~/.config/gitpic/auth.toml` at mode 0600,
kept apart from `config.toml` — which `gitpic config get` prints in full and `config edit`
opens in `$EDITOR`, so it is no place for a secret.

`gitpic auth login` runs GitHub's device flow: it prints a one-time code, you enter it at
<https://github.com/login/device>, done. No client secret anywhere, and no key for you to
carry by hand.

The authorisation asks for the **`public_repo`** scope — write access to your **public**
repositories. That is the narrowest scope that can do gitpic's one job, because GitHub has
no OAuth scope meaning "this one repository", and it is all that is needed: jsDelivr, which
`link_kind = "cdn"` points at, serves only public repositories.

A **private** image host needs `gitpic auth login --scope repo`. `repo` is broad — read and
write on every repository you can reach — which is why it is not the default. Only
`link_kind = "raw"` links resolve from a private repository anyway.

`gitpic auth login` ends by listing the repositories the credential can upload to and
saving the one you pick, default branch included — there is no second command to run.
`gitpic repos` is for looking again later (default branch, private, pushable), and
`gitpic branches` for the branches of one repository.

Point the flow at your own OAuth App with `GITPIC_CLIENT_ID` or
`gitpic auth login --client-id <id>`; the scope has `GITPIC_SCOPE` as its equivalent.

> Why not a GitHub App? A GitHub App's permissions are narrower — `Contents: write` on one
> chosen repository, far more precise than `public_repo`. It lost on the **flow**: a GitHub
> App's user token can only reach repositories the app has been *installed* on, and the
> device flow does not perform an installation. Every user would authorise in the terminal
> and then have to visit a browser again to install the app and select repositories. One
> login that immediately yields a list to choose from is worth more than a tighter grant
> half the users never finish.

Three routes are **removed**, not merely discouraged:

- **`gh auth token`.** A second source meant a second identity: on a machine with a `gh`
  session, which account an upload was attributed to depended on whether a file happened
  to exist, and every credential failure had two remedies to explain. It also made `gh` a
  de-facto dependency for the one job gitpic now does itself in a single command.
- **A pasted token (`--with-token`).** A token that travels by hand ends up in shell
  history, in a scrollback, in a chat log — and it let an agent ask a user to paste a
  credential into a conversation. The device flow moves no secret through human hands.
- **`GITPIC_TOKEN` and a `github.token` config key.** A credential in the environment
  leaks into process listings and CI logs; one in `config.toml` gets printed by
  `gitpic config get`. A `token` line still in the file is a `CONFIG_INVALID` error —
  delete it.

With one source left there is no provenance to report: neither `doctor` nor `auth status`
carries a `token_source` field any more.

### Exit codes and `--json`

`0` ok · `1` other error · `2` usage · `3` config missing · `4` auth failed · `5` network
· `6` local file not found · `7` permission denied · `8` remote resource not found ·
`9` rate limited · `10` config file unusable.

`3` means "nothing configured yet" (run `gitpic auth login`, or
`gitpic config set github.repo owner/name`); `10` means "configured, but the file is
broken" (run `gitpic config edit`). They need different fixes, so they get different
codes.

`--json` returns an envelope carrying `ok` on every subcommand, failures included, with
three exceptions. `gitpic auth login --json` is a **stream**: one complete JSON object per
line, each tagged with `event` (`code` carries the one-time code; the last line is always
`done` or `error`). It has to be — the code must reach the caller minutes before the
outcome exists, and one envelope can only be written once. That is what lets the app run
the login inside its settings window, it is the only place "one invocation, one envelope"
does not hold, and it is why neither a script nor an agent should call it. The other two:
`gitpic completion <shell>` ignores `--json` and prints the shell script;
`gitpic config edit` is **refused** under `--json` (`USAGE`), because it hands stdout to
the editor and cannot also be one JSON document — read the configuration with `gitpic
config get --json` and change it with `gitpic config set`. The editor is `$VISUAL`, then
`$EDITOR`, then `vi`, and a value with arguments (`EDITOR="code --wait"`) works.
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

`token_valid` and `repo_writable` have three values: `true`, `false`, and `null` for
**not checked**. The two GitHub probes only run when `config_ok` is true, so on a machine
that has run `gitpic auth login` but not yet chosen a repository they are `null` — they
used to be `false`, which was a verdict on a credential nothing had looked at, while
`gitpic auth status` on the same machine reported it working.

## Changelog

See [CHANGELOG.md](./CHANGELOG.md); the Chinese version is
[CHANGELOG.zh-CN.md](./CHANGELOG.zh-CN.md).

## License

MIT

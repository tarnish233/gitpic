---
name: gitpic
description: >-
  Upload a local or clipboard image to a GitHub repo (image host) and return a
  Markdown link. Use when the user wants to "upload an image", "turn this image
  into a link", "host an image", "get a markdown link for a screenshot",
  "把图片上传图床", or "生成图片 markdown 链接". Requires the `gitpic` CLI installed
  plus GitHub CLI authenticated with `gh auth login` (install gitpic via
  `brew install tarnish233/tap/gitpic_cli`).
---

# gitpic — GitHub image host uploader

`gitpic` uploads an image to a GitHub repository (used as an image host) and
prints a Markdown link. It is human/agent dual-mode: always pass `--json` when
calling it programmatically, and `--no-copy` on the upload commands.

## Installation

First check whether the CLI exists: `command -v gitpic`. If it is missing,
install it one of these ways, then verify with `gitpic --version`:

- Homebrew (macOS/Linux, recommended — also auto-installs shell completions):
  ```bash
  brew install tarnish233/tap/gitpic_cli
  ```
  The formula is `gitpic_cli`; the command it installs is `gitpic`.
- Prebuilt binary: download the matching asset from the latest
  [release](https://github.com/tarnish233/gitpic/releases), extract, and put
  `gitpic` on `PATH`. On macOS clear the quarantine flag first:
  ```bash
  xattr -d com.apple.quarantine ./gitpic 2>/dev/null; chmod +x ./gitpic
  ```
- From source (needs Rust 1.88 or newer):
  ```bash
  cargo install --git https://github.com/tarnish233/gitpic
  ```

Also require `command -v gh` and a successful `gh auth status`. `gitpic` obtains
credentials only from `gh auth token`; if needed, ask the user to run
`gh auth login`. Never ask the user to paste a token into the conversation.

## 0. Preflight

Run the health check before the first upload in a session:

```bash
gitpic doctor --json
```

Parse stdout JSON. An unhealthy report carries an `error` object in the same
`{ code, message }` shape every other subcommand uses, and exits non-zero with the
same code. **Read `error.code`, not the exit status** — piping the output to a
parser (`gitpic doctor --json | jq`) replaces the exit status with the parser's own,
and some harnesses never surface it at all. `error` is present on exactly the
reports where `ok` is false.

Require `config_ok`, `token_valid`, and `repo_writable` to be `true`. If `config_ok`
is false, tell the user to either run `gitpic init` or set `GITPIC_REPO=owner/name`
(and optionally `GITPIC_BRANCH`, `GITPIC_LINK=cdn|raw`), then stop. If `token_valid`
is false and `repo_writable` is also false, tell the user to run `gh auth login` —
gitpic takes its credential only from `gh auth token` — then stop.

`repo_writable` means **both** that the token may push to the repository **and**
that the target branch exists. When it is false, read `error.code` to tell the two
apart: `REMOTE_NOT_FOUND` (8) means the branch is missing — the user should create
it or change `github.branch` — while `PERMISSION_DENIED` (7) means the token lacks
Contents read/write on the repository. `error.message` says which, and `detail`
carries the same text.

The three checks are probed independently, so read them together before acting. If
`token_valid` is false **but `repo_writable` is true** and `error.code` is
`NETWORK`, the credential is fine and GitHub's `/user` endpoint — which uploads
never call — is simply unreachable. Retry; do not send the user to
`gh auth login`, which cannot fix it. Treat `token_valid: false` as a credential
problem only when `repo_writable` is also false.

`branch_protected: true` is a caveat, not a failure: the branch has protection
rules, which may still permit this account, so a report can be `ok: true` with it
set. It is the usual explanation when an upload is nevertheless refused with
`PERMISSION_DENIED` or a 409/422 after every preflight check passed — if that
happens, say so rather than retrying.

The report's compatibility field `token_source` is `"gh"` when a credential was
obtained and `null` otherwise. `gitpic init` never accepts a token interactively.

## 1. Upload a local image

```bash
gitpic "/absolute/path/to/image.png" --json --no-copy
```

Parse stdout JSON and return `results[0].markdown` to the user. Other useful
fields: `url`, `raw_url`, `html`, `path`, `deduped`.

## 2. Upload multiple images

```bash
gitpic "/abs/a.png" "/abs/b.jpg" --json --no-copy
```

`results` is an array with one record per file.

## 3. Upload raw bytes (no file path)

```bash
cat image.png | gitpic --stdin --json --no-copy
```

Use this when you only have image bytes (e.g. a screenshot buffer). The extension
is derived from the bytes themselves, so JPEG data is never published at a `.png`
path — `--name` only supplies the filename stem, and its extension is ignored.
Pass `--name` when the bytes are a format gitpic cannot recognise; without it that
is a `USAGE` error rather than a guess.

## 4. Upload an image explicitly requested from the clipboard

```bash
gitpic paste --json --no-copy
```

Use `paste` only when the user explicitly asks for the current clipboard image
and the execution environment has clipboard access. Otherwise prefer a local
absolute path or stdin.

## 5. Other useful commands

```bash
gitpic big.png --compress --max-width 1600 --json --no-copy   # shrink before upload
gitpic big.jpg --compress --quality 80 --json --no-copy       # JPEG quality (1-100)
gitpic photo.png --link raw --json --no-copy                  # force raw GitHub URL
gitpic list --json                                            # recent uploads (history)
```

## Output schema (success)

```json
{ "ok": true, "results": [ {
  "name": "shot", "url": "https://cdn.jsdelivr.net/gh/owner/repo@main/images/...",
  "raw_url": "https://raw.githubusercontent.com/owner/repo/main/images/...",
  "markdown": "![shot](https://...)", "html": "<img src=\"...\" alt=\"shot\">",
  "path": "images/2026/07/ab12cd34-shot.png", "sha": "…", "size": 20481,
  "deduped": false, "output": "![shot](https://...)" } ] }
```

## Error handling (exit code / error.code)

| exit | error.code          | agent action                                      |
|------|---------------------|---------------------------------------------------|
| 1    | GENERAL             | unexpected failure — report `error.message`        |
| 2    | USAGE               | fix the invocation                                |
| 3    | CONFIG_MISSING      | run `gh auth login` or configure the target repo   |
| 4    | AUTH_FAILED         | credential invalid/expired — `gh auth login`      |
| 5    | NETWORK             | retry once, then report                           |
| 6    | NOT_FOUND           | check the local input file path                   |
| 7    | PERMISSION_DENIED   | check token Contents permission/repo access       |
| 8    | REMOTE_NOT_FOUND    | check GitHub repository, branch, and remote path  |
| 9    | RATE_LIMITED        | wait or ask the user before retrying later        |
| 10   | CONFIG_INVALID      | the config file is broken — tell the user to run `gitpic config edit`; `error.message` names the file plus the rejected key or the parser's complaint, but not a line number |

Error JSON: `{ "ok": false, "error": { "code": "AUTH_FAILED", "message": "…" } }`
`gitpic doctor` carries the same `error` object alongside its report fields, so the
code is always on stdout — never depend on the exit status alone.

Do not confuse 3 with 10: `CONFIG_MISSING` means nothing is configured yet, so
`gitpic init` is the fix. `CONFIG_INVALID` means the file exists but has bad syntax
or an unknown key — running `init` would not fix it, and retrying will loop.

## Partial success (multiple images)

Uploads run serially. If an image fails after earlier ones succeeded, the exit
code is that of the failure, but `results` still lists every image that did
upload — those links are live and must not be discarded:

```json
{ "ok": false,
  "results": [ { "name": "one", "markdown": "![one](https://…)", "…": "…" } ],
  "error": { "code": "RATE_LIMITED", "message": "…" } }
```

Report the successful links, then handle `error.code` per the table above for the
remaining images. When no image uploaded, the plain error JSON above is returned
instead — `results` is never present and empty.

## Constraints

- Always pass `--json` for programmatic calls, and `--no-copy` on the upload
  commands only (`gitpic <files>`, `--stdin`, `paste`). Every other subcommand
  **rejects** `--no-copy` with a `USAGE` error (2), so never add it to `doctor`,
  `list`, `config`, `skill` or `completion`. The same goes for the other
  upload-only options (`--link`, `--format`, `--name`, `--path`, `--compress`,
  `--no-compress`, `--max-width`, `--quality`, `--stdin`). `--name` is for
  stdin, paste, or a single file; with two or more files it is a `USAGE` error.
  It supplies only the filename *stem* in all three cases — the extension always
  follows the image bytes, so `--name shot` or `--name shot.png` on JPEG bytes
  both publish `shot.jpg`. Never rely on `--name` to set the extension.
- `--json` produces an `ok`-bearing envelope on stdout for every subcommand,
  failures included, with three exceptions — none of which an agent should call:
  `gitpic init` **rejects** `--json` (it is interactive; use `GITPIC_REPO` or
  `gitpic config set` instead), `gitpic completion <shell>` ignores it and prints
  the raw shell script, and `gitpic config edit` ignores it and hands stdout to
  `$EDITOR` (defaulting to `vi`), whose terminal output is not JSON.
- Only access the clipboard when the user explicitly requests it.
- Use absolute file paths.
- Never print the GitHub token in the conversation.
- Prefer `--link cdn` (default) unless the user asks for raw GitHub links. A
  freshly uploaded file can take a moment to appear on jsDelivr; `raw_url` in the
  same result is served by GitHub immediately.
- A cdn link cannot express a branch containing `/` (jsDelivr encodes the ref as
  `repo@branch/path`, so the boundary becomes ambiguous). When `github.branch` has
  a `/` and the link kind is cdn, the upload is refused with `USAGE` (2) **before
  anything is committed** — retry with `--link raw`, which puts the branch in its
  own path segment and works.

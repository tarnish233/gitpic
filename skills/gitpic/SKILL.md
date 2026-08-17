---
name: gitpic
description: >-
  Upload a local or clipboard image to a GitHub repo (image host) and return a
  Markdown link. Use when the user wants to "upload an image", "turn this image
  into a link", "host an image", "get a markdown link for a screenshot",
  "把图片上传图床", or "生成图片 markdown 链接". Requires the `gitpic` CLI installed
  and a GitHub token configured (install via `brew install tarnish233/tap/gitpic`).
---

# gitpic — GitHub image host uploader

`gitpic` uploads an image to a GitHub repository (used as an image host) and
prints a Markdown link. It is human/agent dual-mode: always pass `--json` and
`--no-copy` when calling it programmatically.

## Installation

First check whether the CLI exists: `command -v gitpic`. If it is missing,
install it one of these ways, then verify with `gitpic --version`:

- Homebrew (macOS/Linux, recommended — also auto-installs shell completions):
  ```bash
  brew install tarnish233/tap/gitpic
  ```
- Prebuilt binary: download the matching asset from the latest
  [release](https://github.com/tarnish233/gitpic-cli/releases), extract, and put
  `gitpic` on `PATH`. On macOS clear the quarantine flag first:
  ```bash
  xattr -d com.apple.quarantine ./gitpic 2>/dev/null; chmod +x ./gitpic
  ```
- From source (needs Rust):
  ```bash
  cargo install --git https://github.com/tarnish233/gitpic-cli
  ```

## 0. Preflight

Run the health check before the first upload in a session:

```bash
gitpic doctor --json
```

Parse stdout JSON. Require `config_ok`, `token_valid`, and `repo_writable` to be
`true`; an unhealthy report also has a non-zero exit status. If `config_ok` is
false, tell the user to either run `gitpic init` or set
`GITPIC_REPO=owner/name` (and optionally `GITPIC_BRANCH`,
`GITPIC_LINK=cdn|raw`), then stop. If `token_valid` is false, tell the user to
run `gh auth login` — gitpic takes its credential from `gh auth token` — or to
set `GITPIC_TOKEN`; then stop. If `repo_writable` is false, ask them to check
the target repository and grant Contents read/write permission, then stop.

The report's `token_source` field (`env` / `config` / `gh`) says where the
credential came from. Never ask the user to paste a token into the conversation;
prefer `gh auth login`, which keeps it in the OS keyring.

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
cat image.png | gitpic --stdin --name shot.png --json --no-copy
```

Use this when you only have image bytes (e.g. a screenshot buffer).

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
| 2    | USAGE               | fix the invocation                                |
| 3    | CONFIG_MISSING      | no credential or repo — `gh auth login` / configure |
| 4    | AUTH_FAILED         | credential invalid/expired — `gh auth login`      |
| 5    | NETWORK             | retry once, then report                           |
| 6    | NOT_FOUND           | check the local input file path                   |
| 7    | PERMISSION_DENIED   | check token Contents permission/repo access       |
| 8    | REMOTE_NOT_FOUND    | check GitHub repository, branch, and remote path  |
| 9    | RATE_LIMITED        | wait or ask the user before retrying later        |

Error JSON: `{ "ok": false, "error": { "code": "AUTH_FAILED", "message": "…" } }`

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

- Always pass `--json` and `--no-copy` for programmatic calls.
- Only access the clipboard when the user explicitly requests it.
- Use absolute file paths.
- Never print the GitHub token in the conversation.
- Prefer `--link cdn` (default) unless the user asks for raw GitHub links.

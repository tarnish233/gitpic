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
`true`. `doctor` exits non-zero when a check fails, with the same code as the
report's `code` field, so gating on either the exit status or `ok` works.
If `config_ok` is
false, tell the user to either run `gitpic init` or
set env vars `GITPIC_TOKEN` and `GITPIC_REPO=owner/name` (and optionally
`GITPIC_OWNER`, `GITPIC_BRANCH`, `GITPIC_LINK=cdn|raw`), then stop.
If `token_valid` is false,
ask the user to update the token. If `repo_writable` is false, ask them to check
the target repository and grant Contents read/write permission, then stop.

`doctor` prints only the report, never a separate error envelope, so stdout in
`--json` mode is always exactly one JSON object.

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

## Output schema (`doctor`)

```json
{ "ok": false, "config_ok": true, "token_valid": false, "repo_writable": false,
  "code": "AUTH_FAILED", "detail": "GitHub auth failed (401 …)" }
```

`login` appears when the token resolves; `code` and `detail` only when a check
fails. `code` matches the exit status, and `detail` may contain the raw GitHub
response body, including newlines.

## Error handling (exit code / error.code)

| exit | error.code          | agent action                                      |
|------|---------------------|---------------------------------------------------|
| 1    | GENERAL             | unexpected — report the message to the user        |
| 2    | USAGE               | fix the invocation                                |
| 3    | CONFIG_MISSING      | ask user to configure token/repo                  |
| 4    | AUTH_FAILED         | token invalid/expired, or forbidden — ask to update |
| 5    | NETWORK             | retry once, then report                           |
| 6    | NOT_FOUND           | check the local input file path                   |
| 7    | PERMISSION_DENIED   | token works but lacks push — grant Contents read/write |

These seven are the complete set. Two caveats when matching on them:

- `PERMISSION_DENIED` currently comes only from `doctor`, which inspects the
  repo's reported permissions. An upload that gets a 403 still reports
  `AUTH_FAILED`, because GitHub also uses 403 for rate limiting.
- A 404 from GitHub (missing repo or branch) arrives as `NOT_FOUND`, same as a
  missing local file. Read `error.message` to tell them apart.

Error JSON: `{ "ok": false, "error": { "code": "AUTH_FAILED", "message": "…" } }`

## Constraints

- Always pass `--json` and `--no-copy` for programmatic calls.
- Only access the clipboard when the user explicitly requests it.
- Use absolute file paths.
- Never print the GitHub token in the conversation.
- Prefer `--link cdn` (default) unless the user asks for raw GitHub links.

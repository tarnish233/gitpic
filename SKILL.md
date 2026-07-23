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
`true`. If `config_ok` is false, tell the user to either run `gitpic init` or
set env vars `GITPIC_TOKEN` and `GITPIC_REPO=owner/name` (and optionally
`GITPIC_BRANCH`, `GITPIC_LINK=cdn|raw`), then stop.

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
cat image.png | gitpic --stdin --name shot.png --json
```

Use this when you only have image bytes (e.g. a screenshot buffer).

## 4. Other useful commands

```bash
gitpic big.png --compress --max-width 1600 --json --no-copy   # shrink before upload
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

| exit | error.code       | agent action                          |
|------|------------------|---------------------------------------|
| 2    | USAGE            | fix the invocation                    |
| 3    | CONFIG_MISSING   | ask user to configure token/repo      |
| 4    | AUTH_FAILED      | token invalid/expired — ask to update |
| 5    | NETWORK          | retry once, then report               |
| 6    | NOT_FOUND        | check the file path                   |

Error JSON: `{ "ok": false, "error": { "code": "AUTH_FAILED", "message": "…" } }`

## Constraints

- Always pass `--json` and `--no-copy` (clipboard is meaningless for an agent).
- Use absolute file paths.
- Never print the GitHub token in the conversation.
- Prefer `--link cdn` (default) unless the user asks for raw GitHub links.

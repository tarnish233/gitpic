---
name: gitpic
description: >-
  Upload a local or clipboard image to a GitHub repo (image host) and return a
  Markdown link. Use when the user wants to "upload an image", "turn this image
  into a link", "host an image", "get a markdown link for a screenshot",
  "把图片上传图床", or "生成图片 markdown 链接". Requires the `gitpic` CLI installed
  and authenticated with `gitpic auth login` (install gitpic via
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

Authentication comes from `gitpic auth login` and nowhere else. There is no `gh`
fallback, no `GITPIC_TOKEN`, and no way to pass a token on a command line — so do not
probe for `gh`, do not suggest installing it, and do not ask the user for a token.
`gitpic doctor --json` answers the only question that matters.

When there is no credential, **hand the user the command and stop**:

```
gitpic auth login
```

You cannot run it for them. It prints a one-time code they have to type at
<https://github.com/login/device> and then waits for a browser, so running it yourself
would block on a code only they can enter. Its `--json` is not an envelope but a
line-per-event stream (see Constraints), so it is not the shape the rest of this
document's `--json` advice assumes either.

Once they say they are done, confirm with `gitpic auth status --json` — `ok` and
`token_valid` say whether the credential works, and the report also carries `login`,
`client_id`, `expires_at` and the credential's `path`. Then re-run the preflight.

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
reports where `ok` is false. The report also carries `login` (the account `/user`
confirmed, absent when that probe did not succeed) and `detail`, the same text as
`error.message`.

Require `config_ok`, `token_valid`, and `repo_writable` to be `true`. If `config_ok`
is false, run `gitpic repos --json` (§0b) and offer the user the repositories it lists —
`gitpic config set github.repo owner/name github.branch <that repo's default_branch>`
writes the choice (§0c lists the branches if the user wants one that is not the default), and `GITPIC_REPO=owner/name` (plus `GITPIC_BRANCH`,
`GITPIC_LINK=cdn|raw`) sets it for one run. Then stop. Set the branch from the listing
rather than leaving it: a repository whose default is `master` configured for `main`
fails every upload on a ref that is not there. If `token_valid`
is false and `repo_writable` is also false, hand the user `gitpic auth login` and stop.

`repo_writable: false` with `token_valid: true` usually means the repository is absent,
the credential cannot reach it, or the account lacks write access. Run `gitpic repos --json`
to tell those apart. If the repo is present with `can_push: false`, another login will not
repair the account's permissions. If it has `private: true`, do **not** widen the OAuth scope
and retry: GitPic's links carry no credential, so private repositories are rejected as image
hosts even when the Contents API write itself would be allowed. Ask the user to choose a
public repository instead.

`repo_writable` means **both** that the token may push to the repository **and**
that the target branch exists. When it is false, `error.code` narrows it down but does
not settle it — read `error.message` too:

- `PERMISSION_DENIED` (7): the repository answered, and GitHub reports no push or admin
  permission. The app's access to that repository, or its Contents read/write
  permission, is what needs fixing.
- `REMOTE_NOT_FOUND` (8): **two** causes, told apart by the message. `target branch does
  not exist on the remote` means the repository is fine and only the ref is absent —
  create it or change `github.branch`. A message quoting GitHub's own 404 (`GitHub
  repository, branch, or remote path not found`) means the repository is invisible to the
  app, which is the install/authorise case above; creating a branch will not help.

`detail` carries the same text as `error.message` either way.

The two GitHub checks are probed independently — and only when `config_ok` is true, so
read `config_ok` first. When they did not run at all, `token_valid` and `repo_writable`
are **`null`**, not `false`: that is the state of a machine that has logged in but not yet
chosen a repository, and `false` there was a claim about a credential nothing had looked
at — `gitpic auth status --json` on that same machine reports it working. `null` is not
`true`, so requiring `true` above is unaffected; what changes is that you must not read
`token_valid: null` as a reason to send the user to log in again. If
`token_valid` is false **but `repo_writable` is true** and `error.code` is
`NETWORK`, the credential is fine and GitHub's `/user` endpoint — which uploads
never call — is simply unreachable. Retry; do not send the user to
another login, which cannot fix it. Treat `token_valid: false` as a credential
problem only when `repo_writable` is also false.

`branch_protected: true` is a caveat, not a failure: the branch has protection
rules, which may still permit this account, so a report can be `ok: true` with it
set. It is the usual explanation when an upload is nevertheless refused with
`PERMISSION_DENIED` or a 422 after every preflight check passed — if that
happens, say so rather than retrying. A 409 ref conflict is `NETWORK` (5):
retry once, then report.

`detail` also carries non-fatal caveats, currently branch protection. Two setup states
are hard `USAGE` failures instead: any **private** repository, because neither emitted link
form authenticates its visitor; and `link_kind = "cdn"` with a `github.branch` containing
`/`, because jsDelivr cannot tell that branch apart from the file path. `doctor` reports the
same failure the upload path would rather than calling either configuration healthy.

There is one credential source, so the report carries no `token_source` field: a
credential either works (`token_valid: true`) or the user has not run `gitpic auth login`.
No subcommand accepts a token, and there is no `gitpic init` — the repository is chosen at
the end of `gitpic auth login`, which only a human can run.

## 0b. Which repository (only when the target is wrong or unset)

```bash
gitpic repos --json
```

```json
{ "ok": true, "complete": true, "repos": [
  { "owner": "octocat", "name": "img", "private": false,
    "default_branch": "main", "can_push": true } ] }
```

Every repository the credential can reach, alphabetical. Use it to answer "which repo
should this go to" instead of guessing an `owner/repo`, and to explain a
`REMOTE_NOT_FOUND` that a hand-typed target caused.

- `can_push: false` means the account cannot write there — offer it, do not silently drop
  it, but say so.
- `private: true` repositories are diagnostic rows only; do not offer them as image-host
  choices, because the returned URLs are unauthenticated and will not resolve for recipients.
- `complete: false` means the listing hit its page ceiling, so a repository the user names
  may exist without appearing. Say that rather than reporting it as absent.
- `default_branch` is what `github.branch` should be — do not assume `main`.

Set the target with `gitpic config set github.repo owner/name --json` (add
`github.branch <default_branch>` in the same call when it is not `main`).

## 0c. Which branch (only when the branch is wrong, or the user asks for another)

```bash
gitpic branches --json                        # the configured repository
gitpic branches --repo owner/name --json      # any repository
```

```json
{ "ok": true, "repo": "octocat/img", "configured": "main", "complete": true,
  "branches": [ { "name": "main", "protected": true },
                { "name": "images", "protected": false } ] }
```

Uploads go through the Contents API, which **cannot create a branch**. So the legal values
for `github.branch` are exactly the names in `branches`, and a value outside that list
fails every upload with `REMOTE_NOT_FOUND` — GitHub answers 404 for a missing ref, the same
as for a repository it cannot see, which is why guessing a branch name produces the least
informative failure gitpic has.

- `configured` is the branch an upload would use right now, resolved by the CLI (so it
  reflects `GITPIC_BRANCH`). When it is **not** in `branches`, that is the whole finding:
  say so and offer the listed names. Do not report it as a permissions problem.
- `protected: true` does **not** mean unwritable — the rules may permit this account. Never
  filter a protected branch out of what you offer. It is worth naming only when an upload
  has already failed with `PERMISSION_DENIED` or a 422 after every check passed.
- An empty `branches` with `ok: true` is a repository with no commits. The first upload
  creates the ref, so this is not an error and needs no fix.
- `complete: false` means the page ceiling was hit; a branch the user names may exist
  without appearing.

Change it with `gitpic config set github.branch <name> --json`.

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
path — `--name` supplies the filename stem, and its extension is ignored.

**Bytes gitpic cannot identify are the one exception**, because then there is
nothing to derive an extension from: `--name` must carry one and is honoured.
`--name shot.bin` works; `--name shot` and no `--name` at all are both a `USAGE`
error (2) rather than a guessed `.png`. So do not strip the extension when
retrying a stdin upload that asked for `--name`.

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
| 3    | CONFIG_MISSING      | hand the user `gitpic auth login`, or configure the target repo |
| 4    | AUTH_FAILED         | credential invalid/expired — hand the user `gitpic auth login` |
| 5    | NETWORK             | retry once, then report (includes a 409 ref conflict) |
| 6    | NOT_FOUND           | check the local input file path                   |
| 7    | PERMISSION_DENIED   | check token Contents permission/repo access       |
| 8    | REMOTE_NOT_FOUND    | check GitHub repository, branch, and remote path — `gitpic branches --json` (§0c) separates "the branch is not there" from "the repo is not there", which the 404 itself does not |
| 9    | RATE_LIMITED        | wait or ask the user before retrying later        |
| 10   | CONFIG_INVALID      | the config file is broken — tell the user to run `gitpic config edit`; `error.message` names the file plus the rejected key or the parser's complaint, but not a line number |

Error JSON: `{ "ok": false, "error": { "code": "AUTH_FAILED", "message": "…" } }`
`gitpic doctor` carries the same `error` object alongside its report fields, so the
code is always on stdout — never depend on the exit status alone.

Do not confuse 3 with 10. `CONFIG_MISSING` covers two "nothing is set up yet" states
and `error.message` says which: `missing target repo` is yours to fix with
`gitpic config set github.repo` or `GITPIC_REPO=owner/name`, while `no GitHub credential`
is fixed only by handing the user `gitpic auth login` — setting a repository there
reconfigures a target that was never the problem. `CONFIG_INVALID` means the file exists
but has bad syntax or an unknown key — neither of those commands fixes it, and retrying
will loop.

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
  commands only (`gitpic <files>`, `--stdin`, `paste`). Upload-only options
  (`--no-copy`, `--link`, `--format`, `--name`, `--path`, `--compress`,
  `--no-compress`, `--max-width`, `--quality`, `--stdin`, `--repo` except on
  `doctor`) are not accepted on other subcommands — clap rejects them, exit 2 —
  and they must be written **after** the subcommand: `gitpic paste --json
  --no-copy`, never `gitpic --no-copy paste`, which is a `USAGE` error (2).
  `--json`, `--quiet` and `--verbose` work on either side of it.
  `--name` is for stdin, paste, or a single file; with two or more files it is a
  `USAGE` error. It supplies only the filename *stem* in all three cases — the
  extension always follows the image bytes, so `--name shot` or `--name shot.png`
  on JPEG bytes both publish `shot.jpg`. Never rely on `--name` to set the
  extension — with one exception, `--stdin` over bytes gitpic cannot identify,
  where it is the only source there is and must include one (see §3).
  `gitpic config set` accepts `KEY VALUE` pairs in one invocation
  (`gitpic config set github.owner me github.repo pics --json`) and writes once;
  its `--json` envelope carries `changes` (one `{key, value}` per key, as stored),
  and the top-level `key`/`value` only when a single pair was given.
- `--json` produces an `ok`-bearing envelope on stdout for every subcommand,
  failures included, with three exceptions — none of which an agent should call.
  `gitpic auth login --json` is the one command whose `--json` is a **stream**: one
  complete JSON object per line, each tagged with `event`, the last line always `done` or
  `error`. Parsing its stdout as a single object fails on the first line, and only a
  human can type the one-time code anyway — hand the bare `gitpic auth login` to the user
  and then read `gitpic auth status --json`. `gitpic completion <shell>` ignores `--json`
  and prints the raw shell script. `gitpic config edit` **refuses** `--json` as `USAGE`:
  it hands stdout to an editor, so it can never be one JSON document. Never call it —
  use `gitpic config get --json` to read and `gitpic config set` to write.
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

# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.20.5] - 2026-08-26

### The update check is no longer starved by a shared IP's rate limit

- Update checks use your GitHub sign-in now, so the hourly limit is 5000 rather than 60 shared network-wide
- Nothing changes if you never signed in; an expired credential falls back to anonymous instead of failing

<!-- release-notes-end: everything above is the GitHub Release and in-app update text; below stays in this file. Keep each bullet above on one line — the app's update sheet renders with .inlineOnlyPreservingWhitespace, which keeps newlines verbatim, so a wrapped line breaks mid-sentence at 480pt -->

### CLI

- `release.rs`'s module doc explicitly forbade this: sending the credential "would put the
  user's token on a request that has no business carrying it". That half is reversed, with the
  measurement recorded in the module header — 60 an hour is per address, and an address is not
  a person. The other half, that the two modules keep separate error mappings because the same
  statuses mean different things, still stands and is why they are still two modules.
- What was conceded and what was not is written down. The credential goes to
  `api.github.com` — the same host and the same token `gitpic auth login` already sends
  there — and GitHub is the only party that sees it; this project's repository owner does not.
  It stays optional: no credential, no header. A rejected one falls back to anonymous. And the
  request cannot follow a redirect at all (`redirect::Policy::none()`), so the header has
  nowhere else to travel.
- The test asserting the check never sends a credential was **narrowed, not deleted**. A
  blanket prohibition would now be false, and a false comment about a credential is worse than
  none. Three properties still hold and are still guarded: no credential means no header
  (`sends_no_credential_when_there_is_none`), a credential goes only to the compile-time base
  and only in bearer form (`sends_the_credential_only_to_the_fixed_base`), and a redirect is
  never followed (`does_not_follow_a_redirect_with_a_credential`). Each was checked by
  reverting the thing it guards.
- The credential is a parameter rather than read inside `check_against`. Read from the file, the
  security assertion would pass on CI and fail on any developer who had run `gitpic auth login`
  — an assertion whose verdict depends on the machine is not one.
- The redirect test was vacuous in its first form, and its doc comment says so: `Location`
  pointed at `example.invalid`, which resolves nowhere, so following the hop and refusing to
  follow it produced the same two observable facts — one request and an error — and it stayed
  green with `Policy::none()` deleted. `Location` now points back at the stub, so a client that
  follows is counted.
- Two assumptions the code rests on were measured rather than assumed: GitHub answers **401**,
  not 403, for a bad token on this endpoint, so the fallback branch really fires; and after a
  check with a credential the *anonymous* budget does not move at all (47 → 47), so the request
  really was authenticated.

## [0.20.4] - 2026-08-26

### A refused update check now says which refusal it was

- A failed update check says which refusal it was, instead of calling every 403 a rate limit
- A real rate limit now says how long to wait
- 设置's 「上次检查」 is now 「上次成功检查」, so it no longer reads as the outcome of a failed check

<!-- release-notes-end: everything above is the GitHub Release and in-app update text; below stays in this file. Keep each bullet above on one line — the app's update sheet renders with .inlineOnlyPreservingWhitespace, which keeps newlines verbatim, so a wrapped line breaks mid-sentence at 480pt -->

### CLI

- `release.rs`'s `status_error` mapped `403 | 429` to `RATE_LIMITED` on the status code alone.
  Its own doc comment justified having a mapping separate from `crate::github`'s "because the
  same statuses mean different things here" — and the one difference that mattered was the one
  it got wrong, while the module it deliberately diverged from tested the body first. GitHub
  answers 403 for a blocked user agent and a middlebox answers it before GitHub is reached;
  neither is fixed by waiting.
- Three signals decide it now, because GitHub uses three shapes: `x-ratelimit-remaining: 0`
  for a primary limit, a `retry-after` header for a secondary one, and the phrase in the body
  as the fallback when something stripped the headers — which is the same test `crate::github`
  applies. The status code decides nothing on its own.
- `AppError::with_retry_hint` has existed since the error codes were introduced, documented as
  being for the one code "whose documented remedy is wait and retry, so it is the only one for
  which a number is guidance rather than noise" — and this call site, the one that needed it,
  never used it. `check_against` read `resp.status()` and dropped the response, so the headers
  carrying the answer were gone one line before the mapping asked. It now passes the headers
  and the body through.
- `retry-after` is already seconds; `x-ratelimit-reset` is an absolute epoch second and becomes
  a delta here. A reset in the past yields no hint at all rather than "retry after 0s", because
  a zero reads as advice and is not.
- The test that covered this asserted the defect: it checked that a bare `FORBIDDEN` maps to
  `RATE_LIMITED`. It now asserts the opposite, that GitHub's words survive, and that the advice
  which cannot work is not given — reverting the mapping turns it red, checked. Three more
  cover each shape of real limit, the wait arriving from either header, and the past-reset case.

### App

- The status line under 更新 said 「上次检查」 for a value that `AppModel` stamps only on a
  completed check — deliberately, so a week offline does not silently count as a week of
  checking. The word 「成功」 is what makes the line and the failure row beneath it legible as
  the two different moments they are.



## [0.20.3] - 2026-08-26

### Logging out is no longer blocked while an update is on screen

- Logging out, restarting, or quitting from the Dock icon is no longer refused while the update window is open
- Quitting mid-install still leaves no mounted image, half-prepared copy of the app, or download behind

<!-- release-notes-end: everything above is the GitHub Release and in-app update text; below stays in this file. Keep each bullet above on one line — the app's update sheet renders with .inlineOnlyPreservingWhitespace, which keeps newlines verbatim, so a wrapped line breaks mid-sentence at 480pt -->

### App

- Two changes, and neither is correct on its own.
  `Updater.allowTerminationWithSheets()` clears
  `preventsApplicationTerminationWhenModal` on each sheet as it begins, so `terminate:` stops
  being refused; `AppDelegate.applicationShouldTerminate` then routes what gets through into
  the one quit path. Lifting the refusal alone would let AppKit tear the process down its own
  way, running neither the login-child reap nor the staging undo — the leak 0.20.2 shipped to
  close, reopened through a different door. The delegate alone is dead code, because a sheet's
  refusal happens before the delegate is consulted, measured on 0.20.0 with a probe build that
  logged nothing from it.
- A `willBeginSheetNotification` observer rather than a fix at each presentation. There are
  five sheet-shaped presentations today — the update sheet, 图床's 「把这个配置文件移开？」,
  「升级前需要退出 GitPic」, 「下载并安装」 and the agent-integration confirmation — and the
  source already recorded why per-sheet fixes are the wrong shape: they leave the next sheet
  anyone adds to reintroduce the bug silently. The flag is read a turn later and set across
  every sheet, because `willBeginSheet` fires before AppKit populates `attachedSheet`.
- `QuitPathContractTests` asserts the two halves as a pair, since either alone is a defect
  rather than half a fix. Checked by reverting each independently, plus swapping the
  notification for the wrong one: all three turn it red.
- `scripts/check-self-update.sh` gains the phase that settles it, because no unit test can —
  `swift test` cannot import `GitPicApp`, and the behaviour is AppKit's with a real sheet on a
  real window. It sends the same `kAEQuitApplication` a logout sends, mid-install, and asserts
  both that the process is gone and that nothing is left behind. The second assertion is what
  separates quitting from quitting correctly: had the delegate returned `.terminateNow` the
  process would still have exited and only the debris check would have caught it.
- Measured on the run that gated this release: the process exited, nothing was left, and the
  mid-install quit phase won its race — the interruption landed inside staging rather than
  after the handoff, which is the harder of the two cases it can get.
- `tell application id … to quit` rather than clicking the Dock icon's menu, because it needs
  no accessibility tree and does not have to make the app frontmost — which the script's own
  comment records as poisoning the accessibility tree for the rest of the run.

### Testing

- The contract test built the expected skill path as
  `agent_home.join("skills/gitpic/SKILL.md")`. On Windows `Path::join` appends that literal,
  slashes and all, while the binary builds the path it reports one component at a time, so the
  assertion compared `skills\gitpic\SKILL.md` against `skills/gitpic/SKILL.md`. The binary was
  right and the test was wrong.
- It had been wrong since the per-agent skill work landed: every push to main from 2026-08-23
  failed the `windows-latest` leg, and 0.18.0 through 0.20.2 — six releases — all published on
  top of that red run. Nothing noticed because a tag does not trigger `ci.yml` and nothing on
  the tag path ran `cargo test` at all, so the two defects hid each other.
- The gate's PASS line asserted a process it had itself killed: it named the pid of the last
  relaunch rather than the one the update replaced, and claimed the reopened app was running
  after a later phase had torn it down. Found by running the gate rather than by reading it.

### CI

- A tag now runs the test suite before anything can publish, on Linux and Windows. macOS
  resolves the same `#[cfg(unix)]` as Linux and is genuinely redundant; Windows is the leg
  neither can stand in for, and it is a target this release ships. Stated plainly in the
  workflow: this gate would have blocked those six releases, over a bug in a test rather than
  in a binary.
- `cargo fmt --check` and `cargo clippy -- -D warnings` come along as advisory steps that
  annotate instead of blocking. `-D warnings` on a floating `@stable` is the one check here
  that can turn a *good* release into a failed one — a lint that did not exist when the tag
  was cut, failing code that never saw it — and it would make re-running an old tag
  impossible. Nothing ships worse for being unlinted.
- The tag-path cache key matched nothing. `Swatinem/rust-cache` derives it from the job id, so
  a job called `tests` produced `v0-rust-tests-…` where CI writes `v0-rust-test-…`: a
  guaranteed miss on every release, followed by a 234 MB save. It now declares
  `shared-key: test` explicitly, so renaming either job cannot silently reintroduce the miss.
- Caches are saved only on `main`. A tag's cache is scoped to a ref recorded as
  `refs/heads/refs/tags/vX.Y.Z`, which only a re-run of that same tag can restore, while the
  tag run restores main's copy anyway. The repo sat at 10.7 GB against a 10 GB cap with a
  142 MB floor per entry, so every save was evicting something a pull request depended on;
  eleven tags were holding 6.16 GB of it.
- `ci.yml`'s MSRV job keeps its exemption from the release path, now with the reason written
  down rather than left as an asymmetry. Every consumer was checked: `Cargo.toml` says the
  field only affects building from source, the crate is not on crates.io, and the Homebrew
  formula installs a prebuilt archive and never compiles it.
- The tap dispatch stopped working between 09:32 and 14:41 on 2026-08-24 and returned
  `Bad credentials` for three releases, each falling back silently to the six-hourly cron.
  `continue-on-error` was doing its job for the release and hiding a regression at the same
  time, because a red step inside a green run is not a report. The step now tells a missing
  token from a rejected one and raises a warning annotation and a step-summary line for
  either.



## [0.20.2] - 2026-08-26

### The update's checksum now covers the file that actually gets installed

- **The checksum was verified on one open of the download, and the disk image was mounted through another.** Nothing proved the two were the same file, so the bytes that were checked were not provably the bytes that got installed. The identity of what was hashed is now recorded and re-checked immediately before mounting, and a mismatch aborts the install.
- **A symlink left at the download path is refused too.** The old check followed the link, so pointing it at the verified image passed — which handed the subject of the check to whoever made the link.
- **Quitting GitPic while an update is installing no longer leaves anything behind.** Quitting during an install used to be impossible, because macOS refused it while the update window was open; now that it works, it also removes the mounted disk image, the half-prepared copy of the app and the download, instead of leaving them on disk until the next day's cleanup.

<!-- release-notes-end: everything above is the GitHub Release and in-app update text; below stays in this file. Keep each bullet above on one line — the app's update sheet renders with .inlineOnlyPreservingWhitespace, which keeps newlines verbatim, so a wrapped line breaks mid-sentence at 480pt -->

### App

- The digest and the `dev`/`ino` of the bytes it covers are now taken through a single
  descriptor — `fstat` on the handle that was hashed, never a second path lookup — and
  `stage` re-asserts that the path still names that inode immediately before `hdiutil
  attach`. The window between the two opens is not instants: a `Task.checkCancellation`
  and a hop onto a serial queue shared with a 20 s `brew list --cask` sit inside it.
- That re-assertion uses `lstat`, not `stat`. `stat` follows symlinks, so against it the
  check proves only that the path *resolves to* the verified inode — and a symlink does
  not replace the file, it replaces the name, which is what `hdiutil` is handed.
  Measured: move the image aside and leave a symlink to it at the download path, and the
  compare passes, because a rename keeps the inode the digest was taken from.
- The test for that refusal now substitutes a byte-identical copy of the image rather
  than 31 bytes of ASCII. With garbage it asserted nothing: `hdiutil attach` refuses
  garbage on its own and throws the same case, so the test passed with the check deleted.
  Byte-identical is the strongest premise there is — the digest cannot tell the two files
  apart, so only the inode can.
- 「退出 GitPic」 and ⌘Q used `NSApplication.terminate`, which AppKit refuses while any
  window has a sheet attached, so 图床's move-the-config alert and the update sheet each
  made the app unquittable. Both now route to the same real `exit` the update path uses.
- Fixing that removed a protection nothing had noticed: AppKit's refusal was the only
  thing preventing a quit *during* an install, since the install is started from a button
  inside the update sheet and that sheet stays attached throughout. `exit` runs no
  cleanup handlers, so `stage` now registers what it creates and the quit undoes it —
  killing the child still writing, removing the staging directory and the image, and
  handing the mount to a detached `hdiutil detach -force` that outlives the process.
- Three things about that undo are load-bearing, and each was wrong first. `hdiutil
  attach` is deliberately never killed, because an attach the kernel has committed to
  survives its process and racing it unlinks the mount point out from under an arriving
  image — unrecoverable rather than merely leaked. The staging directory is claimed
  atomically before the install script is spawned, or a quit landing in between would
  delete the bundle the script is about to move and its rollback trap would put the old
  one back, turning a successful install into a silent rollback. And registering answers
  rather than records: a drain takes what is registered at that moment, and the quit does
  a blocking `UserDefaults.synchronize()` before exiting — ample time for `stage` to
  create a directory nothing would read again.
- The quit-path tripwire now looks for every spelling AppKit accepts. It looked for the
  literal `NSApplication.terminate`, which does not match `NSApp.terminate(nil)` — the
  form 0.20.0 actually shipped, and the form the source names five times when explaining
  the defect. Its comment stripper split on a single `/`, hiding real code after any
  earlier slash and turning a column-0 `///` into a failure; and its file list swallowed
  a failed directory read into an empty one, so the scan could report green having read
  nothing.
- `scripts/check-self-update.sh` now drives the quits a user presses, which it never did:
  it reached the quit through 下载并更新, i.e. the update path's own, so 「退出 GitPic」 and
  ⌘Q were held by a source grep alone. Two phases were added after the existing ones —
  quitting with the update sheet attached and nothing installing, which is verbatim the
  0.20.0 repro, and quitting while an install is genuinely in flight, followed by
  asserting no attached image, no staging directory and no download are left.
- That second phase is honest about a race it cannot reliably win: a 5 MB download plus a
  `ditto` of a small bundle can finish in a couple of seconds, so the quit may land after
  the handoff rather than inside staging. The absence assertions hold either way and the
  run reports which of the two it got. ⌘Q is still not driven, because `keystroke` needs
  the app frontmost and making it frontmost poisons the accessibility tree for the rest of
  the run; it shares one selector with the menu item, which is what the unit test checks.
- The same script used to report success while leaving the repository broken. When the
  Cargo.toml restore did not take it warned and then ran `cargo build --release` anyway,
  baking the fake 0.0.1 version into the shared target directory — the exact thing that
  rebuild exists to prevent — and still exited 0 with `PASS` already printed. It now skips
  the rebuild, fails the run, and keeps its pristine copies to restore from instead of
  deleting them and pointing at `git checkout --`, which its own header explains it must
  not use in a checkout worked by several agents at once.

## [0.20.1] - 2026-08-25

### Fixes an update that installed and then kept running the old build

- **The app used to log 「quitting」 and then not quit.** AppKit refuses termination while the
  update sheet is still attached, so the swap script waited out its bound, swapped anyway, and
  `open -a` merely reactivated the old process — the log said 「reopened」 while the old build
  kept running. The quit is now an actual exit that no sheet can block.
- **「Reopened」 is judged from the image a process is actually executing**, not the path it was
  launched from — a process the swap happened underneath keeps running from the moved-aside
  copy, and can no longer satisfy the reopen.
- **The launch sweep protects the image being executed** rather than the launch path, so it
  cannot delete the backup a process is running from.
- New `scripts/check-self-update.sh`: installs a real update and asserts the old pid exits and
  a new one comes back running the new version. Any release touching the update path must pass
  it — 0.20.0 shipped this bug precisely because that gate did not exist.

<!-- release-notes-end: everything above is the GitHub Release and in-app update text; below stays in this file. Keep each bullet above on one line — the app's update sheet renders with .inlineOnlyPreservingWhitespace, which keeps newlines verbatim, so a wrapped line breaks mid-sentence at 480pt -->

### Fixed

- **The quit is the whole fix, and it is `exit`, not a better terminate.** AppKit's own log on a
  failing run:
  ```
  [AppKit:Application] terminate:
  [AppKit:Application] Attempting sudden termination (1st attempt)
  [AppKit:Application] App termination blocked by modal sheet
  [AppKit:Application] Termination aborted
  ```
  The update path always has a sheet attached — the install starts from a button inside the
  update sheet — and AppKit refuses termination before consulting the delegate, so
  `applicationShouldTerminate` was never called (measured: a probe build logged nothing from it
  on a failing run while the same probe fired on succeeding ones). The activation policy was
  exonerated the same way: with the window open and no sheet, the shutdown runs `windowWillClose`'s
  `setActivationPolicy(.accessory)` and the process exits normally. Dismissing the sheet first was
  rejected: it works only if the dismissal animation finishes before `terminate:` runs, and it
  would let the next sheet anyone adds reintroduce the bug silently. `quitForUpdate` returns
  `Never`, so the compiler holds the invariant 0.20.0 broke. A failed dry run before this found
  nothing because `GITPIC_APP_DRY_RUN=1` returned before the quit — not one line of it had ever
  been executed by a test, a dry run or a review; it now runs everything but the `exit`.
- **The `Killed: 9` measurement is corrected in the comments it justified.** Re-measured twice:
  renaming a running bundle's directory leaves the process running from the moved-aside copy —
  which is exactly how the failed quit became a reopened old build. The ordering survives on the
  plain argument (a half-replaced bundle mixes versions; nothing here can put that back), not on
  the wrong measurement.
- **The reopen's evidence is the image, not the argv string.** `ps` shows the path as given at
  launch; `lsof -a -p <pid> -d txt` shows what is executing. Two conditions, both required: the
  pid is not the one the script waited on, and its image is inside the installed target. Five
  distinguishable outcomes replace the single unconditional "reopened": confirmed; the old
  process never exited (the 0.20.0 shape; says the new version is on disk and tells the user to
  quit and relaunch); accepted but nothing executing that bundle appeared; refused; or a
  confirmed-looking process after a rollback, where it is the bundle that was already there.
  The 60-second wait expiry is logged as an `ANOMALY` now, not passed in silence. `pgrep -x
  GitPic` was discarded as the candidate source for the same reason the argv string was — on
  this machine it matches a completely unrelated Homebrew-managed GitPic in `/Applications`.
- **The sweep guards the image being executed, not the launch path.** `Bundle.main.bundleURL` is
  a launch-time path, and a rename is exactly what leaves one stale; a process the swap happened
  underneath therefore protects the directory nothing executes and leaves the backup — the only
  other copy of the app — unprotected. Latent today because the sweep runs once at launch and a
  survivor never reaches it, but a timer or an install-completion sweep would make it live, and
  unlink does not stop a Mach-O mid-exec: silent damage, with `ROLLBACK FAILED` advice pointing
  at nothing. The default is now `SelfUpdate.currentImage()` (lsof) with the launch path as the
  fallback, and the new test answers the question it was written around: `contains()`'s symlink
  normalisation does reconcile lsof's `/private/var/folders/…` spelling with
  `contentsOfDirectory`'s `/var/folders/…`.
- **The gate is the process, not the script.** `scripts/check-self-update.sh` builds an
  old-versioned GitPic, installs it under `~/Applications`, drives a real update through the UI,
  and asserts the old pid exited, a new pid runs the new version from the installed path, the
  reopened app is `.accessory`, and the machine's own `/Applications/GitPic.app` never moved. It
  refuses to run without `--force` if `~/Applications/GitPic.app` exists, and it restores
  `Cargo.toml`, `Cargo.lock` and the shared release binary through its trap. `AGENTS.md` now
  records the rule: no release touching the update path goes out until it has passed on a real
  machine.

## [0.20.0] - 2026-08-24

### A manual install can update itself now

- **Homebrew installs still go through brew; a manual install downloads and installs the update itself.** Only the first could update in one click before — a hand-installed copy was sent to the release page to fetch a DMG, drag it across, and clear the quarantine flag by hand.
- Downloading, verifying, mounting and copying all finish *before* GitPic quits, so a failure changes nothing. Only once all of it has passed does it quit, swap, and reopen on its own.
- Verified against the SHA-256 GitHub publishes for that file — the same thing Homebrew checks a cask against. **No checksum, no install.**
- When Homebrew owns this copy of GitPic, brew stays the installer; nothing is replaced behind its back.
- When an in-app update is not possible, it says which of the real reasons it was instead of always blaming Homebrew.
- `gitpic update check --json` now also reports the release's assets: name, size, download URL and checksum.

<!-- release-notes-end: everything above is the GitHub Release and in-app update text; below stays in this file. Keep each bullet above on one line — the app's update sheet renders with .inlineOnlyPreservingWhitespace, which keeps newlines verbatim, so a wrapped line breaks mid-sentence at 480pt -->

### CLI

- `update check` reports the release's downloadable files: name, size,
  `browser_download_url`, and the `digest` GitHub computes for each one. Additive on the wire —
  `Decodable` ignores unknown keys, so an older app decodes the new envelope unchanged — and
  `human()` and the `-q` contract are untouched.
- `digest` is an `Option` because it is not part of any documented API contract (measured:
  present on every release of this project that shipped a disk image, from 0.15.0 on; earlier
  releases published no app asset at all). The consumer treats its absence as "cannot verify,
  do not install" rather than as permission to skip the check. The `sha256:` prefix is kept
  rather than stripped — the prefix is what says which algorithm produced the hex, and a future
  `sha512:` value read as SHA-256 would be verification that verifies nothing.
- The download URL is `browser_download_url` passed through, never built from a template.
  Building it would put a second spelling of the release URL in this crate, and
  `the_release_feed_is_a_compile_time_constant` exists to keep there being exactly one.

### App

- **Installs an update itself** when Homebrew does not own the bundle: 下载并更新 fetches that
  version's disk image, verifies it, replaces the running GitPic and reopens it. That install
  used to see nothing but 打开发布页.
- **The ordering is where the safety comes from.** The download, the SHA-256 check, mounting
  the image, confirming the version inside it, verifying its signature and copying the new
  bundle in beside the old one all happen while the app is still running, cancellable, and able
  to show an error — a failure there costs nothing. Only once all of that has passed does the
  app quit, and what remains is two renames in one directory. The irreversible window shrinks
  from "however long a download takes" to "between two renames". It is also why this path needs
  no watchdog while the brew one does: brew goes to the network *after* the app is gone.
- **The trust model, stated.** GitPic is ad-hoc signed, so there is no signature chain and
  macOS cannot vouch for a download's origin. What verifies it is the SHA-256 that
  `api.github.com` reports for the asset, over TLS, against the bytes that arrive — which is
  **the same trust root Homebrew uses**: a cask's `sha256` is likewise a hash fetched over TLS
  from GitHub, and brew has no signature chain either. So this is not a weaker path than the one
  already shipped. Neither survives a compromised GitHub account or CI; the only real
  improvement is a Developer ID plus notarisation, equally out of reach for both. Verified: the
  digest the API reports for 0.19.0's image is byte-identical to `shasum -a 256` over the
  published file.
- **Homebrew first, always.** Replacing a cask-managed bundle behind brew's back leaves its
  manifest describing a version that is no longer on disk, so the next `brew upgrade` fights it.
  The in-app installer is therefore not an alternative to brew; it is what happens when brew is
  not the owner. A brew probe that gets **no answer** is never treated as "not brew's" — a
  timeout can be hiding a working Homebrew, and installing over a cask on that guess is exactly
  the damage above.
- Ownership is decided by asking Homebrew *which* bundle it installed, not whether the cask is
  installed at all. `brew list --cask gitpic` exits 0 whenever the cask exists anywhere, so a
  copy in `~/Applications` on a machine whose cask installed to `/Applications` was reported as
  brew's — it would have been handed to `brew upgrade`, brew would have replaced the *other*
  bundle, and the script would have reopened this one: an old build, still reporting the same
  update available, with brew reporting nothing left to do, repeatable forever. Homebrew answers
  exactly, and this now reads that answer: the Caskroom holds a symlink at
  `<prefix>/Caskroom/<cask>/<version>/GitPic.app` pointing at wherever the app was installed.
  Found by running the whole thing on a machine with the cask genuinely installed, not by
  reading the code.
- Only `/Applications` and `~/Applications` are installed into. The cost, stated: a copy kept
  anywhere else still sees the release page. It also means a development build in the
  repository's `dist-app/` cannot be silently replaced by a release build.
- No checksum means no install, and the release page instead. Better not to install than to
  install bytes nothing vouched for.
- The asset is matched on the exact filename `release.yml` builds, not on "ends with .dmg". A
  release carries five archives and five `.sha256` sidecars beside the image, and "the first
  thing that looks like a download" is how a sidecar gets hashed and then mounted.
- The architecture comes from the running process rather than a hardcoded `arm64`, so a machine
  with no published image finds nothing instead of installing one built for another one.
- `locateBrew()` returned the same `nil` for "no Homebrew on this machine" and "the 8 s
  login-shell probe timed out", and both were treated as "ask again later". Free while brew was
  the only installer; not free now — a machine with no brew is precisely the machine this
  feature exists for, and folding it in with "could not tell" left that user retrying a probe
  that was never going to answer differently. `locateBrewOutcome()` separates them, and the
  asymmetry follows `loginShellLookup`'s existing reasoning: a path in stdout is trusted even if
  the shell had to be killed, so the bound only decides whether *absence* of a path is evidence.
- The update decision uses the **bundle's own** version, not the report's `current` — that one
  is the CLI's, and this replaces the bundle. They are identical in any packaged install
  (`build-app.sh` refuses to package a mismatch) and can differ for a source build.
- Copying uses `ditto --noqtn` rather than `cp -R`: `man ditto` documents that it preserves
  resource forks, extended attributes and ACLs, and an ad-hoc signature lives in extended
  attributes — `cp -R` would break it. The same page says quarantine bits are preserved too, and
  a quarantined un-notarised bundle is one Gatekeeper refuses outright.
- **Quitting before the swap is measured, not assumed.** Renaming a running executable's
  directory away and putting a fresh one at the old path got the process `Killed: 9`. So the
  simpler design — swapping in-process — is not available.
- Four things in the handoff script are the result of finding them wrong first:
  - The backup directory's name carries a UUID and its absence is asserted before the rename.
    `mv a a.old` when `a.old` already exists does **not** fail — it moves `a` inside it, giving
    `a.old/a` (reproduced). With a fixed name, a second attempt would "roll back" a wrapper
    directory that is not a bundle and then delete the real old app with the leftovers.
  - The script does not delete the rollback material at all. `open -a` exiting 0 is not the new
    version running — measured, it returns 0 for a bundle that aborts on launch, and macOS holds
    the crashed process long enough that even `pgrep` seeing it proves nothing — so nothing the
    script can observe entitles it to destroy the only working copy. The previous version is left
    on disk and removed by a later launch instead. The emptied staging directory goes by `rmdir`,
    which cannot take a bundle with it if the swap did not happen.
  - The reopen is in a `trap … EXIT`, not at the end of the success path. GitPic is
    `.accessory`: once it has quit there is no Dock icon and no menu-bar icon, so a script that
    dies early takes the whole app with it.
  - `PATH` is pinned explicitly. Not a privilege measure — nothing here runs elevated — but the
    app's own PATH has a Homebrew prefix prepended, and a script whose job is to replace a
    bundle has no business resolving `mv` through a user-writable directory.
- `codesign --verify` is run on the **staged copy**, after `ditto` and after the `xattr` that
  mutates it, and is documented as proving **nothing about origin**: it passes for anything anyone
  ad-hoc signs. Catching a truncated or half-written copy is the whole point, so it has to run on
  the copy — verifying the read-only mount instead, as the first version did, only re-proves what
  the digest already proved and costs a full decompress pass. The digest is the only
  authentication in the path.
- The launch-time sweep covers more now: besides stale upgrade scripts, it removes a `.dmg` left
  by a cancelled download and the staging and backup directories an interrupted install left in
  an Applications folder. Those two are whole copies of the app, and the script can neither delete
  the staging directory it is standing in nor delete the backup at all. Two rules keep it from
  eating something in use: it skips anything that **is** or **contains** the bundle it is running
  from — structurally, not by age, because any age bound eventually expires while the app is still
  running from there — and it ages a leftover from `st_ctime` rather than mtime, because `mv` and
  `ditto` both preserve mtime *and* birthtime (measured), so a backup was born already older than
  any cutoff and the one-day floor protected it for zero seconds.
- The previous version stays in the Applications folder for about a day, hidden, at roughly the
  size of the app — so three updates in a day leave three of them. That is a deliberate trade
  against the alternative, which is deleting the only working GitPic on the machine on the word of
  an exit code that does not mean what it looks like.
- 取消 is honoured through the whole sequence, not only the download. The staging steps check it
  between the attach, the version gate, the signature check and the copy, and a cancel that lands
  after staging removes the staging directory before throwing. Past the handoff there is nothing
  left to cancel — the script is a detached process by then — so the button is gone at that point
  rather than present and inert.
- **No privilege escalation.** The plan was to ask for an administrator password when the target
  directory could not be written; a red-team pass overturned it. `/Applications` is
  `root:admin drwxrwxr-x`, so any admin can already write it and would never need the prompt;
  the only users who hit the refusal are standard ones, and for them the prompt is a genuine
  local privilege escalation — the app is ad-hoc signed with no library validation and no
  hardened runtime, so the user can inject code into their own GitPic and control the string
  that reaches `do shell script`, while the authorisation dialog shows no command text. So an
  unwritable target says which of the four real causes it was and points at `~/Applications`,
  which needs no extra permission.
- The "cannot upgrade here" line now branches on the actual reason. The old sentence — "not
  installed by Homebrew, or there is no brew on this machine" — was already wrong for a bundle
  brew manages at a path this app is not running from, and there are now two more causes
  ("the directory cannot be written", "the release has no verifiable image") than one sentence
  can carry.
- Nothing to do about a hand-made `bin/gitpic` symlink: the bundle path does not change across
  an install, so an existing link stays valid and points at the new version.

## [0.19.0] - 2026-08-24

### Launch at login and update checks

- **Starts itself at login**, optionally: 设置 ▸ 通用 ▸ 开机自启动. The same switch as 系统设置 ▸ 通用 ▸ 登录项与扩展.
- **Checks for updates** — daily on its own, again whenever the settings window is opened, and whenever you ask. A new version is presented with its release notes and can be installed from there.
- The Finder right-click switch moved from 上传 to 通用.
- Tightened the 图床 copy.
- New CLI command `gitpic update check`: the latest version and its notes, with `--json`.

<!-- release-notes-end: everything above is the GitHub Release and in-app update text; below stays in this file. Keep each bullet above on one line — the app's update sheet renders with .inlineOnlyPreservingWhitespace, which keeps newlines verbatim, so a wrapped line breaks mid-sentence at 480pt -->

### CLI

- `gitpic update check` reports the latest release of `tarnish233/gitpic` — current version,
  latest version, and the release notes — with `--json` and `-q`. It reads neither config nor
  credential: the endpoint is public, so a machine whose config is broken can still ask
  whether there is a newer version, which may well be where the fix is. The feed is a
  compile-time constant and cannot be redirected by a config key or an environment variable:
  this text is rendered inside GitPic's own window, so letting anything else choose its origin
  would be a way to put attacker-authored prose in front of the user.
- Versions are compared as three integers, not as strings. `"0.9.0" > "0.10.0"` holds as text,
  so a string comparison would offer a *downgrade* as an update on the first minor release
  past `.9`. The historical `app-v*` tags, pre-release suffixes, and anything that is not
  exactly three numeric components are refused rather than coerced; when a comparison is not
  possible it is reported as an error instead of answered "up to date", which would hide a
  real pending update behind a reassuring message.
- The notes printed in the terminal are trimmed the same way the app's sheet trims them.
  `human()` printed the release body verbatim, so `gitpic update check` was the one place
  that showed the `## GitPic.app` appendix — instructions for someone who downloaded the DMG
  (drag it to Applications, clear the quarantine flag) printed to a person who already has
  the CLI — plus the theme line already printed just above it as the release name. Measured
  against 0.18.1: 23 lines of notes, of which 6 are about what changed.

### App

- GitPic.app can now **start itself at login**: 设置 ▸ 通用 ▸ 开机自启动. It writes
  macOS's own login-item registration (`SMAppService.mainApp`), so 系统设置 ▸ 通用 ▸
  登录项与扩展 is the same switch rather than a second record that can disagree with it.
- The switch shows **the status the system reports back**, not the outcome of the click.
  `SMAppService.mainApp.status` is re-read after every flip, so "registered, and withheld by
  macOS until you approve it" is shown as on plus a pointer to System Settings instead of
  masquerading as off — in that state clicking again changes nothing. When a flip genuinely
  does not take, the system's own message is shown with it.
- **The Finder right-click switch moved from 上传 to 系统集成 on 通用.** These are the only two
  switches in the app that write system state immediately instead of editing the config and
  waiting for 保存; with both in one place, the note on 上传 explaining why that row did not
  behave like its neighbours is no longer needed. The cost, stated: anyone used to finding it
  at the bottom of 上传 has to look somewhere else.
- Tightened the 图床 copy: dropped the `public_repo`/jsDelivr paragraph in the account section
  (the login button is directly below it) and the standing "you still have to press 保存" note
  in the repository section — 保存 is present on every config pane and its tooltip already
  names the keys waiting to be written, and the one case that genuinely needs the instruction
  (nothing configured yet) still says so.
- 设置 ▸ 通用 ▸ 更新 carries the `自动更新` switch, a status line, and 检查更新.
  The status line has four states, and "this build is newer than the latest release" is the
  one that earns its place: every unreleased build of this repository is in it, and calling
  that "up to date" would be defensible and actively confusing.
- The status-item menu carries it too. An `.accessory` app has no Dock icon and no app menu,
  so the place a Mac user looks for "Check for Updates…" does not exist here. The item becomes
  「有新版本 x.y.z…」 once one is found, so the menu keeps saying so long after a notification
  banner has been dismissed.
- The automatic check runs once a day, and due-ness is evaluated at launch and every time the
  settings window is put on screen. No repeating timer: the price of one would be a background
  request on a cadence nobody is watching, and "check again when the window opens" covers
  ordinary use. Worth recording that this sentence started out false — only `GeneralPane`'s
  `.task` called it, and since `orderOut` emits no `onDisappear` and the window survives being
  closed, that `.task` runs once per process. "Daily" was in practice "per launch".
- An automatic check that finds an update posts a notification; only a manual one raises the
  sheet. A dialog nobody asked for over whatever the window was being used for is an
  interruption, and the window is usually shut when the daily check lands anyway. 设置 ▸ 通用
  keeps a 「查看更新内容」 button for as long as the update stands, so nothing is lost. Once per
  version, too: `Notifier.post` uses a fresh identifier per banner and nothing coalesces, so
  someone who saw the notice and chose to stay put was told the same thing again every day.
- A manual check always produces an answer, which took two things. The sheet is attached to the
  settings window's root view rather than inside 通用 — `detail` destroys the current pane on
  every tab switch, so a check completing after the user moved to 图床 had nowhere to present
  and the answer was simply lost, while the flag stayed raised and ambushed them on their next
  visit to 通用 with a report that might by then be about another version. And a manual click
  colliding with a running automatic check is no longer dropped: that check adopts the request
  instead of reporting through a banner.
- Two structural trims to the notes shown in that sheet, both found by looking at the
  rendered result: the leading `### <theme>` line is what `release.yml` publishes as the
  Release *title*, already shown above the body, so keeping it printed the same sentence
  twice; and the trailing `## `-level sections are install instructions for someone who
  downloaded the DMG (drag to Applications, clear the quarantine flag), which is of no use to
  a reader who already has the app open. A heading means hashes *followed by a space*, and
  fenced blocks are skipped — otherwise notes opening `#42 修复…` lose that whole line, and a
  `## ` quoted inside a ``` block ends the notes there and leaves the fence unterminated.
  `gitpic update check` applies the same rule (`UpdateReport::summary`).
- 立即更新 runs `brew upgrade --cask gitpic` on the user's behalf. The app is a Homebrew cask,
  signed ad-hoc and not notarised, so a Sparkle-style updater would have no signature chain to
  verify a download against and would fight Homebrew's manifest. Homebrew cannot replace a
  running bundle, so the sequence is: write a script, quit, let the script wait for the exit,
  upgrade, reopen. It reopens on failure too — the old bundle is still there — and logs to
  `~/Library/Logs/GitPic-update.log`. `brew upgrade` itself is bounded by a watchdog (15
  minutes), because the reopen runs strictly after it: an upgrade that never returns costs the
  user the whole app, since an `.accessory` app that has quit has no Dock icon, no menu-bar
  icon, and no dialog left to name the log — `open -a GitPic` in a terminal would be the only
  way back. The log tells the watchdog's verdict apart from brew's own. The child inherits the
  app's environment and overrides `PATH` (the policy `GitpicRunner.run` uses); the two
  hand-picked keys it used to build dropped every proxy variable and left brew fetching direct.
- 立即更新 appears only once brew is confirmed to be managing this app. Finding `brew` says
  nothing about where this copy came from: a drag-installed app on a machine that also has
  Homebrew is entirely ordinary, and `brew upgrade --cask` there fails. The cask being
  installed is not enough either — the running bundle also has to be where a cask installs one
  (`/Applications` or `~/Applications`), or a copy running from `dist-app/` would upgrade
  `/Applications` and then be reopened at its own path: an old build, still reporting the same
  update, with brew reporting nothing left to do, repeatable forever. In both cases the sheet
  offers the release page and the command to run instead of a button that cannot work.
- Only a definite answer about brew is cached. `brew list --cask` hitting its 20 s bound, or
  the 8 s login-shell probe timing out, says nothing about how this copy was installed —
  remembering either told a user with a perfectly good Homebrew 「这份 GitPic 不是用 Homebrew
  装的」 for the rest of the process's life, with restarting the app as the only way to ask
  again.
- Under `GITPIC_APP_DRY_RUN=1`, 立即更新 writes the script and stops — nothing is spawned and
  the app does not quit. Replacing `/Applications/GitPic.app` is at least as consequential as
  a commit to the image host, and it is the one action in this app that cannot be undone by
  deleting something afterwards.
- The 「右键上传已关闭」 notification points at 设置 ▸ 通用 ▸ 系统集成. It still named 上传 after
  the switch moved — and once the entry is off, that notification is the only place the app
  says where the switch is.
- 通用's two system-state switches are re-read when the window is focused again, not only when
  it is opened. The window holds `.regular` while open, so it has a Dock icon and a 窗口 menu,
  and both route around `showWindow`. Launch-at-login is the one that made this matter: with a
  stale value `needsSystemSettings` is false, so the 「打开「登录项与扩展」」 button that is the
  only remedy for `.requiresApproval` was never drawn, under a caption asserting a launch that
  would not happen.
- Two sentences come back to 图床, each only when it is needed. After a repository is picked, a
  line says the choice is not in the config file yet. The standing note that was removed did
  restate the toolbar — but removing it outright left nothing on screen at the one moment it is
  load-bearing, when `draft` holds a selection that closing the window would lose, and the
  「还没配置图床」 block that still says this stops applying the instant a repository is chosen.
  And a line above the login button names `public_repo` again: it was the only mention of scope
  *before* the login, so without it someone whose image host is a private repository authorises,
  gets an empty repository list, and is then sent to a terminal for `--scope repo`.

### Internal

- `LaunchAtLoginState` (`GitPicCore`) owns the status mapping and the copy, so both are
  testable. Measurement overturned two assumptions taken from the header:
  `SMAppService.Status.notFound` **is the state of a fresh install** — a bundle the
  background-task-management store has never seen reports it, and only a bundle registered and
  then unregistered reports `notRegistered` — so it has to mean plain "off" rather than an
  error state pointing at System Settings. And `kSMErrorAlreadyRegistered` /
  `kSMErrorJobNotFound`, which `SMAppService.h` documents for redundant calls, are not thrown
  on macOS 26.5: both simply succeed. Since the documentation and the running system disagree,
  the decision rests on the re-read status alone.
- New `src/release.rs` (version parsing and comparison, the release fetch) and
  `GitPicCore/UpdateCheck.swift` (the `--json` decode, the daily due-ness rule, the notes
  trim), with the rules on both sides under test. A last-check timestamp in the *future*
  counts as due: a machine whose clock ran ahead and was corrected, or one restored from a
  backup, holds one, and comparing the signed difference would stop it checking until real
  time caught up. The notes trim is implemented twice because it spans two languages, so the
  rule is written out in both doc comments, clause for clause; `notes` in `--json` is left
  untrimmed, because a script may want the whole body.
- Fixed a flaky test in `src/github.rs`: the stub server did one `read` per connection, but
  TCP is a stream and `reqwest` writes headers and body as separate segments, so a single
  `read` often returned the headers alone. Only
  `put_file_sends_the_existing_sha_when_overwriting` asserts on a request body, and it failed
  about two runs in five — across three CI platforms, enough to redden a release build. It
  now reads to the end of the headers and then exactly as many body bytes as
  `Content-Length` promises.
- That correct reader moved into a new `src/testutil.rs` (`#[cfg(test)]`), shared by `github`
  and `release`. The reason: `release.rs`'s loopback test had reintroduced the single `read`
  verbatim — and there the consequence is worse than flakiness, because that test asserts the
  update check sends **no** `Authorization` header, and a truncated read satisfies it by never
  having read the header block. A security assertion that passes because it looked at nothing
  is worse than no assertion, since it reads like cover.
- `RunFailure` grew a `message` (in `GitPicCore`, where it can be tested). The app matched only
  `.cli` and fell back to `String(describing:)`, printing the enum at the user: an app built
  from source with an 0.18.x `gitpic_cli` on PATH showed
  `undecodable(status: 2, raw: "error: unrecognized subcommand 'update'")` on 通用 — and since
  the check never completes, `lastUpdateCheck` is never stamped, so every visit produced it
  again. `ConfigFailure.other` had the same fallback and changed with it; its existing test
  asserted `contains`, so it had stayed green either way.
- New `.github/scripts/release_notes.py` holds the only implementation of "the summary above
  the marker": `release.yml` extracts with it, `check_manifests.py` validates with it. The rule
  used to live in an awk program and, separately, in a substring test, and the two drifted into
  three defects. The awk stopped at the marker text anywhere in a line, so a summary bullet
  naming the marker truncated the published body — while this step's own non-empty guard passed,
  the remaining heading not being empty. The substring test could not tell a marker below the
  detail (which withholds nothing) from one in the right place. And it ran only in `ci.yml`,
  while `release.yml` triggers on a tag and never invoked it, so `git push --follow-tags` could
  publish before CI had finished. The `version` job now runs it and `publish` needs that job.
  `MARKER_SINCE = (0, 19, 0)` is what lets the guard sit on the publishing path at all:
  pre-0.19.0 sections have no marker on purpose, because backfilling an old tag must keep
  publishing them whole, so the marker is required only from 0.19.0 on. The module carries a
  `--self-test` that `ci.yml` runs — there is no Python test infrastructure here to hang a test
  file on.

## [0.18.1] - 2026-08-23

### A quieter settings window

### App

- Tightened the settings copy across Agent, About, History, and Upload, keeping only
  the labels and explanations needed to act on each pane.

## [0.18.0] - 2026-08-23

### Agent integrations, managed separately and never overwritten silently

### CLI

- `gitpic skill install --agent generic` installs the bundled skill for Generic Agent under
  `~/.agent/skills` (or `AGENT_HOME/skills`).
- `gitpic skill path --json` now reports the prospective `action` for every target so UI
  clients can distinguish a new install, a differing file, and an unchanged copy without
  writing first.
- `gitpic skill install` refuses to replace a differing `SKILL.md` unless `--force` is
  explicit. A new install is published atomically without clobbering a file created after
  the status check, and read errors are reported instead of being mistaken for a missing
  file.

### App

- GitPic.app now has an **Agent** settings pane that manages Claude Code, Codex, and a
  Generic Agent separately, showing whether each copy is missing, different, or current
  with its own install or update action. Only a confirmed replacement passes the CLI's
  overwrite permission.

## [0.17.0] - 2026-08-23

### A whole-project review: three health reports that lied, two writes that lost things

Nothing here is a new feature. Seven reviews were run across the CLI, the app, the
scripts and the workflows, and this is what they found — with, throughout, a preference
for the version of a fix that a test can fail on.

**Breaking, in three places, all narrow.**

- `doctor --json`'s `token_valid` and `repo_writable` are now `true | false | **null**`,
  where `null` means the probe did not run. See below for why `false` was a lie.
- `gitpic config edit --json` is refused as `USAGE` instead of handing stdout to an
  editor and then printing an envelope after it.
- A file upload is named for what its bytes are, so a `.jpeg` renders `.jpg` and a
  mislabelled file gets its real extension. New uploads of such files land at a new
  remote path and will not dedup against the copy already there — one extra blob, once,
  per file. Nothing already uploaded moves or breaks.

#### `--compress` was rotating people's photos

A phone camera writes landscape pixels plus `Orientation = 6` rather than rotating
anything itself. `load_from_memory_with_format` never calls `orientation()`, and neither
re-encoder writes EXIF back — `JpegEncoder` emits it only when `set_exif` was called, and
it is not. So the pixels were re-encoded as stored and the tag saying to rotate them was
dropped: every viewer then showed the photo 90° from what the user saw locally, reported
`ok: true`, with nothing to suggest the file had been altered. `--max-width` was wrong on
the same photo for the same reason — it compared against the stored width and resized the
wrong axis.

Baking the rotation in is the only option that survives the metadata being dropped. It
costs nothing for an image with no tag, which is most of them.

#### `doctor` called three broken setups healthy

- **`link_kind = "cdn"` with a branch containing `/`.** The upload path refuses that as
  `USAGE` before the credential is resolved and before any request, because jsDelivr
  encodes the ref as `repo@branch/path`. `gitpic repos` writes GitHub's default branch
  verbatim, so a repository whose default is `release/v1` lands in `config.toml` beside
  the default `cdn` — legally, since `Config::validate` checks each key alone. `doctor`
  never read `cfg.upload.*` at all, so it reported ✓ ✓ ✓ and exit 0 while every upload
  exited 2 having sent nothing. It now reports the same code and message the upload would.
- **A private repository with `cdn` links.** `RepoInfo` deserialized only `permissions`,
  dropping `private` from a response `doctor` already fetches. Every upload succeeds and
  every jsDelivr link 404s, and nothing said so: `repos` warns at picker time, but a later
  `config set upload.link_kind cdn`, or a repository flipped to private, reached the same
  dead state silently. A caveat rather than a failure, because the upload really does
  work — which is what makes it worse in one respect.
- **`token_valid: false` for a credential nothing had checked.** The probes are gated on
  `config_ok` but only two of the three need a target, so on a machine that had run
  `gitpic auth login` and not yet `gitpic repos`, `/user` was never called and the report
  said the credential was invalid — while `gitpic auth status` on the same machine said it
  worked, and GitPic.app showed both claims side by side. The remedy a reader takes from
  `✗ token valid` is "log in again", which mints a second token to fix a config file.
  `null` distinguishes "not checked" from "checked and bad"; a credential that could not be
  *resolved* stays `false`, because that is a definite answer. Agents requiring `true` are
  unaffected.

#### `gitpic auth login`: refusing to run, losing a token, polling nobody

- A corrupt `auth.toml` blocked the one command that replaces it. `previous` is read only
  to say "replaced the credential that was stored for X", and it was read with `?`.
- A failed write escaped the documented stream contract and took the token with it.
  `auth::save` sat outside the block whose errors become an `error` event, so a full disk
  produced `main`'s seven-line pretty envelope: the app's line parser dropped every line,
  reported no outcome, and the token minted seconds earlier was gone.
- `--json` had lost the closed-pipe guard the human path documents, so
  `gitpic auth login --json | true` minted a one-time code and polled GitHub for the full
  fifteen minutes it stayed valid, for a code that reached nobody.
- `auth logout` said "removed" and left the user to infer "revoked". The authorisation
  stays live on github.com with no expiry, so a recovered disk or a synced copy of the old
  file is still a working credential. gitpic cannot revoke it — that needs the client
  secret — so it now names the page that can.

Also `oauth.rs`, where two comments disagreed about whether a value is secret: `Device`'s
`Debug` redacts `device_code` because it "is what authorises fetching the token", while
`post` said that at the device endpoint "nothing in a response is a credential" and quoted
200 characters of the raw body on a parse failure. No body is quoted at either endpoint
now; the status and content-type carry the diagnostic and neither can carry a secret.

#### Three ways to lose data quietly

- **A blank `--repo` erased the configured target.** `set_repo_spec` parses rather than
  judges, so an empty spec assigned an empty repo *over* the file's value, and the failure
  surfaced two layers later as `CONFIG_MISSING` telling the user to configure a repository
  their file already named. `gitpic shot.png --repo "$REPO"` with `REPO` unset is the shape
  that finds it. Blank now behaves like "not set", the rule `GITPIC_REPO` and
  `--client-id ''` already follow.
- **One bad byte cost the whole history file.** `read_to_string` fails whole-file on
  invalid UTF-8, so a torn append made `gitpic list` a permanent `GENERAL` failure — and
  `trim_file` then returned early on every subsequent append, switching the 2 MB ceiling
  off and letting the file grow without bound. Both readers are lossy now, so one bad byte
  costs one record.
- **A stdout that really failed reported success.** The same error had two opposite
  answers: `record_write` panicked, which under `panic = "abort"` is exit 134, while
  `finish` swallowed it and let the run exit 0 with a truncated file — and which one you
  got depended only on whether the last write carried a newline. Measured on `skill print`
  under `ulimit -f 1`: exit 101 and a raw panic before, exit 1 and
  `error: failed printing to stdout: File too large` after. A broken pipe is still a
  normal end.

#### Also in this change

- **A zero-byte file is refused**, the way stdin always was. `touch shot.png && gitpic
  shot.png` used to make a real commit and print a link that renders as a broken image.
- **The size ceiling is asked before the file is read.** `gitpic bigvideo.mov` allocated
  three gigabytes and *then* said the limit is 100 MB — or was an OOM kill, exit 137.
- **A 422 that is only ever the GET/PUT race is retryable.** The mirror image is a 409,
  which has been `NETWORK` "so agents retry it" since 0.13.2; the loser of the race was
  told exit 1, which `SKILL.md` defines as do-not-retry. Guarded on the body so branch
  protection stays `GENERAL`. (The first version of that guard matched the quoted
  `"sha"` and would never have fired, because the body is raw JSON and those quotes
  arrive backslash-escaped. The test caught it.)
- **A rate limit says when to retry.** `retry-after` / `x-ratelimit-reset` were dropped
  one line before the body was read, so exit 9 — the one code whose purpose is to be
  retried — carried the least information of any.
- **`config edit` can launch an editor with arguments.** `EDITOR="code --wait"` looked for
  an executable of that literal name. It goes through the platform shell now, the way git
  runs its editor, and `$VISUAL` is consulted first. The release audit also caught the
  first Windows implementation treating `cmd /C`'s `%1` like `sh -c`'s `$1`; the path now
  travels in a dedicated environment variable, outside the shell code, and cannot become
  a literal `%1` on Windows. The same cross-platform check restored the clean
  warnings-as-errors Windows build after the new private-write policy flag was otherwise
  Unix-only.
- **`skill install --dir` at the path `skill path` prints no longer installs one level
  too deep**, writing `gitpic/gitpic/SKILL.md` and reporting success. The write is atomic,
  so a crash cannot leave a skill with intact frontmatter and the instructions cut off. A
  partial `--agent all` reports what landed instead of discarding it. And the listing says
  `differs` rather than `outdated`, which was a claim about the user's file that nothing
  here can support.
- **`XDG_CONFIG_HOME=.config` no longer makes every path cwd-relative**, which since
  0.16.0 took the credential with it.

#### GitPic.app

- **Closing the settings window really stops a login.** `cancelLogin()` had one caller —
  the 取消 button — and since 0.15.0 the window is no longer released on close, so ⌘W left
  `gitpic auth login` polling until the code expired.
- **Starting another login immediately after cancelling no longer loses the new task.**
  The old stream needs another scheduler turn to unwind, and its unconditional `defer`
  could clear the new login's handle — making it look idle and leaving neither 取消 nor
  window close able to stop it. A task may now clear only its own generation.
- **Copying the one-time code no longer swallows a pasteboard failure.** The app tells the
  user to enter it manually instead of letting the button look successful.
- **With `gitpic` missing, 账号 span on 「检查登录状态…」 for the life of the process.**
  `attach` calls back into `refreshAuth`; the failure branch did not, and nothing else
  would.
- **An unreadable history file was reported as a config failure**, which both panes render
  by replacing the entire editable form — so a bad `history.jsonl` made every setting
  uneditable and named the wrong file.
- **Launch ran `reload()` twice**, putting a duplicate `config path`, `config get` and
  `list` on the serial gate in front of a cold-launch right-click upload.
- **The launch log is a real `O_APPEND`** rather than `seekToEnd()` plus a write — there is
  no `O_APPEND` on `FileHandle`, and the seek was itself the proof. Measured with two
  concurrent writers: 396 of 400 lines before, 400 after.
- **The thumbnail disk cache is keyed on the thumbnail size**, which is part of what the
  cached bytes are. Raising `maxPixel` left every cached row a hit, and `decode` does not
  upscale, so the pane would have drawn small images in a larger box for good.

#### CI was not running the check that matters most

`FinderServicePlistTests` reads the built bundle's `Info.plist` and disables itself when
there is none — and both workflows ran `swift test` **before** `scripts/build-app.sh`,
with `dist-app/` gitignored. So on every CI run since 0.15.0 the one check holding the
`NSServices` plist and the Swift that registers it to the same names quietly checked
nothing, and a skipped test still counts in "Test run with N tests", so even the total was
unchanged. The step order is fixed, and the test now *fails* rather than skips when `CI` is
set, so re-breaking it cannot go quiet.

Three more that could not fail, and now can: the `-q` source scan latched its "guarded"
flag for the rest of each function, so deleting a real guard left it green; the four `pbs`
wire keys were only ever asserted against themselves, so a typo in the modern key left the
whole suite passing while the switch reported 开 for a service that was off; and
`pngRoundTrip` asserted only dimensions, which survive a JPEG, with no transparent fixture
anywhere to catch the black boxes. `check_manifests.py` also passed a manifest truncated to
`{}`, because `{}` is falsy.

#### Documentation that had gone stale, in the two places it is read most

`release.yml`'s release notes still ended with "Requires GitHub CLI (`brew install gh`)" —
appended to **every** release body since 0.16.0 deleted `gh`. And `SKILL.md` said
`auth login` "refuses `--json` outright" while line 318 of the same file described its
`--json` stream in detail. `new-worktree.sh` and `AGENTS.md` promised that `--seed-config`
makes real uploads possible, which stopped being true when the credential moved into the
per-worktree `auth.toml`.

#### Simplifications

`✓`/`✗` existed four times in three shapes and `note:` a fourth time — the copy the `-q`
contract scan could not see. The path-template dummy sample was written three times and its
message twice, already drifted. `matches!(mode, Mode::Quiet)` eight times.
`effective_link_kind`, `ConfigGate`, `Clipboard.write` and `UploadedLink.snippetOrReason`
each collapse a rule that was being held by hand in two or three places. `build-app.sh`
honours `CARGO_TARGET_DIR` — which this repo's own worktree flow exports — and no longer
leaves a bundle-shaped directory behind on failure.

## [0.16.0] - 2026-08-23

### `gitpic auth login` is the only way in — `gh` is gone

**Breaking.** gitpic no longer reads a credential from anywhere but its own login:

```bash
gitpic auth login     # authorise in the browser (GitHub device flow)
gitpic auth status    # whose credential this is
gitpic auth logout    # remove it
gitpic repos          # which repositories this credential can upload to
```

The token lands in `~/.config/gitpic/auth.toml` at mode 0600, written through the same
atomic-private helper `config.toml` uses — extracted into one function rather than copied,
because "private from before the first byte" is not a property worth re-deriving next to a
secret. It is a separate file on purpose: `gitpic config get` prints every key it knows and
`config edit` opens the file in `$EDITOR`, so neither can reach a credential. That also
makes `auth.toml` the one file in `~/.config/gitpic/` to keep out of dotfiles sync.

**To upgrade: run `gitpic auth login` once.** Then `gitpic repos` lists every repository
the new credential can upload to — pick one instead of typing an `owner/repo` that may not
be reachable.

The authorisation asks for **`public_repo`**: write access to public repositories, the
narrowest OAuth scope that can do the job, since GitHub has none meaning "this one
repository". It is also all a working image host needs — jsDelivr, which `link_kind =
"cdn"` points at, serves only public repositories. A private image host needs
`gitpic auth login --scope repo`, which is broad enough that it is not the default;
`GITPIC_SCOPE` overrides it the way `GITPIC_CLIENT_ID` overrides the app.

A **GitHub App** was the other candidate and would have been narrower — `Contents: write`
on one chosen repository. It lost on the *flow*, not the permissions: a GitHub App's user
token reaches only repositories the app has been **installed** on, and the device flow
performs no installation, so every user would authorise in a terminal and then have to
visit a browser again to install the app and select repositories. One login that
immediately yields a list to choose from is worth more than a tighter grant half the users
never finish.

#### One route removed, and one that never shipped

**`gh auth token` is the breaking one.** It worked in every release through 0.14.0, so a
machine relying on it needs one `gitpic auth login`. A second source meant a second
identity: on a machine with a `gh` session, which account an upload was attributed to
depended on whether a file happened to exist, and every credential failure had two
remedies to explain. It also made `gh` a de-facto dependency for the one job gitpic now
does itself in a single command.

`--with-token` existed only between commits on the way here, so no release ever offered
it and nobody's setup depended on it. The reasoning is worth keeping:

- **A pasted token (`--with-token`).** A token that travels by hand ends up in shell
  history, in a scrollback, in a chat log — and it let an agent ask a user to paste a
  credential into a conversation. The device flow moves no secret through human hands.
  The flag is refused rather than ignored: silently discarding a token someone piped in is
  the worst available outcome, because the secret has already left its keychain.

`GITPIC_TOKEN` and a `github.token` config key remain unsupported, for the reasons they
were dropped in the first place: the environment leaks into process listings and CI logs,
and `config.toml` gets printed by `config get`. A `token` line still in the file is a
`CONFIG_INVALID` error naming it.

#### Also in this change

- **`gitpic init` is gone.** It prompted for the repository, the branch, and the link kind,
  all three typed by hand. `gitpic repos` replaces the first two and is better at them: it
  lists the repositories this credential can actually push to, takes a number, and saves
  `owner`/`repo` alongside the branch **GitHub reports as the default** — typing that
  branch was how a repository whose default is `master` ended up configured for `main`,
  with every upload then 404ing on a ref that does not exist. The link kind moves to
  `gitpic config set upload.link_kind cdn|raw`. A first run is now `gitpic auth login`
  followed by `gitpic repos`.
- **`token_source` is gone** from `doctor --json` (and never existed on `auth status`).
  With one source, a field whose value could only be `"gitpic"` restates the command that
  produced it. `gitpic doctor` prints one line fewer for the same reason.
- **`Debug` is hand-written on every type that holds a token** (`auth::Stored`,
  `oauth::Granted`), printing `<redacted>`. A derived one would put the credential into
  panic messages and `expect` output, which is the last place anyone looks for one.
- **An expired token is `AUTH_FAILED`, not `CONFIG_MISSING`.** Both name the same command
  now, but an agent that reads 3 as "nothing is set up yet" would otherwise go and
  reconfigure a repository that was never the problem.
- **`gitpic repos` is new.** Every repository the credential can reach, with its default
  branch, whether it is private, and whether you can push — `--json` for a picker, plain
  lines for a human. It exists because a hand-typed `owner/repo` that the token cannot see
  fails as a bare `404`, and because `default_branch` is not always `main`.
- **`auth login --json` is the one subcommand that streams.** Everywhere else `--json` is
  exactly one envelope per invocation; here the code has to reach the caller minutes
  before the outcome exists, and one envelope can only be written once. So it is
  newline-delimited JSON: one object per line, each tagged `event` (`code`, then `done` or
  `error`), the last line always the outcome. This is what lets GitPic.app run the login
  inside its own window. An agent still must not call it — a reader parsing stdout as a
  single object fails on the first line, and only a human can type the code.
- **A login nobody can see is refused before it starts.** `gitpic auth login | true` threw
  the one-time code into a closed pipe and then polled GitHub for the full fifteen minutes
  it stayed valid. The heading is now written *before* the device-code request and doubles
  as the probe: a closed stdout can only be discovered by writing to it, so checking
  earlier than that can never fire, and checking later means the code has already been
  minted.
- **An expiring token is reported at login time**, rather than discovered by the upload
  that fails eight hours later. gitpic's app has token expiration switched off, so this
  normally does not appear; it can if `GITPIC_CLIENT_ID` points at an app that has it on.
  gitpic does not refresh automatically — the note says to log in again. (Refreshing is
  possible without a client secret for device-flow tokens, so this is a gap rather than an
  impossibility; the `refresh_token` is currently not stored.)
- `GITPIC_CLIENT_ID` / `--client-id` point the flow at a different OAuth app, `GITPIC_SCOPE`
  / `--scope` at a different grant; `--no-browser` skips the opener, which only ever
  launches a `https://github.com/` URL.

#### GitPic.app: log in and pick a repository without a terminal

图床 grew an 账号 section and a repository dropdown, so first-run setup no longer starts
with "open a terminal". The login happens in the window: the one-time code is shown (and
copyable), the browser opens itself, and the pane switches to the account as soon as GitHub
confirms. The repository is **chosen**, never typed: there are no Owner / Repo / Branch
fields any more, and the branch comes with the repository — GitHub's default, not an
assumed `main`. Nothing is written until 保存, exactly as before. For a repository the
listing cannot show, `gitpic config set github.repo owner/name` still takes a value
directly.

Three things behind it worth naming:

- **The login does not go through the invocation gate.** Every other `gitpic` call is
  serialised there so two uploads cannot race on the branch ref, and the gate has no
  timeout — so a device-flow login, which blocks for as long as its code stays valid,
  would have held it for fifteen minutes and wedged every upload behind it. A login races
  with nothing: it writes `auth.toml`, which no other command touches.
- **Streaming reuses the existing drain.** `ChildProcess` reads both pipes in one `poll`
  loop precisely so neither can be starved into the 64 KiB deadlock; a second loop reading
  only stdout would have reintroduced it. The line callback is threaded into that loop
  instead.
- **Cancelling really stops it.** Closing the window or pressing 取消 terminates the child,
  rather than leaving it polling GitHub until the code expires.

And everything the app had for `gh` is gone with it: `ToolPaths.gh`, `locateGH`, `GHStatus`, `GHProbe`, the gh row
in 关于, and the 凭据来源 row in 图床. `childPATH` no longer prepends anything, since the
CLI spawns nothing to authenticate.

The gh probe existed for exactly one reason — the CLI collapsed "gh missing", "gh not
logged in" and "gh failed" into one `CONFIG_MISSING` message with gh's stderr discarded, so
the GUI re-ran `gh auth status` itself to say something actionable. One source means one
state and one remedy, already in `error.message`, so the app now echoes what the CLI said
instead of re-deriving it and risking drift.
## [0.15.0] - 2026-08-23

### Select an image, right-click, upload

**Right-clicking a selected image in Finder now offers 「GitPic 上传至图床」.** It runs
exactly the path 选择文件上传 already runs — `gitpic <files> --json`, then the link on the
clipboard in the current 格式 / 地址, then a notification. Multiple selections work as one
batch. The app does not need to be running: the right-click launches it.

**It is an `NSServices` entry, not a Finder extension.** The other two ways to put an item
in that menu were both costed. An Action extension (`com.apple.services`) and a
`FIFinderSync` plug-in can carry the app's icon, but the first needs a signed extension
bundle in `Contents/PlugIns` — a target SwiftPM does not build — and the second has to be
switched on by hand in 系统设置 ▸ 登录项与扩展 and only fires inside directories it
registers. Both need a real Developer ID to register reliably, and this project has only
ad-hoc signing (`docs/macos-app-plan.md` C4). `NSServices` rides in the bundle's own
`Info.plist`, where Launch Services reads it, so an ad-hoc signature is no obstacle and
there is nothing for the user to enable. The cost is that the menu item has no icon.

**Without `NSRequiredContext` the item does not appear — and every other check still
passes.** This was the expensive one. Omit that key and the service still registers, still
lands in the services cache, and still answers `NSPerformService` by name all the way
through a completed upload; it is simply absent from Finder's context menu. Nothing short
of a human right-clicking can catch it.

It was found by declaring five variants in one bundle, each differing from the baseline by
exactly one thing, and seeing which one was missing from the menu: only the one with
`NSRequiredContext` removed. That also cleared the suspects that looked more likely at the
time — `NSPortName` is harmless (Safari and Xcode both set it); `LSUIElement` is irrelevant
(easy to misread, since every other services provider installed on this machine happens to
be a regular Dock app); and living in the hidden `.claude` directory is irrelevant too. And
`NSSendFileTypes = public.image` works fine, so the images-only restriction cost nothing.

**The item lands in the 服务 submenu, not at the top level.** An earlier version of this
entry claimed top level, reasoning from Ghostty's two entries, which did render inline at
the time. That was a misread: Finder lays services out according to how many there are, and
once this app's entry existed Ghostty's own two moved into a 服务 submenu beside it
(observed). Placement is Finder's to decide and no key in the declaration pins it, so the
settings caption now tells the user where to look instead of promising a position.

**A right-click upload is normally a cold launch, and that changed one thing about
uploading.** The service launches the app, so the files arrive while `resolveTools()` is
still looking for `gh` — where the old code answered 「正在查找 gitpic，请稍候重试」, which
asks the user to redo the step they just took. Discovery is now held as a `Task`: an upload
lights the status icon and reports 「开始上传」 *first*, and only then awaits the runner.
That order is the point — the wait is exactly the stretch the user would otherwise
experience as nothing happening. Measured on a cold dispatch, `upload started` really does
appear ahead of discovery's own launch record.

上传剪贴板 changed with it. It used to refuse during discovery while a right-click in the
same second waited and succeeded — same intent, same file URLs, opposite outcome, decided
only by which entry point was used. Both paths await now.

**The first config read was pulled into that same wait, or a right-click gets the wrong link
form.** `finish()` needs `AppModel.savedConfig` to resolve both addresses and to honour
`upload.auto_copy`, and `reload()` makes two separate trips through `GitpicRunner`'s serial
gate (`configPath()` then `loadConfig()`, and `configPath` is nil on a cold launch). The
upload slots between them, making the gate order `configPath` → `upload` → `loadConfig`, so
`finish()` saw a nil config: the CDN address unavailable, `form.target` forced to `.raw`
while the banner still named the configured form, and **`auto_copy = false` ignored**
(the fallback for an unreadable config is `true`). `resolveTools()` now awaits the first
reload directly, so discovery completing *means* the config is ready — an ordering
guaranteed by the language rather than won on timing.

**Non-images are refused, and that check is load-bearing.** Measured: the `public.image` in
`NSSendFileTypes` only decides whether the item appears in the menu. At dispatch, pbs checks
only that the pasteboard carries `public.file-url` — it says so itself ("Pasteboard
contained types (), but service expects types (public.file-url)") — and it handed a
`notes.txt` all the way through to the app. The CLI does not check either: `gitpic <file>`
uploads whatever bytes it is given (`src/commands/upload.rs` sniffs formats only for
`--stdin` naming, and `imageproc::maybe_compress` passes anything it cannot decode
through). This is the only place that can say no, and without it a PDF becomes a real commit
in the image-host repository.

### There is a switch for it in 设置

**上传 gains a 「Finder 右键」 section with one switch for whether the item is in the
context menu.** It writes the one place macOS keeps that state: a per-service entry under
`NSServicesStatus` in the `pbs` domain — the same entry the checkbox in 系统设置 ▸ 键盘 ▸
键盘快捷键 ▸ 服务 writes. It has to be written there because the menu item comes from the
bundle's `Info.plist`, which nothing the running app does can take back.

**There is no second copy of the state.** The switch reads that entry rather than keeping a
private flag beside it — otherwise turning the service off in System Settings would leave
GitPic's switch reading 开. The menu title is not a second copy either: `pbs` keys the entry
by title, so the title is read back out of the **running bundle's `NSServices` array** by
`NSMessage`, and the switch's key cannot disagree with the menu it belongs to. That also
makes it apply immediately instead of waiting for 保存, and since it has nothing to do with
the config file, the section sits **outside** the config-dependent branch and stays usable
when the config cannot be read.

**With the switch off, the provider checks again.** Measured: pbs still dispatches to a
disabled service, so `ServiceProvider` re-checks. The item being gone is the ordinary case,
but when the services cache has not caught up, this is what keeps the switch's answer true.
(A renamed title orphans the old entry, and this guard cannot help with that either — only
not renaming can.)

**Reading that entry had two traps in it, and the second matters more.**

`enabled_context_menu` is not the current spelling. AppKit's own diagnostic strings call it
*"the older 'enabled_context_menu' key"* — found verbatim in the macOS 26.5 dyld shared
cache, alongside `presentation_modes`, `ContextMenu`, `ServicesMenu` and `TouchBar`. A reader
that consults only the legacy key reports 开 for a service switched off in System Settings,
whenever System Settings wrote the modern key alone. `presentation_modes` is now read first,
the legacy key second, and only an unreadable pair defaults to on. **The modern key's value
shape is inferred, not observed:** nothing on this machine has ever been toggled
(`NSServicesStatus` reads back empty), so there was no real entry to inspect and the mode
names come from AppKit's symbols rather than from a plist. Hence both plausible encodings are
accepted on read, and a write only ever *updates an existing* `presentation_modes` — it never
invents one.

The other trap: the same flag can be a boolean, an integer, *or a string* — the `0` that
`defaults write … '{enabled_context_menu = 0;}'` stores is an `NSTaggedPointerString`,
because old-style plist text has no number syntax. An `as? NSNumber`-only reader saw nil and
fell through to "absent means on". All three are read now, and strings are matched against
known values only: `NSString.boolValue` never returns nil and maps `""` to `false`, which
would have *disabled* the feature on an unreadable entry while hiding nothing from Finder's
menu — the exact outcome the fail-open default exists to prevent.

**The write is best-effort, and says so.** It used to read the value back and hand the caller
a landed/failed flag. That was a tautology: the read-back hits the same in-process
CFPreferences cache the write just populated, so it echoes the written value whatever
happened underneath. Measured with `chflags uchg` on `pbs.plist` —
`CFPreferencesAppSynchronize` still returned `true`, the in-process read showed the new value,
and `NSDictionary(contentsOfFile:)` showed the old one. Reading the file instead does not work
either: on a healthy write cfprefsd has usually not flushed yet, so it would report failure
for writes that were fine. So the reassuring 「改不了右键菜单」 dialog is gone and the switch's
caption points at System Settings, which is the only honest thing this code can offer.

**A write keeps the entry's sibling keys.** It used to replace the whole sub-dictionary,
discarding `key_equivalent` — the Services keyboard shortcut the user assigned (this
machine's `pbs.plist` carries `ServicesShortcutsPresent`, so those exist in practice). Turning
the right-click item off and on again would quietly take a shortcut away.

### App

- The status-item menu is unchanged: right-click is a fourth entry point, and the first
  three (file picker, clipboard, CLI) all remain.
- Failure wording is split by cause: no images says 「选中的不是图片：<names>」 (more than
  three collapse to 等 N 个, because the system truncates a notification body at a length it
  picks), no files at all says 「右键上传没有收到文件」, and a switched-off item says
  「右键上传已关闭」 — through a neutral notice, not through the upload-failure path, whose
  banner title is hard-coded 「GitPic 上传失败」. A mixed selection that drops some files now
  names them in their own notice rather than leaving the success count to be reconciled
  against what was selected.
- `~/Library/Logs/GitPic.log` records every dispatch: how many items arrived, how many were
  images, and which were skipped.

Not one line of the CLI changed.

## [0.14.1] - 2026-08-23

### The stdin failure told you to do the thing you had just done

0.14.0 made a stem-only `--name` over unidentifiable stdin bytes a `USAGE` error —
correctly, since publishing them at a guessed `.png` is a lie about the content —
but it reused the message written for the case where no `--name` was given at all:
*"cannot tell what kind of image this is from the bytes; pass --name to set the
filename"*. Read that after passing `--name shot` and the only move it suggests is
the one that just failed.

Which is exactly the loop an agent walks into, because the rule everywhere else in
`SKILL.md` is that `--name` supplies the stem and the bytes supply the extension —
"never rely on `--name` to set the extension". Unidentifiable bytes are the one
place that rule inverts: there is nothing else to take an extension from, so
`--name` has to carry one.

So both halves are fixed. The message now names what is missing (`--name "shot"
carries no extension and these bytes are not an image gitpic can identify …
e.g. --name shot.bin`), and the shipped skill states the exception in §3 and beside
the rule it contradicts, with the advice an agent needs: do not strip the extension
when retrying. The skill travels inside the binary (`include_str!`), so this is the
release that delivers it.

Also in the skill, since it is the contract agents call under: `config set --json`
carries `changes` (one `{key, value}` per key, as stored) and keeps the top-level
`key`/`value` only for a single pair.

## [0.14.0] - 2026-08-23

### `gitpic branches`, and the branch is a choice too

The branch was read-only in the app and taken from the repository's `default_branch`, which
is right almost always and wrong the moment someone wants a dedicated `images` branch or a
`gh-pages` one. It is now a second dropdown, backed by a new subcommand:

```bash
$ gitpic branches                              # the configured repository
* main  (configured, protected)
  images

$ gitpic branches --repo octocat/legacy --json  # any repository
{ "ok": true, "repo": "octocat/legacy", "configured": "main", "complete": true,
  "branches": [ { "name": "master", "protected": false } ] }
```

A list rather than a text field, for a reason specific to this field: the Contents API
writes into an **existing** ref and will not create one, so the set of values
`github.branch` may legally hold is exactly the repository's branches. A name outside that
set fails every upload with `REMOTE_NOT_FOUND` — and GitHub answers 404 for a missing ref
exactly as it does for a repository the token cannot see, which makes a mistyped branch the
least informative failure gitpic has.

That is also what the plain output leads with when it applies:

```
$ gitpic branches --repo tarnish233/GitPic-legacy
  master
  tmp-verify-sha
  note: `main` is configured but not in this list, so every upload will fail on a ref
        that does not exist — `gitpic config set github.branch <one of the above>`
```

Which is the exact hazard `config set github.repo` leaves behind, now visible in one
command instead of after an upload.

- **Protected branches are labelled, never filtered.** Protection does not mean unwritable
  — the rules may well permit this account — so removing one from the list would remove a
  legitimate choice. It is reported because it is the usual explanation for a 409/422 when
  every other check passed.
- **A repository with no commits lists nothing, and that is not an error.** The first
  upload creates the ref, so `ok` stays true and the human output says so.
- **`--repo` works here**, as it does on `doctor` — the two read-only lookups that answer a
  question *about* a repository, which is what makes checking one before saving it useful.
  The usage error for a misplaced upload flag names both.
- **The app's picker is driven off the draft, not the saved file.** The interesting moment
  is after choosing a repository and before 保存, which is exactly when the previous
  repository's branches would still be on screen — so a listing that arrives for a
  repository the user has already moved away from is discarded rather than offered.
- **The 图床 pane lost its `App` row.** It showed the OAuth client id, a constant string
  next to the account name. `gitpic auth status` prints it, which is the right surface for
  a twenty-character opaque value; the one thing a different app actually changes — token
  expiration being on — already has its own row.
- **`gitpic branches --json` follows the branch listing agents read** (§0c of the skill),
  including the rule that `configured` not appearing in `branches` is the finding, not a
  permissions problem.

### `gitpic init` is gone: the repository is chosen where the credential is

**Breaking.** `gitpic init` has been removed. `gitpic auth login` now ends by listing the
repositories the new credential can upload to and writing the one you pick:

```
✓ logged in to github.com as octocat
  stored in: /Users/x/.config/gitpic/auth.toml

which repository should gitpic upload to?

  [1] octocat/GitPic-legacy   (branch master)
* [2] octocat/picture_of_notes  (branch main)
  [3] octocat/dotfiles        (branch main, private)

image host? [1-3] [2]:

✓ octocat/picture_of_notes on main — saved to /Users/x/.config/gitpic/config.toml
```

`init` had become the wrong shape twice over. It stopped being an *initialisation* once it
required a credential — a list has nothing to offer until gitpic knows who you are — so the
one command whose name promised to be the first you ran was strictly the second, and both
READMEs documented it with no mention of the order. And it had nothing left of its own to
ask: with the target chosen from a list rather than typed, `init` was one question, asked
one command too late, at a moment when the caller already had exactly the credential
needed to answer it.

**To change the image host afterwards:** `gitpic config set github.repo owner/name`, with
`gitpic repos` to see the candidates (the app: the dropdown on 图床). One caveat that
`init` used to hide — **`config set github.repo` does not touch `github.branch`**. A repo
whose default is `master`, configured for `main`, fails every upload on a ref that does not
exist; `gitpic repos` prints each candidate's `default_branch` next to it, and
`gitpic doctor` names the missing branch when it happens.

`gitpic init` is not special-cased into a message. `Cli` takes positional filenames and
deliberately does not set `args_conflicts_with_subcommands`, so the word is now read as one:
`error: file not found: init`, exit 6 — the same thing every mistyped subcommand has always
said.

Also in this change:

- **The `CONFIG_MISSING` remedies no longer name it.** `Config::require_target` and
  `doctor` both published "run `gitpic init`" as the fix for the most common first-run
  failure, which would have left the advice for exit 3 pointing at a subcommand that no
  longer resolves — and, for an agent following it, a loop. Both now name `gitpic repos`
  and `gitpic config set github.repo`, neither of which is ever the wrong advice: `repos`
  resolves the credential itself, so someone who has not logged in gets the login
  instruction from the command that actually needs one. An integration test reads the
  message an unconfigured user receives and requires it to name something that parses.
- **The picker lives next to the listing** (`commands::repos`), not in `auth_cmd`. Which
  repositories may be offered at all — push access, the private/jsDelivr caveat, a
  truncated page — is one set of rules, and the `--json` listing agents read has to obey
  the same ones.
- **A mistyped choice is re-asked, not returned.** The picker runs *after* the credential
  is on disk, so `USAGE` for a typo would end a completed browser login in a failure, and
  the obvious response to "login failed" is to log in again — minting a second token to fix
  a repository listing. Three tries, then the fallback command. A failure that is not the
  user's to fix (no network for the listing) is a note for the same reason.
- **`commands::prompt` is gone** with the command that needed it. It read EOF as consent to
  the default, which was safe only for `init`'s "keep what is configured" fields; the two
  prompts left — the picker and `skill install` — both treat EOF as an abort, because both
  write something.
- **Read-only repositories are excluded from the picker but counted in the output.** A
  repository that cannot be pushed to is not a choice, it is a choice that fails later. But
  "my repository is missing" is the harder question, so the count is printed.

### Drag-and-drop upload is gone, menu-bar icon included

**GitPic.app accepts no drags from this version on.** Dragging an image onto the menu-bar
icon no longer uploads it — that behaviour was there throughout 0.13.x and is now removed.
The three ways in that remain all still work: **选择文件上传** and **上传剪贴板** in the
menu, and the CLI (`gitpic <files>` — the app and the terminal share one binary).

It was removed not because it did not work but because **the interaction itself is
awkward**. Five shapes were built, installed, and dragged onto by hand:

1. **The menu-bar icon itself** (the 0.13.x behaviour) — measured, its hit rectangle is
   **36 × 29 pt** (a 20 × 16 pt image, padded 8 pt a side), and **a bigger glyph cannot fix
   it**: `NSStatusBar.system.thickness` is 22 pt, so even `pointSize: 17` only reaches
   42 × 30. The ceiling is the bar.
2. **A panel that opened on any image drag** (240 × 132 pt, beside the cursor) — no travel
   at all, but a PNG moved between two Finder folders opened a panel nobody asked for.
3. **A hot zone in the screen's top-right corner** — quiet, but it means going to the corner.
4. **A hot zone under the icon** — closer, but **an invisible trigger region is one a careful
   gesture stops short of, silently**: traced cursor positions for drags aimed at the icon
   sat at y = 1015–1032 against a region that began at y = 1038. Deepening it to 64 pt fixed
   the triggering and added one more behaviour to explain.
5. **⌃ to summon it** (panel 48 pt below the cursor) — nothing to stop short of, nothing to
   aim at, no noise, and every technical unknown verified. By then the shape of the cost was
   clear: to make "just drag it" work, a user has to be told about a key, a delay, and a
   panel that appears.

So it is not being kept. **选择文件上传 and 上传剪贴板 already cover the same need with
nothing to explain.** Removed with it: `StatusIcon`'s hover state (that glyph existed only
for the drop target), `ImageDrop` (the rule for what a drop target accepts), and
`Motion.shelfArrival` (the panel's fade).

**The measurements survive in `docs/macos-app-plan.md` §C6, marked as a record.** Every
constraint there is still true and anyone attempting drag upload again has to get past them:
the 36 × 29 pt ceiling on a status-item drop target; a non-activating panel in an
`.accessory` app *does* receive a drag another app started; a global **mouse** monitor needs
no Accessibility grant but **any ordinary key does, the space bar included** — two processes
sampling `CGEventSource.keyState` at the same instant, the trusted one read `true` and the
untrusted one `false` throughout, and that grant is keyed to a code signature which ad-hoc
signing changes on every build; a changed `changeCount` on `NSPasteboard(name: .drag)` does
**not** mean the pasteboard is written (`clearContents()` bumps the counter by itself and the
write that follows never bumps it again); and the panel could not use a `.behindWindow` blur —
on a 120 Hz 4K-at-2x display it has to be re-derived every frame the drag image passes over
it.

### The menu-bar icon tracks how many uploads are actually running

`report()` used to be last-writer-wins for the glyph: a second upload, or copying a row
from 最近上传, put the icon back to idle while another upload was still on the queue.
The icon is a refcount now; copies notify on their own and no longer banner as
「GitPic 上传失败」. A `CONFIG_MISSING` diagnosis probes `gh` on the discovery queue
instead of parking a cooperative thread, and clears the in-flight glyph first.

A later `CONFIG_INVALID` no longer hides behind the last good form — 图床 / 上传 show
「备份并重建」 again. 连通性测试 with no `gitpic` says so instead of sitting on 「还没测过」.

### CLI: a bad `--path` is USAGE before any credential; a 409 is retryable

`--path ../x/{name}.{ext}` used to walk on to `gh auth token` and come back
`CONFIG_MISSING`. It is now refused as `USAGE` (exit 2) first, the same timing as a
CDN link on a branch with `/`. On `--stdin`, a stem-only `--name shot` over bytes
that are not a recognisable image is also `USAGE` instead of publishing a fake
`.png`; a *file* upload still falls back on the extension the file arrived with. A Contents API 409 is `NETWORK`
(exit 5) so agents retry it; Windows config save no longer unlinks `config.toml` before
the rename.

`gitpic config set` takes `KEY VALUE` pairs and writes the file once, so a later
key that fails validation cannot leave the earlier ones on disk. The app's save is
that one process.

Upload-only flags (`--compress`, `--no-copy`, …) live on the upload commands instead
of being global, which buys two things: `gitpic list --compress` is a clap error
rather than a silent no-op, and **they now have to follow the subcommand.**
`gitpic paste --no-copy` is the spelling; `gitpic --no-copy paste` is a `USAGE`
error (2) instead of a flag that parses and is then dropped, and the same goes for
`--repo` before `doctor`. `--json`, `--quiet` and `--verbose` are untouched — they
mean something everywhere and still work on either side of the subcommand.

## [0.13.2] - 2026-08-22

### The app ships as a dmg, and the settings panes say less

**The macOS app ships as `GitPic-<version>-macos-arm64.dmg` from this version on, not a
zip.** The image carries an `/Applications` symlink beside the app — that alias is what
makes it worth being a dmg at all: open it and drag across, which a zip cannot offer.
UDZO, so it is about the size the zip was: measured on 0.13.1's bundle, 4.76 MB against
4.35 MB, 9% for the install experience.

**It does nothing for Gatekeeper, and that has not changed.** The app is still ad-hoc
signed on the build machine and not notarised by Apple, so a downloaded dmg is quarantined
exactly as the zip was — a manual install **still** needs
`xattr -dr com.apple.quarantine` (brew does it for you). The dmg is about how installing
feels, not about whether macOS trusts it.

CI's verification changed with it: the image is **mounted read-only and asserted in
place** rather than extracted, because what ships is the image. All ten previous
assertions survive, plus one on the `/Applications` symlink — a build that lost it would
still install by hand and would silently stop being a drag-across. The whole packaging and
verification sequence was run locally on macOS before CI was trusted with it.

### App

- **The three ellipses are gone from the status-item menu**: `选择文件上传`, `打开设置`,
  `连通性测试`. Worth stating that this is a **deliberate step away from the platform** —
  macOS uses `…` to mark a command that needs more input before it completes, Apple's own
  Settings… and every open-panel item carry one, and all three of these do open something.
- **上传's 链接 caption keeps only its first sentence** (what the two keys are called, and
  that 保存 applies them). Gone is the paragraph about the status-item menu writing
  immediately, which snippet gets copied, the six combinations not re-uploading, and
  `-f` / `--link` overriding — all true, none of it needed while someone is looking at two
  segmented controls.
- **自动复制到剪贴板 loses its caption entirely** and collapses to a one-line toggle; the
  switch says what it does. Why the app honours the same key as the CLI is now a code
  comment, which is where it belongs.
- **关于 loses two explanations**: `versionNote` is deleted outright (its three cases spelled
  out in prose what two version numbers agreeing or disagreeing already says), and 工具位置
  keeps its two paths while losing the sentence about a Finder-launched app getting a
  minimal PATH.

### Docs

- **Both READMEs now open with the app icon**, centred (icon → title → one-line
  description → language switch), the way most open-source projects do. The icon is
  extracted from the installed `AppIcon.icns` (`iconutil`, 512×512) rather than drawn
  again, so the README shows what the app installs. It lives at `docs/assets/icon.png` — a
  relative path, so forks and offline copies render too.

**The old README documented `brew install tarnish233/tap/gitpic` as still installing the
command line; it installs the app.** 0.11.5 renamed the cask to `gitpic` and deleted the
formula's old-name map, but that release only touched the changelogs and the manifests —
neither README followed. Verified now: that name resolves to the cask (0.13.1), and
`--formula` on it reports `No available formula ... Found a cask named
"tarnish233/tap/gitpic" instead`. Anyone following the old text wanting the CLI would have
installed the app. The correct line for the command line alone has always been `brew
install tarnish233/tap/gitpic_cli`. The old cask name `gitpic_app` still resolves through
`cask_renames.json`, so nothing already installed breaks.

**Both READMEs are reordered and a good deal shorter**: GitPic.app first, then that the
command line *is* the app (one file, so they cannot be at different versions, with config
and history shared) along with CLI usage, and the agent skill last. 271 → 178 lines,
English 315 → 202. What went is duplication and over-detail — the opening console
transcript, the case-by-case expansion of the formula/cask conflict, the standalone
completion and downloads sections (one line each now), and several paragraphs of prose
about `--json`, strict key validation and `doctor`. What stayed is what someone types: the
full `config.toml`, the placeholder list, the exit-code table, the three `--json`
exceptions, and the two rules for agents. Every command in the new README was run.

**AGENTS.md now says how the tap learns about a release**, and loses two claims in the
same paragraph that were no longer true (that the cask is `gitpic_app`; that
`formula_renames.json` must not be removed — it was deleted in 0.11.5, precisely because
keeping it made `gitpic` ambiguous between a formula and a cask).

### CI

- **The tap no longer waits up to six hours after a release.** `release.yml`'s `publish`
  job fires a `repository_dispatch` at the tap (`gitpic-released`, with the version in the
  payload) once the release is up, and the tap follows within seconds — measured at 10s.
  The motivation was measured too: 0.13.0 was published at 05:17Z with the tap still
  pinning 0.11.5, so `brew upgrade` had nothing to say about a version that was already
  out. It needs `secrets.TAP_DISPATCH_TOKEN` — a fine-grained PAT limited to the tap with
  Contents: write — because `GITHUB_TOKEN` cannot reach another repository.
- **The tap keeps its six-hourly cron**, demoted to a fallback. That is the design, not an
  oversight: an unset, expired or revoked token, or a GitHub hiccup, has to degrade to the
  old behaviour instead of leaving the tap stuck forever. For the same reason the dispatch
  step is guarded on the secret being non-empty (so it does not run at all until one
  exists, and adding it could not break a release in the meantime) and is
  `continue-on-error` (by the time it runs the release is published, and failing a good
  release over something the cron fixes on its own is a bad trade).
- **The dispatch carries the version, and the tap fails loudly when it disagrees.**
  Publishing and `releases/latest` moving are not one atomic act, so a run that started a
  moment early would read the previous release, pin the tap to it and report success —
  then sit there until the next cron. That silent wrong answer is worse than a failure.
  Both directions were tested: matching version → success; a deliberate `0.0.1` → failure,
  logging `dispatch was fired for v0.0.1 but releases/latest is v0.13.1` and `refusing to
  pin the tap to a release the dispatch did not name`, and dying before it downloaded a
  checksum or rewrote the formula or cask — the tap was confirmed untouched afterwards.

## [0.13.1] - 2026-08-22

### The sidebar does not collapse: that button was modelled on the wrong window

### Fixed

- **The settings sidebar no longer collapses, and the button offering to collapse it is
  gone.** Hiding and showing it lurched: the moment it expanded, the detail content was
  still laid out at its collapsed width and ran off the window's right edge, clipped,
  while the toolbar — measured against the now-narrower region — could not fit its items
  and grew an `»` overflow chevron that appeared and vanished again. Two symptoms, one
  cause, and the fix here is to **delete the operation rather than repair its animation**.
- **This reverses what `192566c` decided in 0.11.2, and for a reason beyond the bug.**
  That commit added the toggle on the grounds that its absence "did not match the
  platform", citing Passwords and Mail. Those are **content browsers** with resizable
  sidebars, and this window is not modelled on them: it is modelled on **System
  Settings** — said out loud twice in the same source file — and **System Settings has no
  sidebar toggle**. Four fixed panes do not need one; the analogy was to the wrong kind
  of window.
- **Three things go, so the operation is gone rather than merely hidden**: the
  `columnVisibility` state, the binding on `NavigationSplitView`, and the toggle itself
  via `.toolbar(removing: .sidebarToggle)`. Verified on the built bundle: the toolbar is
  five buttons where it was six, with no 隐藏边栏 / 显示边栏 among them, and the menu bar
  carries no View menu, so there is no menu item and hence no ⌃⌘S either.
- **A leftover is recorded in a comment rather than silently deleted**, because it would
  bite anyone who tries a toggle again: a `.frame(width: 200)` sat on the sidebar's
  content as well as on its column. It was harmless when written, since the sidebar could
  not collapse then — but once it could, every collapse animated a column from 200pt to 0
  around content told in absolute points that it may only ever be 200 wide. No width
  satisfies both instructions, so the transition had nowhere smooth to go.
  `navigationSplitViewColumnWidth` was always the whole of what was wanted, and it is
  what remains.
- The cost is stated in the comment: the 200pt is permanent now, so a small screen cannot
  reclaim it. That is the same deal System Settings offers.

## [0.13.0] - 2026-08-22

### Feedback moves back to where the action happens

No new features in this one. What changed is **where** the app answers you. Three things had the same flaw: the feedback was too far from the action.

### App

- **The copy button reports itself now — no banner, no sound.** Clicking a row's copy
  button used to post a system notification and play the `.default` sound, for a button
  sitting directly under the pointer. The glyph on the button now becomes a checkmark in
  place, for one second. **Failures still go through the notification**, because a failure
  carries real diagnosis that will not fit in a badge (the whole sentence about a `/` in
  the branch making jsDelivr unparseable, for one), and `Notifier` itself is untouched —
  an upload finishing still gets a banner and a sound, because there the premise "the
  window is usually closed" holds. This change is exactly where that premise does not:
  the window is open and the pointer is on the button. The two glyphs are **stacked** and
  switched by opacity rather than swapped conditionally — measured, `doc.on.clipboard` is
  16×18pt and `checkmark` 14×13, so a conditional swap would shift the byte count 2pt
  right and take 5pt off the row's height.
- **A thumbnail no longer cuts in — but it only fades if you actually waited.** The test
  is not "was it cached" but **"was the placeholder ever on screen"**: elapsed time inside
  the `.task`, threshold 100 ms. Measured, a warm cache answers all 33 at once in
  4.0–6.6 ms (slowest single row 6.5 ms) and an all-memory pass in 0.1–0.2 ms, so 100 ms
  sits ~15× above the slowest warm row and far below anything a network does. Fading a
  cache hit in would **manufacture flicker where there is none**, once per reopen of the
  pane.
- **The app has its first accessibility handling** (`Motion.swift`).
  `accessibilityDisplayShouldReduceMotion` is read at the moment of use rather than
  observed: nothing on screen is derived from the flag, and it is consulted at the single
  instant a thumbnail lands. Note that reduce-motion here is **not** "no fade" — a
  cross-fade with no displacement is precisely what the setting asks motion to be replaced
  by — so it stays a fade, just shorter and linear; scale and spring are ruled out in both
  branches.
- **The history header says how many thumbnails are still coming** (`正在取缩略图 12/33`).
  On a cold cache those 33 grey boxes sit there for about four seconds, and with nothing
  said about it a slow link is indistinguishable from a broken one. **On a warm cache it
  never flashes**, by two mechanisms: cache hits never enter the denominator (the count is
  taken below the disk-cache early return, below the ceiling and URL guards, and before the
  fetch gate — which also makes 正在取缩略图 a true sentence, since a disk read is not a
  fetch); and a real but very short episode is held back 300 ms, because the first rule
  cannot catch the one freshly-uploaded image fetched over a link that answers in 200 ms,
  which would flash `0/1`. Deliberately **no** `ProgressView`: it is taller than this line
  of text and so the one thing that really would change the header's height, twice per
  open.
- **The menu-bar icon now shows that a dragged image will be taken.** The system already
  badges the drag image with a green "+", so accept-vs-refuse was never invisible — but
  that badge rides the cursor and says the same thing over any copy destination on screen;
  nothing marked *this* target as the one that would take it. So the target changes too,
  and only on the accept side: **refusal stays completely silent**, since the system's own
  snap-back says it better than any indicator could. No work happens during the hover
  (`draggingUpdated` fires ~78 times per second of it); the icon changes only on the
  enter/exit/end transitions.
- The dedup badge's hardcoded 7pt became `.caption2` + `.imageScale(.small)`. Measured
  with `ImageRenderer` against the same 44×32 box: it was 13×16 (50% of the box height),
  `.caption2` alone makes it 17×20 (62%, crowding the corner and competing with the
  picture), and `.caption2` + `.small` lands at 14×17 (53%). The layout knob was adjusted
  rather than reverting to a magic number.

### Fixed

- **With `gitpic` missing, one failed upload erased the warning icon for good.** When the
  CLI cannot be found the status-item icon is a warning triangle — but the "找不到 gitpic"
  failure the missing tool itself produces goes through `report`, which unconditionally
  reset the glyph to idle. The warning vanished, and since `resolveTools` runs once at
  launch, nothing could restore it. The icon's shape is now right (`StatusIcon`): one
  `State` field (idle / uploading / tool-unavailable, so two cannot be set at once) plus a
  hover flag, and leaving a hover restores **what was underneath** — the arrow mid-upload,
  the warning when there is no tool. `report`'s finished case asks `restingState`, read off
  `AppModel.toolState`, so there is no second copy of "was the tool found" to disagree with
  the first.

### Testing

- 12 new cases (123 total): 6 for the thumbnail-progress accounting, 6 for the status-icon
  state machine. The icon rule moved into `GitPicCore` to be reachable at all — `GitPicApp`
  is an executable target no test can import, the same reason `ImageDrop` and
  `UploadReport` live there.
- One of them, the late-subscriber case, first **slept 180 ms** to land "into the second of
  three 120 ms fetches" and then asserted one had already landed. It passed five runs in a
  row here and failed on CI, where the first fetch had not completed inside that window —
  so it read 0/3 and failed a claim the store was honouring. **A sleep long enough to be
  safe on every machine is one nobody can pick**, so the precondition now waits on an
  event: one subscription is consumed until the store itself reports an image landed with
  others still outstanding, and only then is the second subscription made and asserted on.
  The delay is slack now rather than timing. Re-verified under load, with eight CPU-bound
  processes running.

## [0.12.0] - 2026-08-22

### The history pane shows the pictures now, fetched once each

### App

- **Every history row now shows a thumbnail.** A row used to carry one SF Symbol —
  `photo`, or `doc.on.doc` when the upload was deduped — so 37 rows looked identical and
  finding an image meant reading filenames. Each row now leads with a fixed 44×32 box
  holding the picture, fitted whole. **Not cropped**: centre-cropping a screenshot to a
  square leaves nothing worth looking at. The cost is letterboxing, which is why the box
  is a visible surface rather than nothing, and the width is fixed because the text
  column has to start at one constant x — the one thing a list of a hundred rows cannot
  give up.
- **History records no local file, so a thumbnail is a network read — once per image,
  ever.** A row carries `path`, `sha` and `size` and no trace of the file it came from
  (`src/commands/upload.rs:187-195`), which is usually gone or moved by the time anyone
  opens the pane. Three layers: memory by content, disk by blob sha, network gated and
  de-duplicated. What lands on disk is the **decoded, downscaled** PNG rather than the
  original — measured here, 13.3 MB of originals became 472 KB of cache, ~14 KB each, a
  29× reduction. The sha is content-addressed, so the cache is never invalidated: the
  same bytes stay one entry after `github.repo` changes, and different bytes are a
  different key.
- **Addresses are jsDelivr first, `raw.githubusercontent.com` behind it.** Not a speed
  choice — that was measured and between these two hosts it is a wash. All 33 distinct
  images of this machine's history, eight at a time, two rounds each: jsDelivr 5.16 s
  then 4.11 s, raw 6.03 s then 3.59 s. (One file re-fetched three times had suggested
  jsDelivr was 2–3× ahead, TTFB 0.29–0.31 s against 0.79–0.94 s; over 33 files cold at
  the edge it is not, and the single-file figure does not generalise.) The CDN leads for
  two other reasons: it is the address the config points at by default
  (`upload.link_kind = "cdn"`), so the pane exercises the same host the user's published
  links do, and it is reachable from networks that cannot reach
  `raw.githubusercontent.com` at all. Raw is the fallback because it is the one that
  cannot be missing or behind: a branch containing `/` has no parseable jsDelivr ref, so
  such a repository gets raw alone and not one wasted request; and jsDelivr resolves a
  branch ref through its own cache, so an upload from minutes ago — the top of this pane
  — can 404 there while GitHub serves it fine. That 404 costs one request and then falls
  through, once, because the result is cached by content afterwards. When both fail it is
  raw's answer that is reported, since a CDN 404 says nothing here.
- **Opening the pane fetches every row at once: `Form` + `ForEach` on macOS is not
  lazy.** Measured — opening 历史 on a 37-row history and touching nothing, without one
  scroll, put all 33 distinct images in the cache. So the concurrency limit is the only
  number that decides how long a cold pane takes; over those same 33 images: four at a
  time 6.26 s, eight 4.11–5.16 s, twelve 2.21 s. Eight rather than twelve is politeness,
  not a client limit — these come off a CDN serving them for free, and shaving two
  seconds off a once-per-image cost is not worth being the app that opens twelve
  connections at once.
- **Ceilings, written down rather than incidental**: originals past 12 MB are not
  downloaded at all (the recorded `size` is enough to refuse them without a request);
  thumbnails are 160 px on the long edge (a 44×32 box needs 88×64 on Retina); the disk
  cache is capped at 32 MB and pruned oldest-first past it, the same shape as the CLI's
  `history::trim_file`; memory holds 120, enough for a full `list --limit 100`.
- **A `sha` becomes a filename, so it has to be validated first.** It is read out of
  `history.jsonl` — an append-only text file any process can write — and joined onto a
  directory path, and `appendingPathComponent` will not refuse
  `../../../../Library/Preferences/…`. Hex only, at most 64 characters: that admits
  git's 40-character SHA-1 and a future SHA-256, and admits no separator, no `.`, no
  `..`.
- **Dedup moved from the icon to a badge.** `deduped` used to be expressed by swapping
  the row's glyph, and the thumbnail took that slot. It became a corner badge rather than
  being dropped, because a deduped row shows the *same picture* as the row it deduped
  against — which is exactly why the distinction has to be stated somewhere. Rows sharing
  a sha also share one request: 4 of this machine's 37 rows are deduped, and the cache
  holds exactly 33 files.
- Adds `ThumbnailTests` (14 cases, including a request-counting `URLProtocol` stub)
  pinning "fetched once, ever", "a second store on the same directory reads the disk not
  the network", "a CDN miss falls through to raw", "when both fail it is raw's answer
  that is reported", "an oversized original is never requested", and the path-injection
  cases for `sha`.

### CI

- **`scripts/build-app.sh`'s Info.plist heredoc no longer executes three words out of a
  comment.** The heredoc is `<<PLIST` — unquoted, because it has to expand
  `$APP_VERSION` and `$CLI_VERSION` — and the comment inside it read \`Cancel\` /
  \`Open\` / \`Undo\`. In an unquoted heredoc a backtick *is* command substitution, so
  every build really did run those three names: `Open` resolves to `/usr/bin/open` on a
  case-insensitive filesystem, which printed a page of `open` usage into the build log
  alongside `Undo: command not found`, and left the three words blank in the generated
  plist. The plist stayed valid and every key stayed correct (`plutil -lint` always
  passed), which is why this went unnoticed — but it would execute anything on `PATH`
  named `Cancel`, `Open` or `Undo`. Escaped the way `scripts/new-worktree.sh` has been
  doing it all along; whoever wrote that file knew about this. Verified after the fix:
  the build log is clean, the three words are back in the plist, and all three version
  substitutions still land.

## [0.11.5] - 2026-08-22

### The names line up: the repo and the cask are both `gitpic`

**This repository is [`gitpic`](https://github.com/tarnish233/gitpic) now**, not
`gitpic-cli`. The name had to be freed first: the pure-Swift app repo `GitPic` (stopped
at 2.0.5) was holding it, because GitHub repository names are **case-insensitive** —
`GitPic` and `gitpic` are one name — and archiving does not release a name, while an
archived repo is read-only and cannot even be renamed. So the order was forced: leave a
pointer at the top of both of its READMEs, rename it to
[`GitPic-legacy`](https://github.com/tarnish233/GitPic-legacy), then archive it.

GitHub redirects the old URLs, but **a redirect is not a name**: all 78 references were
rewritten — 28 release/compare links in each changelog, `Cargo.toml`'s
repository/homepage/documentation, both READMEs, `SKILL.md`, both plugin manifests, the
app's About-pane link, and the repository root label in `docs/macos-app-plan.md`. The
marketplace line you type is `tarnish233/gitpic` too.

**In Homebrew the cask `gitpic_app` became `gitpic`, and the formula's old-name map was
dropped.** Those two go together: with the map still in place, a cask also called
`gitpic` makes the name permanently ambiguous — measured, Homebrew prints

    Warning: Treating …/gitpic as a formula. For the cask, use …/gitpic or specify the `--cask` flag.

which cannot even state the alternative, since both tokens are the same string, and then
quietly picks the formula. Without the map the bare name resolves to the cask, no warning:

    brew install tarnish233/tap/gitpic       # the app plus the gitpic command (--cask optional)
    brew install tarnish233/tap/gitpic_cli   # command line only

So `brew install tarnish233/tap/gitpic` **means something different** now: it used to
install the CLI, it installs the app — which has carried the CLI since 0.11.4. An
installed `gitpic_app` is migrated by `cask_renames.json` (verified here: `Caskroom/gitpic`
becomes the real directory and `gitpic_app` stays as a compatibility symlink). On the
formula side the old name `gitpic` no longer resolves to `gitpic_cli`; the tap's README
carries the way out.

The crate, the binary and the skill keep their names. Nothing about building or using it
changes.

### App

- The About pane's repository link points at `github.com/tarnish233/gitpic`.
- No other change in the app.

## [0.11.4] - 2026-08-22

### The app's CLI is now the terminal's CLI too

Install the app and then `brew install tarnish233/tap/gitpic_cli` and the machine holds
two copies of the same build: installed twice, upgraded twice, and able to disagree in
between. The cask now links the copy inside the bundle to `bin/gitpic` and generates the
bash, zsh and fish completions — **installing the cask installs the command line**, and
upgrading the app upgrades the command, so version skew is gone by construction. The
formula stays: it is the only option on Linux, on Intel, and for anyone who wants no app.

This uses Homebrew's own `generate_completions_from_executable` (the cask flavour, in
`cask/artifact/generated_completion.rb`) rather than a postflight writing into the prefix
behind its back — Homebrew removes them itself, verified: after
`brew uninstall --cask gitpic_app` the symlink and all three completions are gone.

Installing both makes them compete for `bin/gitpic` and for the same three completions,
and both directions were measured: cask first, and the formula installs but ends with
`Error: The \`brew link\` step did not complete successfully`; formula first, and the cask
installs the app anyway, printing `skipping link` and three `Will not overwrite` lines —
and the keg's files are byte-identical afterwards, because Homebrew refuses to write
through the formula's symlinks. Whichever arrived first owns the command and the
completions, so the READMEs now say install one — not the earlier "installing both is
fine". One trap follows and is recorded in the tap's README: uninstalling the formula
from that state leaves no `bin/gitpic` at all, since the cask skipped the link;
`brew reinstall --cask gitpic_app` restores it.

**One bug fixed on the way, visible only on a fresh install**: the quarantine strip lived
in `postflight`, the completion stanza *runs* the binary, and postflight comes after the
artifacts — so on a fresh install macOS SIGKILLed the still-quarantined ad-hoc-signed
binary and not one completion file was written. (A reinstall hid it, because it reuses the
bundle whose flag was cleared the round before.) It happens in `preflight` now, in the
staging directory, and `app` moves the cleared bundle with `mv`.

## [0.11.3] - 2026-08-22

### Two things to install, two names to install them by

The CLI and the app have always been two things shipping from one version and one
Release, but Homebrew only had one name for them — `gitpic` — so
`brew install tarnish233/tap/gitpic` left you guessing whether you were getting the
command line or the menu-bar app. Both are registered in the tap now, under names of
their own:

    brew install tarnish233/tap/gitpic_cli         # the CLI; the command is still gitpic
    brew install --cask tarnish233/tap/gitpic_app  # GitPic.app

**Nothing about using it changes.** The formula still installs `bin/gitpic`, the same
three completion scripts, the same `/opt/homebrew/bin/gitpic` symlink — only the
formula name and the directory in the Cellar moved. The old name is not dropped
either: the tap carries a `formula_renames.json`, so
`brew install tarnish233/tap/gitpic` still resolves, and an installed keg is migrated
by `brew update` / `brew upgrade` or by `brew migrate gitpic` (measured here: unlink,
move `Cellar/gitpic` to `Cellar/gitpic_cli`, relink — `gitpic --version` unaffected).

**The two copies of the CLI do not fight.** Install the app *and* `gitpic_cli` and
there really are two `gitpic` binaries on the machine, but neither addresses the
other: the app always runs the one in its own bundle
(`ToolDiscovery.locateGitpic` checks `Contents/Resources/gitpic` first and returns,
and the PATH lookup below it exists for `swift run` during development, where there is
no bundle — the launch log reads
`gitpic=/Applications/GitPic.app/Contents/Resources/gitpic`), while Homebrew's copy
serves the terminal. What they do share is
`~/.config/gitpic/config.toml` and `~/.local/share/gitpic/history.jsonl`, and that is
the design: change the repo in the app and the terminal's `gitpic` follows it
immediately; drop an image on the menu bar and `gitpic list` shows it. The one thing
to watch is letting the two versions drift far apart — config keys are validated
strictly, so a key a newer build writes is a `CONFIG_INVALID` for an older one.

The tap's six-hourly updater now edits the formula and the cask. It reads
`releases/latest` and does not alarm on failure, so a wrong path after the rename
would fail **silently**: it was replayed against the renamed files with a fake tag and
fake checksums, and only pushed once all three urls, all three sha256s and the cask's
version/sha256 came out rewritten.

### App

- **Installable with brew**: `brew install --cask tarnish233/tap/gitpic_app`, and
  `brew upgrade --cask gitpic_app` after that. The app is ad-hoc signed on the build
  machine and not notarised by Apple, so the cask clears the quarantine flag itself —
  the `xattr -dr com.apple.quarantine` line the README used to ask you to type is
  Homebrew's job now.
- `zap` removes only what the app itself creates
  (`~/Library/Preferences/dev.gitpic.app.plist`, `Logs/GitPic.log`, Caches,
  HTTPStorages, Saved Application State). It deliberately leaves `~/.config/gitpic`
  and the upload history alone — those are shared with the CLI, and deleting them
  would clear the terminal side too.
- No code changes in the app itself; it carries the repo's version as always.

## [0.11.2] - 2026-08-22

### Two pieces of window chrome that did not match the platform

**The sidebar toggle was missing**, and putting it back needed more than un-hiding
it: `columnVisibility` was `.constant(.all)`, so the button would have been visible
and inert. It is a real `@State` binding now, `.toolbar(removing: .sidebarToggle)` is
gone, and the sidebar collapses and comes back — verified by clicking it: the item's
AX description flips 隐藏边栏 / 显示边栏, the four rows leave and return, and with the
sidebar away the toggle moves into the toolbar beside back/forward, which is where
Passwords and Mail put it.

**The refresh button was a pill twice its needed width with the glyph off-centre in
it** — and that was self-inflicted. 0.11.1 stopped the toolbar relayouting when work
started by keeping a hidden `ProgressView` next to the button, and a hidden view still
takes part in layout: the button and the invisible spinner shared one glass capsule,
so the capsule was sized for two controls and the arrow sat in one half of it,
matching neither 放弃 nor 保存.

Progress now replaces the glyph *inside* the button, in a 16×16 box both states fill.
One control, its own capsule, the same size either way: measured idle and during a
connectivity test, the button stays 44pt wide at x=1152 and every other toolbar item
keeps its position too — 0.11.1's reason still holds, because nothing is inserted into
the toolbar any more.

### App

- **The sidebar can be collapsed.** As above: a real binding plus the system's own
  toggle, not a control of our own.
- **The refresh button looks like an icon button again** — round, the same height as
  放弃 and 保存, glyph centred; it turns into the spinner itself while work runs,
  without changing size.

## [0.11.1] - 2026-08-22

### The half second spent opening Settings was mostly not about settings

The window was slow to open, and the instant it appeared the toolbar's 刷新 and the
host pane's 连通性测试 twitched. Neither is a matter of taste. Measured on this
machine, per open:

    NSHostingController(rootView: SettingsWindowView())   338ms first, 133–172ms after
    super.showWindow + ordering                            44–91ms
    main thread still busy after showWindow returned          176ms
    reload (three gitpic invocations)                      115–154ms

The window was built from scratch every time: `windowWillClose` released the
controller, so every open paid for the whole SwiftUI tree again. It is now built
once — at launch, in its own turn of the main loop, where nothing is waiting on it
— and kept. Opens after that are `build=0ms`, `showWindow=20–28ms`, with the main
thread settled in 26–35ms.

The twitch was the progress report. Everything gated on `busy` changed state twice
on the way past, and the spinner was *inserted* into the toolbar when work started
and removed when it stopped, so AppKit relayouted and 刷新 / 放弃 / 保存 slid
sideways and back on every open — the report was moving the controls it was
reporting about. `busy` now means "still running after 250ms": a window-opening
reload never crosses that line, while a save (one process per changed key), an
upload or a connectivity test does and still gets its spinner.

### App

- **The settings window is built once, so opening it just shows it.**
  `SettingsWindowController.prewarm()` builds it at launch (after the status item is
  on screen — that icon is what the user is actually waiting for), and
  `windowWillClose` no longer releases it. That release did carry one thing worth
  keeping: closing the window spends the back/forward trail, the way System Settings
  does. It used to be a side effect of destroying the view's `@State`; it is now
  explicit — the trail lives in `SettingsNavigation`, which outlives one window
  session, and `endSession()` spends it on close. Verified: switch panes and 返回
  lights up; close, reopen, and it is dark again on the pane you left.
- **`config path` is read once per launch, not once per reload.** A whole process for
  an answer that cannot change while the app runs: the path comes from
  `XDG_CONFIG_HOME` and the home directory, and `rebuildConfig()` renames the file
  into the same place. It was also the most expensive call in the sequence — ~90ms of
  ~120ms, because the first spawn of a cycle waits on the main thread finishing the
  window's first layout. A reload is now 16–24ms.
- **The spinner lives in the toolbar permanently and is only sometimes visible.** It
  used to be inserted on demand, which pushed the buttons beside it out of the way.
  Only its opacity changes now, so the layout does not move. Verified through the AX
  tree: at the instant the window appears and 2.5s later, the five toolbar buttons
  report identical x positions and identical enabled states — 832 / 873 / 1155 /
  1196 / 1246, with 刷新 enabled throughout.
- **刷新 is no longer disabled during a read.** `reload()` is idempotent and every
  invocation passes through `GitpicRunner`'s serial gate, so a second press queues a
  second read rather than racing the first. An extra read is a better trade than a
  button that flickers.

## [0.11.0] - 2026-08-21

### The window is Settings, and the keyboard belongs to the system again

App-side only; not a line of the CLI changed. All four items are the same kind of debt:
names, platform conventions, and a UI whose text did not match what it did.

The window had always been called 主窗口 — the main window — while the only thing it
ever did was edit the config. So the menu item is now 「打开设置…」, its icon went from
`macwindow` to `gearshape`, and the title bar reads 设置 with the current pane as its
subtitle. System Settings lets the title bar be the pane alone, because the app it
belongs to is named in the Dock and the menu bar; this app is `.accessory` and has
neither, so a title bar reading only 「图床」 left nothing on screen to say which window
this is or that it is where settings are edited.

The upload pane's 自动复制到剪贴板 switch used to be labelled 仅 CLI, its own caption
admitting 对 App 无效 — a setting declaring itself decorative in the very UI that offers
it. The app now reads that key. The copy still happens app-side, because `--json` not
touching the clipboard is deliberate (`upload.rs` gates the write on `Mode::Human`, which
excludes `--quiet` too): a `gitpic upload --json` inside someone's script must not
overwrite what they had on their clipboard. What is aligned is the behaviour, not by
giving machine mode a side effect it should not have.

Inside the settings window ⌘W, ⌘Q, ⌘M, ⌘C, ⌘V and ⌘Z all did nothing, because those keys
are dispatched by the **main menu's** key equivalents — and this app never had a main
menu: it is `.accessory`, its own menu bar is not drawn, so nobody ever built one. The
hardest symptom to spot was in the text fields: they do not implement editing commands
themselves, the Edit menu is what sends `copy:`/`paste:`/`undo:` to the first responder,
so with the caret genuinely in the Owner field (measured: `AXFocusedUIElement` was the
`AXTextField`) ⌘A ⌘C copied nothing at all.

### App

- **主窗口 is now 设置, from the menu item down to the type names.** The status-item entry
  went from 「打开主窗口…」 to 「打开设置…」 and its icon from `macwindow` to `gearshape` (the
  former describes a shape, and a shape says nothing about what clicking it does);
  `MainWindowController` / `MainWindowView` / `MainTab` / `MainNavigation` became
  `SettingsWindowController` / `SettingsWindowView` / `SettingsTab` /
  `SettingsNavigation`. The title bar is now 设置 plus the pane as a subtitle, for the
  reason above. **One thing deliberately kept its old spelling**:
  `setFrameAutosaveName("GitPicMainWindow")` is a defaults key (`NSWindow Frame
  GitPicMainWindow`), not a name anyone reads — renaming it would make every window
  already out there forget its size and position, a real cost for no benefit.
- **A standard main menu, so the system shortcuts work in the settings window.** Three
  menus: GitPic (About, 设置… ⌘,, Hide, Quit ⌘Q), Edit (Undo/Redo, Cut/Copy/Paste/Delete/
  Select All) and Window (Close ⌘W, Minimize ⌘M, Zoom, with the window list handed to
  `NSApp.windowsMenu`). Not one custom binding: standard titles, standard selectors,
  standard key equivalents, each dispatched to whatever the first responder happens to be
  — which is what "leave it to the system" means at this layer. Close lives in the Window
  menu rather than in a File menu invented to hold one item, because this app has no file
  operations; System Settings resolves it the same way. **This adds no global hotkeys**: a
  main-menu key equivalent fires only while this app is frontmost, which for an
  `.accessory` app means only while a window of its own is open. The status-bar menu still
  carries no shortcuts at all, for the unchanged reason that they would look global and
  would not be. ⌘R is wired to the toolbar's refresh button — like ⌘S it is dispatched by
  SwiftUI inside the window, which is exactly why those two were the only keys that
  responded while there was no main menu.
- **`upload.auto_copy` is honoured by the app, and no longer labelled 仅 CLI.** The switch
  lost its parenthetical and its caption now tells the truth; with it off the app writes
  no clipboard, and the link is still in 最近上传 and 历史 to copy by hand. When the config
  cannot be read the default is `true`, matching what the CLI defaults to for a missing
  file. The copy result also went from a `Bool` to a three-state `ClipboardOutcome`
  (`written` / `failed` / `suppressed`): "did not copy" and "the copy failed" used to share
  the line 「上传成功，但写剪贴板失败」, which reported a working switch as a malfunction.
  An upload with the switch off now reports 「N 张已上传，未自动复制。链接在「最近上传」里」 —
  a success, and never a claim of a copy.
- **The bundle declares `zh-Hans`, so the system half of the UI follows suit.** AppKit picks
  its own strings against the localizations a bundle declares, and a bundle that declares
  none is treated as English — which is why a Chinese app put up `Cancel` / `Open` and an
  English `Undo` between 剪切 and 拷贝. With `CFBundleDevelopmentRegion` and
  `CFBundleLocalizations` in Info.plist the open panel reads 取消 / 打开, its sidebar
  最近使用 / 个人收藏, undo reads 撤销键入, and even the items AppKit appends itself
  (自动填充 / 开始听写… / 表情与符号) come through in Chinese. `zh-Hans` alone, without
  `en`: there is no English UI here to fall back to, and one consistent language beats
  Chinese panes with English buttons.

## [0.10.0] - 2026-08-21

### Configuring this thing can now be done in the window

A config file still carrying a `github.token` line — the key that stopped being
accepted in 0.5.0 — makes `config get` refuse, correctly and informatively: it names
the offending key and the file it is in. The app then threw that away. `ConfigEnvelope`
declares `config` non-optional, so a perfectly good error envelope failed to decode
and collapsed into "读取配置失败。" beside a 重试 button that could never change the
answer. The host, upload and history panes all went blank at once, and the window's
bottom bar read `undecodable(status: 10, raw: "{\n \"ok\": false,…` — truncated JSON
serving as the explanation.

What made it fatal was having no way out. Every config-*writing* subcommand in the CLI
begins with `Config::load()`, the very call that is failing, so `config set` cannot
repair a file it refuses to parse — and `init` is interactive, so the GUI cannot drive
it. A broken config meant editing the file by hand in a terminal: a GUI app sending
the user back to the command line.

Three things close that gap in this release. **Error envelopes are decoded in one place
in `GitpicRunner`** (`doctor` and partial uploads are untouched: their `error` is
optional, so they decode `ok:false` as data and never reach the fallback), the panes state
the CLI's own words, and they offer an action that changes the answer — back up and
rebuild renames the unparsable file in place and hands back an editable form. **The copy
form became config**: a new `upload.format` (the eleventh key) joins `upload.link_kind` to
decide what the app copies *and* what `gitpic` defaults to in a terminal — it used to live
only in memory, resetting to Markdown · CDN each launch, with the menu's checkmarks free
to disagree with the window. **The settings window follows the macOS 26 conventions it was
missing**: back/forward in the toolbar, a title that follows the pane, and a history pane
rebuilt on the same container as every other pane (it had been bleeding 11pt past both
edges, lined up with nothing).

The window's bottom bar is gone in the same pass: outcomes go to Notification Center only.

### Added

- **`upload.format` — an eleventh config key, and the default for `--format`.** Takes
  `md` | `html` | `url`, spelled exactly as the flag accepts them. Until now "which
  syntax do I get" could only be answered per invocation: `link_kind` had been a config
  key from the start, the format had not, so "I always want HTML" was not a thing the
  config file could say. `effective_format` now reads the flag first, the config second,
  and only then falls back to md — which is precisely what keeping the flag an `Option`
  was for: "the user asked for md" and "nobody said anything" have to stay separable, and
  only the second defers to the file. Unrecognised values are refused
  (`parse_output_format_strict`, the same treatment `parse_link_kind_strict` gives
  addresses): a hand-edited `htlm` is `CONFIG_INVALID` naming `upload.format`, and
  `config set upload.format htlm` is a `USAGE` error. A generated config writes `format`
  immediately above `link_kind`, because the two answer the two halves of one question.

  **Upgrade note**: `gitpic` 0.9.0 and earlier do not know this key, and the config is
  `deny_unknown_fields` — so a config carrying `format` is rejected wholesale by an older
  binary. The app and the CLI ship at one version, so installing the release fixes both;
  a stale `gitpic` left on the machine will report `CONFIG_INVALID`.

### App

- **The copy form moved from the history pane to the upload pane, and became real
  config.** Both dimensions now bind `upload.format` and `upload.link_kind`: in the
  window they behave like every other setting on the pane — edited through the draft,
  written by 保存, undone by 放弃 — while the status-item menu writes immediately, because
  a menu has no 保存 button and no room for one, so a click there has to be the whole
  interaction. The upload pane's separate "CLI 默认地址" row is gone: two controls for one
  address, one of which had to admit in its own caption that it did not affect the app
  you were looking at, is exactly what wanted collapsing. The snippet the app copies and
  the default `gitpic` uses in a terminal now come from the same two values.
- **`linkForm` is derived from the saved config instead of being state of its own.** It
  used to reset to Markdown · CDN on every launch however the config was written, and the
  menu's checkmarks could disagree with the window: measured — after switching to
  纯链接 · Raw in the window the menu still showed Markdown ✓ / CDN ✓, with the copy
  behaviour correct (both read the same variable) and only the marks lying. There is one
  answer now, and `onConfigChange` rebuilds the menu whenever the config moves —
  including when the move came from a 保存 two panes away.
- **A config that cannot be read now says why.** `RunFailure` gains
  `.cli(status:error:)`, carrying the CLI's own `ErrorCode` and message, and
  `GitpicRunner.runJSON` tries this command's payload first and the error envelope
  second. That order is deliberate: `doctor` and a partially-successful `upload` both
  declare `error` optional, so they decode `ok:false` as **data** and never arrive
  here; the commands with a non-optional payload — `config get`, `list` — do, and they
  are exactly the two that used to turn `{ok:false,error:…}` into `undecodable`. The
  pane shows the CLI's message verbatim: it already names the file and the key, which
  beats any paraphrase, and `src/config.rs` pins that a rejected `token` is reported
  without echoing its value, so quoting it is safe.
- **A broken config has a way out from the GUI: back up and rebuild.** The old file is
  renamed in place (`config.toml.broken-<stamp>`), never deleted —
  `owner`/`repo`/`branch` in it are probably still right, and the backup is where they
  are read back from. Once it is out of the way `config get` returns the defaults (a
  missing file is not an error — `src/config.rs`), the form is editable again, and 保存
  writes it one `config set` per key as always. The app does the rename because no
  subcommand can: every config write starts with `Config::load()`. **Renamed, never
  read**: a pre-0.5.0 config still holds `github.token`, and putting its contents in
  the window — or in a notification — would be putting a possibly-live credential on
  screen. The CLI holds that line in its error messages; the app must not become the
  leak the CLI declined to be.
- **The rebuild is offered for one cause only.** `CONFIG_INVALID` means the file exists
  and its text is the problem, which a rename fixes. `spawnFailed`, non-envelope output
  and `CONFIG_MISSING` are all about something other than the file's contents, and
  renaming for those would destroy a working config to fix nothing.
- **A blank form now says what it is for.** With Owner or Repo empty, the host pane
  states it: fill both in, press 保存 at the top right, and credentials are not
  configured here (they come from `gh auth token`, so `gh auth login` first). Two paths
  reach that state — a machine that never ran `init` (a missing file reads back as the
  defaults, not as an error) and one that just used the rebuild above.
- **The upload pane is no longer just "读取配置失败".** Same cause, same verbatim
  message, plus a jump to the host pane — the repair lives in exactly one pane, the one
  that owns the config.
- **The history pane now uses the same grouped Form as every other pane; it had not been
  lining up with anything.** It was a bare `VStack` + `List`, with two faults. A `VStack`
  only stretches when one of its children is greedy, and `ContentUnavailableView` reports
  an ideal height rather than filling — so with an empty history nothing pushed the stack
  open, it stayed content-sized, and the detail column centred the lot: the format
  switcher floated halfway down the pane. (With records present the `List` is greedy,
  which is what hid that.) And even with records it was misaligned, because a `Form`
  honours the detail column's own margins and a naked `List` does not. Measured on this
  window: the form panes' content sits at x=847 in a scroll area starting at 827 — a
  symmetric 20pt inset — while the list's scroll area started at 816 and ran 494 wide,
  bleeding 11pt *under* the split-view divider on the left and 11pt past the window's
  right edge. Padding it by hand would have meant hard-coding that 11 and re-deriving it
  at every window size; using the container the other panes already use costs nothing and
  cannot drift. All three panes now report the same geometry (scroll area 828/472,
  section 848/432).
  The cost, stated: the format switcher is two Form rows that scroll with the content
  instead of a strip pinned above it. The status-item menu carries the same shared
  `linkForm`, so it is not the only way in — and the pinned strip is what forced the
  hand-aligned layout to begin with.
- **The two segmented pickers are one per row, neither `.fixedSize()`.** Both in a single
  Form row does not survive the move: the row gains a label column, and two segmented
  controls that refuse to compress pushed the content to 920pt inside a 680pt window —
  measured — squeezing the sidebar to a sliver and shoving the size and copy columns off
  the right edge. A Form row puts the label in its own column and gives the control the
  value column, which is the layout that fits.
- **An empty history no longer lies.** History and config are read by the same
  `reload()`, config first, so a file that will not parse takes the history down with
  it and the empty list says nothing about whether anything was ever uploaded. That case
  now reads "读不到历史" with the reason and two actions, and the "N 条" counter is
  omitted when the read failed: "0 条" beside a failure reads as a fact about the
  history, and it is not one.
- **The window's bottom bar is gone; outcomes rely on macOS notifications alone.** It
  carried two things: a line of status text, and the 保存/放弃 pair. The line is deleted
  rather than moved — an outcome is an event, this window is usually shut when one
  happens, and Notification Center is where the app already reported uploads, so of the
  two surfaces the bottom one was mostly stale. The one thing it uniquely carried, a
  failed config read, is now stated in the pane that owns it, next to the buttons that
  fix it. The buttons moved to the toolbar, still dimming rather than disappearing when
  nothing is dirty, ⌘S unchanged. The cost is recorded because it is real: with
  notification permission denied, outcomes reach only `~/Library/Logs/GitPic.log` —
  which is why every notification now also writes a log line.
- **The window now follows the macOS 26 settings-window conventions it was missing.**
  The bones were already right (an `NSWindowController` with `.fullSizeContentView`, a
  balanced `NavigationSplitView`, the grouped-Form trio, reference-counted activation
  policy for an `.accessory` app). Added: **back/forward navigation history** on the
  toolbar's leading side (the sidebar reaches any pane in one click, so these are for
  retracing, as in System Settings); **the window title follows the active pane** (the sidebar's `navigationTitle` is
  what the app is called, the title bar is what you are looking at); and an explicit
  `alignment: .topLeading` on the detail pane.
- **Detail-pane alignment went from a per-pane patch to a rule.** The history pane's
  control strip floating mid-window came from the detail column centring content shorter
  than the window; that was fixed in the history pane itself. `.topLeading` now sits at
  the pane-routing layer, so the next pane does not get to rediscover it.
- **All four toggles state `.toggleStyle(.switch)`.** A `Toggle` in a grouped Form
  already renders as a switch, but the style is inherited — one `.toggleStyle` anywhere
  up the tree turns them into checkboxes.
- **Secondary buttons are uniformly `.controlSize(.small)`.** The connectivity test, the
  three config-repair actions, reveal-backup and reveal-log are row actions, not the
  point of their rows.
- **关于 gains a 项目 section**: one line on the CLI and app sharing a repo and a
  version, credentials passing only through GitHub CLI, and no secret in the config
  file — plus a link to the repository.
- **A connectivity test that could not run says so in its own section.** It used to go
  to the status line at the bottom of the window, two panes away from the button that
  caused it — and it is now kept distinct from a report that came back unhealthy, which
  is a different branch.

## [0.9.0] - 2026-08-21

### The link format was two choices all along

This release is app-side again. The CLI is unchanged; it takes the version along
because since 0.6.0 there is one version and one Release for both.

The menu's four-way "链接格式" — Markdown / HTML / CDN URL / Raw URL — looked like a
set of alternatives. It was really two unrelated things crammed into one dropdown:
**which syntax wraps the snippet**, and **which host the link points at**. The CLI has
had them as separate flags (`--format` × `--link`) from the start; the app had
collapsed them into one.

The cost was two concrete bugs. Two of the six combinations had no entry at all, so
"Markdown pointing at the raw URL" could not be chosen. And the history pane's "CDN
URL" returned `record.url`, which is whichever address `upload.link_kind` selected —
so with `raw` configured it handed back a `raw.githubusercontent.com` link under a
label reading CDN.

They are two independent dimensions now, all six combinations reachable, and
switching still costs no re-upload. `src/link.rs` is ported to Swift along the way,
because the envelope carries only one address — escaping included, since the history
pane used to build Markdown by plain interpolation and a single `]` in a filename was
enough to produce a broken link.

### App

- **The link format is now two independent dimensions: syntax × address.** It used to
  be one flat four-case enum (Markdown / HTML / CDN URL / Raw URL), which is not a
  decomposition of anything: `markdown` and `html` carried whichever address
  `upload.link_kind` happened to select, while `cdn` and `raw` were bare URLs. Two
  consequences, both real — **"Markdown pointing at the raw URL" had no entry at all**,
  leaving two of the six combinations unreachable, and the history pane's `cdn` case
  returned `record.url`, which is the address `link_kind` selected, so with `raw`
  configured "CDN URL" handed back a `raw.githubusercontent.com` link under a label
  reading CDN. The CLI has had these as separate flags (`--format` × `--link`) since
  before the app existed; the app now matches.
- **The choice is shared between the menu and the window.** The status-item menu and
  the history pane each held their own copy, so picking HTML in the menu left the
  window still copying Markdown, with nothing on screen explaining the disagreement.
- **`src/link.rs` is ported to Swift, because the envelope carries only one address.**
  `ItemResult.url` is whichever kind `upload.link_kind` selected, so a raw-configured
  host emits no jsDelivr URL anywhere; `list --json` is narrower still — one URL per
  row, and nothing recording which kind it is. The escaping came with it: the history
  pane used to build Markdown by plain interpolation (`"![\(r.name)](\(r.url))"`), so a
  filename containing `]` or `(` terminated the label early and yielded broken
  Markdown. Both escapers walk `unicodeScalars` to match Rust's `chars()` — a
  `Character` loop folds `\r\n` into one grapheme and emits one space where the CLI
  emits two.
- **Both addresses are resolved when the upload lands, not when a snippet is copied.**
  The URLs are built from `github.owner/repo/branch`, so deriving them at copy time
  would make a menu entry from ten minutes ago silently follow a target that upload
  never used.
- **A branch containing `/` now yields no CDN address instead of a dead link.**
  jsDelivr encodes the ref as `repo@branch/path`, so a `/` in the branch leaves the
  branch/path boundary unparseable and the link 404s — the CLI refuses the upload over
  it (`reject_dead_cdn_link`). The app builds CDN addresses itself now, and `--link
  raw` on a `feat/x` branch uploads perfectly well, so without the same predicate the
  app would manufacture exactly the dead link the CLI declines to print. When a CDN
  address is absent **the reason travels with it**: an unreadable config and a slashed
  branch need different things from the user, and reporting the second as the first is
  a message they can act on wrongly.
- **The window no longer opens with the caret in the Owner field.** AppKit hands
  initial focus to the first view in the key-view loop, which here was the Owner field
  — so the window came up with a caret in it and the value selected, one keystroke away
  from replacing a working image-host owner with whatever was typed next.
- **Return no longer saves; the bottom bar's 保存 is the only path.** The status bar on
  config panes is now always present with its buttons dimmed rather than appearing and
  vanishing: a button that only shows up once you have already changed something cannot
  tell you that clicking it is how a change gets written, and a bar that changes width
  as you type moves the button out from under the pointer.
- **The About pane shows the app's own icon**, read back out of the bundle via
  `NSImage.applicationIconName`, so it displays what was actually packaged rather than
  a second copy that could drift.

## [0.8.0] - 2026-08-21

### Drag one image onto the menu-bar icon

Everything here is on the app side. The CLI is unchanged; it takes the version along
because since 0.6.0 there is one version and one Release for both.

The app had three ways to upload and none of them was a drag — the notch panel was
the only thing built for it, it never passed acceptance, and it sat in the tree
switched off by default, so nothing could drop anywhere. The drop target is now the
menu-bar icon itself: drag an image onto it to upload, and clicking it still opens
the menu. The notch's two files (366 lines) are gone along with them, and the
platform measurements they documented stay in `docs/macos-app-plan.md`.

Upload outcomes moved to system notifications, because they are events the user may
have walked away from; an upload *in flight* is still shown by the icon, because that
is a state with a natural end.

### App

- **The menu-bar icon is now a drop target: drag one image onto it to upload.** The
  app had no drop zone at all. The notch panel was meant to be one, but it was never
  verified — synthesising a real Finder-to-panel drag needs an accessibility-authorised
  CGEvent sequence, so it shipped parked behind a `NotchDropZone` default and nothing
  could drop anywhere. `docs/macos-app-plan.md` had listed dragging onto the status
  item as the cheapest alternative, and a probe confirmed on this machine that it
  works: a subview of `statusItem.button` registered for `.fileURL` receives a real
  Finder drag, *and* clicking the icon still opens the menu — but only if `hitTest` is
  left alone. The old notch drop view overrode it to keep every event for itself,
  which on the status item would have meant the icon never opened its menu again.
- **A drag carries exactly one image, or it is refused before it starts.** Several
  files, a non-image, or a folder makes `draggingEntered` return no operation: the
  icon does not highlight and the system plays its own snap-back. This reverses the
  deleted notch view's written decision to accept any file type on the grounds that
  the CLI validates no content either. Two things outweighed it — the two other upload
  entry points already restrict to images, so the unfiltered drop was the odd one out,
  and a drag has no undo: by the time a wrong file is uploaded it is a commit in the
  image-host repository.
- **Upload outcomes are system notifications now, and the notch is gone.** The status
  item still changes its icon while an upload is in flight, because that is a state
  with a natural end; what *happened* is delivered as a banner, because that is an
  event the user may have walked away from. `NotchPanel.swift` and `NotchShape.swift`
  are deleted (366 lines); the C2/C3 platform measurements they documented live on in
  `docs/macos-app-plan.md`, and C3 still governs the new drop view.
- **The icon-reset timer and its guard token are gone rather than ported.** The icon
  used to be restored by a 2.6 s task, which needed a token so a stale reset could not
  wipe a newer message. The outcome now resets the icon directly, so there is no timer
  to race and nothing to guard. `AppModel.clearStatus(_:from:)` went with it — its only
  caller was that task.
- **The upload result wording is now covered by tests.** Its four outcomes — one file,
  several files, partial success, and a successful upload whose clipboard write failed
  — were built inline in the app layer, which no test can import. They moved to
  `UploadPresentation.report` in `GitPicCore` unchanged in behaviour, and the case
  that matters most is now locked down: a failed clipboard write must not be reported
  as a success, or the user pastes stale content and never learns why.

## [0.7.0] - 2026-08-20

### The invariants the comments claimed, now actually held

Most of the fixes in this release share one shape: a comment, a doc, or the previous
changelog already declared an invariant that the code did not keep. The actor claimed
it serialised `gitpic` invocations (it did not); the 8 s bound claimed it bounded the
probe (it did not); `skill.rs` claimed a closed stdin is not consent, while a closed
stdout made a blind install look consented; and the last changelog claimed the draft
and status-line fixes were in (they were not). All of them hold now, each with a test
that fails if it stops holding.

One stretch of never-executed code went with them. The previous entry claimed a fix
for dedup and overwrite of images over 1 MB, but that path was never reached —
GitHub returns 200 for a 4 MB file and `ContentsGet` already parsed it. Dedup and
overwrite always worked; those 45 lines were dead, and they are gone along with the
claim.

### CLI

- **`--name` sets the filename stem, never the file type.** `gitpic photo.jpg
  --name shot` published JPEG bytes at `shot.png`, and `--name shot.png` did the
  same, because the name replaced the extension outright and `render_path`
  defaults `{ext}` to `png`. The extension now follows the bytes, matching what
  `--stdin` and `paste` already did: both spellings publish `shot.jpg`. A format
  the decoder cannot identify keeps the extension the input file arrived with, so
  `diagram.svg --name shot` is `shot.svg` rather than a usage error.
- **A cdn link that would 404 is refused before anything is committed.** jsDelivr
  encodes the ref as `repo@branch/path`, so a branch containing `/` makes the
  branch/path boundary ambiguous and no encoding can repair it. `--link cdn` (or
  the default) on such a branch is now a `USAGE` error raised before the
  credential and before any PUT, so nothing is uploaded and `--link raw` re-runs
  cleanly. It used to warn on stderr and then report `ok: true` with a dead URL —
  and `--json` consumers never see stderr.
- **A closed stdout can no longer answer a question the user never saw.**
  `printf '…' | gitpic init | true` wrote a complete config to disk: every prompt
  write was discarded while stdin was still consumed, so the answers landed
  without one question being shown. `gitpic skill install` was worse — it writes
  files into agent directories and its prompt defaults to "all". A prompt whose
  text could not be delivered now refuses to read an answer at all.
- **A closed stdout no longer turns a failing run into exit 0.** `gitpic config
  get no.such.key --json | true` used to exit 0 because the broken-pipe handler
  called `process::exit(0)` from inside `print_error`. A closed reader on a
  successful write is still a normal end; the process now returns the status it
  already decided.
- **`gitpic init` validates the config the next command will resolve, not only the
  file it is about to write.** `GITPIC_OWNER=me gitpic init` answering just `pics`
  was refused with "a target repo is required", even though owner-from-environment
  plus repo-from-file is exactly what every upload accepts — and the repo prompt's
  own default was written for that case, so `init` was refusing a default it had
  just offered. Nothing environment-derived is written to the file. `owner/` is
  still refused and still leaves nothing on disk, and `gitpic config edit` still
  re-parses after `$EDITOR` exits so a typo is `CONFIG_INVALID` rather than a
  silent ok that every later command then refuses.
- **`feat/x` is a legal branch again**, with one boundary. `check_branch` used to
  reject `/` even though the comments described `feat/x` as the example. `/` is
  allowed in a git ref; empty segments, `.` / `..`, and a leading or trailing
  slash are still refused. The `/branches/{branch}` lookup percent-encodes `/` as
  `%2F` so it cannot add a path slot, while `?ref=` keeps `/` intact because that
  is what GitHub expects in the query. Raw links give the branch its own path
  segment and work; cdn links cannot express it and are refused (above).
- `--name` on two or more files is a `USAGE` error instead of being silently
  ignored. It still applies to stdin, paste, and a single file.
- Uploads larger than 100 MB are rejected locally. The Contents API PUT cannot
  accept them; encoding a payload that cannot land was wasted work and a confusing
  remote error.
- GitHub 409 (ref conflict) and 422 (unprocessable, including branch protection)
  are classified instead of falling through as an unlabelled 4xx. They remain
  `GENERAL` because neither is uniquely actionable, but the message now names the
  status.

### App

- **Two `gitpic` invocations can no longer run at once.** The type was an actor and
  its comments claimed that serialised them; actors are reentrant, so every `await`
  admitted the next caller. Measured on this exact shape: two overlapping
  `applyConfig` calls put two `gitpic` processes on the machine together, and
  `config set` is load → mutate one key → write the whole file with no lock, so one
  of the two changes was silently dropped. Uploads had the same hole, which is the
  GitHub 409 branch-ref race the comment said the actor prevented. A serial queue
  now gates every invocation.
- **The 8 s bound on `gh auth status` and the login-shell lookup is real now.** The
  drain waited for EOF, which needs *every* write end of the pipe closed — and a
  login shell whose profile starts ssh-agent, gpg-agent or nvm leaves one open, so
  killing the child did not produce EOF and the wait never returned at all. A
  `poll` loop bounded by the deadline replaces it, and the child exiting now ends
  the drain instead of EOF: that turns the ssh-agent case from an 8 s kill into a
  complete answer in about 0.1 s. A call that does time out still hands back
  everything it drained.
- **A killed child can no longer crash the app.** `Process.terminationStatus` raises
  an Objective-C exception on a process that has not exited, which `try` cannot
  catch, and after SIGKILL the wait for it could itself expire. The status is read
  only once the termination handler has fired; a child that never reports is
  described as SIGKILLed rather than asked.
- **`gh` is found on machines whose shell profile prints something.** The
  login-shell probe trimmed the *whole* of stdout and treated it as one path, so
  nvm/conda chatter or a motd ahead of `command -v`'s answer made the lookup fail
  and the app said "找不到 gh，请 brew install gh" with gh installed. Lines are now
  scanned for one that is an absolute path whose last component is the tool and
  which is executable — which also stops a stray executable path in a profile from
  being spawned as `gh` — and non-UTF-8 noise no longer discards the answer.
- **The config form no longer reports a saved value as unsaved.** A `repo` typed as
  `owner/name` is stored split, so the typed form never equalled the file again,
  and the draft was reconciled all-or-nothing: one edit elsewhere suppressed the
  whole re-read and that key stayed dirty however often it was saved, with
  `revert()` the only way out. Reconciliation is per key now — the file wins for
  anything the user is not editing, the user wins for anything they touched during
  the round trip, and after a partly failed save only the keys that actually landed
  are adopted, so the value whose write failed stays in the form to retry.
- **Nothing on screen claims a check that did not run.** A failed `doctor` left the
  previous report standing, so "仓库可写 ✓" was rendered beside "doctor 失败". The
  panes now distinguish three tool states instead of two: while discovery is still
  running they say so rather than latching "读取配置中…", and "找不到 gitpic" is only
  said once the search has finished — a drop in the first seconds after launch used
  to get it for a binary that was merely not located yet. The form also loads itself
  as soon as discovery completes instead of waiting for the user to find retry.
- **A status message is cleared by whoever wrote it.** One line was shared by four
  writers and none could clear another's, so a failed save's "写入失败" outlived the
  successful reload that disproved it, "没有改动" was cleared by nothing at all, and
  the history pane's "写剪贴板失败" was stranded the same way. Entering an upload also
  retires any reset still pending, which is what used to wipe "上传中…" mid-upload.
- Tool discovery no longer blocks a cooperative thread. `Task.detached` does not come
  with a thread of its own and the probe blocks for up to 8 s per tool; it runs on a
  dedicated queue now, with the cooperative pool only ever waiting on a continuation.
- Nested reload/save/doctor work no longer lets the first `defer { busy = false }`
  clear the spinner of work still running. Re-opening the main window no longer
  leaks `.regular` activation: `showWindow` takes one `enter()` for the life of the
  window, so closing it returns the app to `.accessory` even if the menu item was
  clicked while the window was already visible or miniaturised.
- Successful uploads refresh the history pane and keep only the eight most recent
  items the menu actually shows. The notch overlay no longer auto-idles an
  in-progress upload. The menu-bar "连通性测试" item opens the 图床 pane and runs the
  same probe the window button uses, instead of a second NSAlert copy of the report.
  History "Raw URL" encoding matches the CLI (`+` `#` `?` are escaped; `/` is not).
  An undecodable CLI process includes stderr in the error shown to the user.

## [0.6.0] - 2026-08-20

### One version, one release — the CLI and the app ship together

From this release the `gitpic` CLI and GitPic.app carry the same version number
and are published in the same GitHub Release. `Cargo.toml` is the single source of
truth; `apps/GitPic/VERSION` and the `app-v*` tag namespace are gone. Every
release is cut by one `vX.Y.Z` tag.

### Release process

- **The two versions are unified, and the build proves it rather than promising
  it.** `scripts/build-app.sh` reads the version out of `Cargo.toml`'s `[package]`
  section and then asserts that the `gitpic` binary it is about to embed reports
  that same version. A stale `target/release/gitpic` used to ship silently inside
  a bundle stamped with a version it did not contain; now the build stops and says
  which binary to rebuild.
- `.github/workflows/release-app.yml` is deleted and its build, verification, and
  packaging steps move into `release.yml` as a macOS job. One publisher attaches
  every artifact — the four CLI archives and the app zip — to a single Release, so
  the release either has everything or does not exist.
- The release is a normal release, not a prerelease. The app is still ad-hoc
  signed and not notarised; that caveat is stated in the release notes next to the
  app asset instead of being encoded in the prerelease flag. The flag could not
  stay: `releases/latest` skips prereleases, and the Homebrew tap's updater reads
  exactly that endpoint, so marking the unified release as a prerelease would have
  stopped the formula from ever updating again — silently, since its cron does not
  fail.
- The release workflow now asserts that the tag matches `Cargo.toml`. Only the app
  side checked its tag against its version before; the CLI derived the version from
  the tag and never compared it to anything.
- The pre-publish artifact guard no longer counts a loose `gitpic-*` glob. It
  asserts the exact expected set instead, because with both artifact families in
  one directory `ls gitpic-*` matches `GitPic-…zip` on any case-insensitive
  filesystem — the guard passed only because the publish job happens to run on
  Linux.
- Both changelogs now carry `### CLI` and `### App` subsections per version.
  `apps/GitPic/CHANGELOG.md` is frozen at 0.1.2 and kept as history.

### CLI

- No functional changes. The version jumps 0.5.1 → 0.6.0 because the CLI and the
  app now share one number, not because anything in the CLI behaves differently.

### App

- **Copying an image *file* — the ordinary Finder ⌘C — no longer reports "剪贴板里
  没有图片".** The clipboard reader only looked for bitmap data (`.png`, `.tiff`,
  an `NSImage`), and a Finder copy puts none of those on the pasteboard: it puts
  `public.file-url`, which `NSImage` does not read back either. Measured, not
  assumed. File URLs are now checked first and uploaded as files, so the original
  bytes, extension, and name survive instead of every paste landing as a
  re-encoded `clipboard.png`. A clipboard with nothing usable on it now also logs
  the pasteboard's types — it was the one failure that left no trace at all, which
  made "GitPic 没反应" undiagnosable.
- A failed clipboard write is no longer reported as "已复制". `setString`'s result
  was discarded, so a failure claimed success and the user pasted stale content
  with no explanation. An empty result list no longer clears the clipboard either.
- **Owner / Repo / Branch and the path template read as editable, because they now
  look editable.** A bare `TextField` in a `.grouped` form draws no bezel and
  right-aligns its text, which on macOS 26 is pixel-identical to the read-only
  rows beside it — the fields have always been writable, but nothing on screen
  said so. They now carry a bezel, read from the left, and show a placeholder;
  Return saves.
- The target-repository pane is now called **图床**, and its `doctor` button
  **连通性测试** — the status-bar item's entry is renamed to match. The button's
  three probes are all reads, and the pane now says so before it is pressed.
- **The status-bar menu no longer advertises shortcuts it cannot honour.** `⌘⇧V`,
  `⌘O`, `⌘,` and `⌘Q` were shown as if they were global hotkeys. Nothing in the app
  registers one, and a status-bar menu is not in the main menu chain, so they fired
  only while the menu was already open — measured: pressing `⌘⇧V` with Finder
  frontmost leaves no trace in the log at all. The labels are gone; the items work
  by clicking.
- The file picker and the connectivity-test alert now hold `.regular` for as long
  as they are on screen, the way the main window does, instead of calling
  `NSApp.activate(ignoringOtherApps:)` — deprecated since macOS 14, and under
  cooperative activation a background app cannot pull itself in front of the
  active one.
- The application icon is an Icon Composer document: the menu-bar SF Symbol
  `photo.on.rectangle.angled`, enlarged, as a black mark on a white Icon Composer
  fill. Tahoe applies specular glass and shadow from `AppIcon.icon`; older macOS
  gets the flattened `.icns`. `scripts/build-app.sh` compiles it with `actool`
  (icns + `Assets.car`) and declares both `CFBundleIconFile` and
  `CFBundleIconName`. The 1024 px PNG the old `sips` pipeline resized is gone.
- CI now runs `scripts/build-app.sh` and the bundle assertions on macOS. It used
  to run only `swift build` and `swift test`, so the bundle, icon, and signing path
  was never exercised until a tag — which is how a release guard that still looked
  for `Resources/GitPic.icns` survived the move to `actool`.

### Not in this version

- **Global hotkeys.** Uploading from the clipboard without opening the menu would
  need `RegisterEventHotKey`; nothing registers one yet.

## [0.5.1] - 2026-08-19

### Declare an MSRV, and let CI hold it for you

### Packaging
- Declared an MSRV: `rust-version = "1.88"`. There was none, so on an older
  toolchain `cargo install` blew up somewhere inside a dependency instead of saying
  "gitpic requires rustc 1.88". 1.88 is the floor the dependency graph sets —
  `image 0.25.10` declares 1.88.0 and the `icu_*` crates reqwest pulls in declare
  1.86 — and it is *measured*, not read off those manifests: a 1.88.0 toolchain was
  installed and `cargo build --locked` passes on it. This only affects building from
  source; the Homebrew and release binaries are built by CI on stable. Both READMEs
  and the skill document now state the requirement in their from-source section.

### CI
- Added a build job pinned to the declared MSRV. It reads the toolchain version
  **out of `Cargo.toml`** rather than repeating it in the workflow — a hardcoded
  copy would drift from the promise the job exists to check, which is the same hole
  `check_manifests.py` closes for the three plugin manifests. It runs
  `cargo build --locked` and not the tests: what is promised is that `cargo install`
  works, and that path does not build tests. cargo itself refuses the build when a
  dependency requires a newer rustc than we claim — which is the drift that actually
  happens, since one `cargo update` can raise a dependency's floor above ours.

## [0.5.0] - 2026-08-19

### Align the contract with the implementation

> **Upgrade note**: `--repo` and `gitpic init` now reject bad target values they
> used to accept — `--repo 'owner/re po'`, `--repo owner/..`, or an answer with a
> space at `init`'s repo/branch prompt are `USAGE` errors (exit 2). The only calls
> affected are the ones that could never have produced a working link: they
> previously ended in a bare 404, or in a config file gitpic itself refused to load.

### Added
- `gitpic doctor`'s report now carries an `error` object (`{ code, message }`, the
  shape every other subcommand uses), present on exactly the reports where `ok` is
  false. The failure reason used to live only in the **exit status** — a side channel
  an agent may never see: `gitpic doctor --json | jq` replaces it with jq's own 0
  (measured; the pipeline semantics are harness-independent), and `| jq` is the most
  common way an agent parses JSON. Some agent harnesses' shell wrappers do not return
  the exit status at all. stdout is the one channel a caller parsing this report
  definitely has, so the code goes there too. The exit status is unchanged.
- The "every probe answered and GitHub simply said no" outcome now has a message to
  read. Its `PERMISSION_DENIED` is *synthesised* — there is no probe error to take a
  code from — so it previously carried neither `error` nor `detail`: the most common
  "can read, cannot write" result told neither a machine nor a human why. `summarize`
  now keeps the code and the message together in one `AppError` rather than two loose
  `Option`s, which is what let them come apart.

### Fixed
- `gitpic init` no longer writes a config it would refuse to load. It was the one
  writer that **persists** to disk while skipping `Config::validate`, so answering
  `me x/pics` at "Target repo" — or a branch with a space, or `..` — printed
  "✓ saved config" and then made **every** config-reading command fail with
  `CONFIG_INVALID` (exit 10), `init` itself included, since it loads the file
  before prompting. The only way out was `gitpic config edit`. Validation now runs
  before the write: a bad answer is a `USAGE` error and nothing on disk is touched,
  so `init` can simply be re-run.
- `--repo` is now validated like every other source. It is the **highest**-priority
  source and was the only unchecked one: `--repo o/..` made reqwest normalise a
  whole segment out of the request URL (the request landed on a different
  endpoint), and `--repo 'o/re po'` sent `%20` into the path — both surfacing as a
  bare 404, while the identical value in `config.toml` was `CONFIG_INVALID` and in
  `GITPIC_REPO` was `USAGE`. All five entry points now go through one of
  `validate`'s two wrappers.

### Documentation
- The skill document and both READMEs told agents, in three places, to read
  `error.code` from the `doctor` report to tell "branch missing" (8) from "no write
  permission" (7) — and that field did not exist. It does now (see above), and the
  documents say to read it rather than the exit status, and why the exit status is
  not dependable.
- "Always pass `--json` and `--no-copy`" contradicted the documents' own examples.
  `--no-copy` is meaningful only on the upload path; the other five subcommands
  reject it as a `USAGE` error (2), so `gitpic doctor --json --no-copy` fails. The
  instruction now scopes it to the upload commands.
- `init` is not the only `--json` exception: `gitpic completion <shell>` ignores it
  and prints hundreds of lines of shell script, and `gitpic config edit` ignores it
  and hands stdout to `$EDITOR` (defaulting to `vi`), which off a tty emits a
  screenful of terminal control sequences before the envelope. All three exceptions
  are now stated.
- `CONFIG_INVALID` has not reported a line number since 0.2.3 — `Display` was
  replaced with `message()` so a source line that might hold a credential is never
  echoed — but the skill's exit-code table and both READMEs still promised it named
  "the offending line".
- `--quiet` was written as a general rule while only the upload path and
  `gitpic list` honour it; `doctor -q` and `skill install -q` still render human
  output.

### CI
- The release subtitle no longer accepts a Keep a Changelog category word. It is
  taken from the first `### ` heading in the changelog section, so a section that
  opens straight into "Changed" or "Security" produced a public release title of
  "gitpic v0.4.0 — 变更" — a category label carrying no information about the
  release. Hitting a category word now fails the job, forcing a theme line first,
  and an empty subtitle fails instead of falling back to "Release". The 0.4.0
  section gained the theme line it was missing.

## [0.4.0] - 2026-08-19

### Credentials come from the GitHub CLI only

### Changed
- **Breaking:** GitHub credentials now come exclusively from
  `gh auth token --hostname github.com`. `GITPIC_TOKEN` is ignored and the
  legacy `github.token` config key is rejected. Before upgrading, remove that
  key and run `gh auth login`.
- `gitpic doctor` keeps the `token_source` field for wire compatibility, but its
  only non-null value is now `"gh"`.

### Refactored
- Removed the three-source credential precedence model, token-source enum,
  config redaction path, and legacy token branches from `init` and `config`.
- Centralized `config set` semantic validation in `Config::validate`, moved
  upload-only helpers into the upload module, and unified guarded stdout writes.
  These changes reduce duplicated logic without changing non-authentication
  behavior.

## [0.3.0] - 2026-08-18

### Security
- `gitpic init` no longer asks for a token. `prompt` reads through a plain
  `stdin.read_line()`, so a typed token echoed to the terminal and stayed in the
  scrollback, in `script`/asciinema recordings, and in any terminal logger — and
  answering it then wrote that token to disk in plaintext, the exact thing the
  credential chain was reworked to avoid. `init` now points at `gh auth login` and
  `GITPIC_TOKEN`. An existing `github.token` keeps working and still wins over
  `gh`, so nobody is cut off.
- The directory holding the config is tightened to `0700` on every save. `config
  set` and `init` write a file that may hold a legacy token, and `create_dir_all`
  builds `0755` directories — enough for another local user to *list* the config,
  not just read it. The write path itself (same-directory temp file, `0600` from
  creation, permission errors surfaced) was already hardened in 0.2.3.

### Fixed
- `gitpic doctor` no longer reports `repo_writable: true` on repository push
  permission alone. Repo-level `push` says nothing about whether the ref an upload
  targets exists, so a push-capable token against a missing branch passed every
  preflight check and then failed the Contents API with a bare 404. The target
  branch is now probed too (concurrently, like the other two), and `repo_writable`
  requires both. A missing branch reports `REMOTE_NOT_FOUND` with a message naming
  the fix.
- `gitpic init` no longer erases a configured repository when you press Enter. The
  "Target repo" default was derived from `owner` alone, so with an empty owner —
  which happens when `repo` was set by itself, or the owner comes from
  `GITPIC_OWNER` — no default was offered, Enter returned `""`, and
  `set_repo_spec("")` cleared it. An empty answer with nothing configured is now a
  usage error rather than a "✓ saved config" that leaves the tool unusable.
- Trimming the history can no longer empty it. When a single record exceeded the
  trim budget, nothing fit, `trimmed` returned an empty string, and the caller
  wrote that over the file — deleting every recorded link to enforce a size limit.
  The newest record is now kept unconditionally. Reachable in 0.2.0–0.2.2 with a
  pathological `--name`, whose control characters JSON-escape to six times their
  length.
- A closed reader no longer crashes the process. `gitpic list | head`,
  `gitpic completion zsh | true`, `gitpic skill print | head` — any consumer that
  stops reading — made `println!` panic, and with `panic = "abort"` that is SIGABRT:
  exit 134, outside the documented 1-10 contract, with a raw Rust panic on stderr.
  A closed pipe is not an error, so the process now exits 0, which is what `head`
  and friends expect. Every stdout write in the crate goes through one guarded
  place, `completion` included — it wrote through `clap_complete`'s own `.expect()`,
  where this crate could not intercept it.
- Concurrent uploads no longer corrupt the history. `writeln!` emits the record and
  its newline as two separate `write` calls; `O_APPEND` makes each atomic but not
  the pair, so a second process appending at the same time landed its record
  between them. Merged lines were then skipped by the reader without a word —
  records silently missing from `gitpic list`. It is one `write_all` now, and the
  trim's temp file carries the pid so two trims cannot write the same path.
- Config *values* are validated wherever they arrive, not just through
  `config set`. `deny_unknown_fields` guarded key names; a hand-edited
  `link_kind = "raw2"` or `GITPIC_LINK=raw2` still loaded and the lenient reader
  then served cdn links forever. `github.owner` had no validation at all, so
  `config set github.owner "  me  "` produced `/repos/%20%20me%20%20/repo` — the
  exact failure env-var trimming was added to prevent, on the entry point it did
  not cover — and `..` silently removed a path segment. An empty `github.branch`
  and an out-of-range `upload.quality` in the file are likewise refused instead of
  reaching a 422 or a silent clamp. One `validate` now runs for the file, the
  environment and `config set` alike.
- `gitpic --stdin` names the upload from the bytes instead of always calling it
  `image.png`. `cat photo.jpg | gitpic --stdin` published JPEG data at a `.png`
  path, which GitHub and jsDelivr then served as `image/png`. This is the same
  defect fixed for `paste --name shot.jpg` in 0.2.0, on the source that fix missed:
  the extension comes from the content and `--name` supplies only the stem.
  Unidentifiable bytes with no `--name` are a usage error rather than a wrong
  `.png`.
- `--json` is honoured by every subcommand that produces output. `config path`
  printed a bare path, `config get` printed TOML, and `skill print` printed raw
  Markdown, so an agent following the skill's "always pass `--json`" instruction got
  a parse error. `init` is interactive and now rejects `--json` outright rather than
  interleaving prompts with an envelope.
- `--quiet` prints only machine-usable lines. `gitpic list --quiet` rendered the
  full human listing, and on an empty history printed "no uploads recorded yet" —
  prose a script had to filter out. It is one URL per line now, matching what the
  upload path already did.

### Added
- `gitpic doctor` reports `branch_protected`. Protection does not mean this
  account cannot write, so it does not make a report unhealthy, but it is the
  usual explanation when an upload is refused after every preflight check passed.
- `tests/json_contract.rs`, which spawns the built binary. The `--json` and
  broken-pipe contracts live in the wiring between `dispatch` and each renderer,
  which no unit test can reach — a source-scanning check written first passed while
  the bugs were still present, so it was replaced with this.

## [0.2.3] - 2026-08-18

### Config persistence and release contracts tightened

### Fixed
- Config is written to a same-directory temporary file, fully flushed, and only
  then replaces the destination, preventing an interrupted process from leaving
  half a TOML document. On Unix, mode `0600` is enforced from temporary-file
  creation onward and permission errors are no longer ignored.
- Invalid-config diagnostics no longer echo the TOML source line, so a syntax
  error on `github.token` cannot print the credential. The unknown field name and
  the `gitpic config edit` recovery hint remain available.
- Markdown output escapes parentheses and backslashes in URL destinations, so a
  valid address containing those characters cannot terminate the image link.

### CI
- Release notes only accept a changelog heading that exactly matches the tag and
  reject whitespace-only sections. A heading such as `0.2.3-extra` can no longer
  be mistaken for `0.2.3`.

## [0.2.2] - 2026-08-17

### Input that cannot take effect is now refused

> **Upgrade note**: calls like `gitpic list --compress` now report a USAGE error
> (exit 2) instead of exiting 0. Only scripts that pass upload options to a
> non-upload subcommand are affected — those options never took effect, so such a
> script was not doing what it appeared to.

### Fixed
- A path template that escapes the repository is rejected instead of producing a
  bare 404. `upload.path_template = "../../../etc/{name}.{ext}"` was accepted and
  then sent to the Contents API, which answers with an unexplained "Not Found".
  The check runs on the *rendered* path — the one point all three template sources
  funnel into (`config set`, `--path`, a hand-edited file) — and `config set` also
  renders a sample so a bad template fails when it is set.
- Upload-only options are refused by the subcommands that ignore them.
  `gitpic list --compress --max-width 99` parsed, exited 0, and quietly did none
  of it; the same held for `completion`, `config`, `skill` and `init`. They stay
  `global = true` so `gitpic paste --no-copy` keeps working, but `dispatch` now
  reports the ones the chosen subcommand cannot act on. `--json`, `--quiet` and
  `--verbose` mean something everywhere and are unaffected; `--repo` is still
  accepted by `doctor`, which resolves a target.
- `history.jsonl` no longer grows without bound. Past 2 MB it is trimmed to the
  newest half, written to a temp file and renamed so an interrupted trim cannot
  leave a partial history. The trim runs only when a cheap metadata check says the
  file is over the ceiling, so an ordinary append does not read the file at all.
  **This drops the oldest records**, which contain links to old uploads.

### CI
- The release workflow no longer has four jobs racing to create the same Release.
  Each build now uploads an artifact and a single `publish` job downloads all of
  them, verifies four archives and four sidecars are present, and makes one
  `action-gh-release` call. The Release can no longer appear half-populated while
  other platforms are still building, and the four build jobs run with a read-only
  token — only `publish` can write.
- The Windows checksum sidecar matches `shasum -a 256` byte for byte (lowercase
  hash, two spaces, filename, LF, no BOM). `(Get-FileHash).Hash | Out-File` wrote
  an uppercase hash with no filename, which `shasum -c` cannot read at all. Every
  sidecar is now verified in CI, on the platform that produced it and again before
  publishing — the Windows format is not something a maintainer on macOS can check
  locally.
- `check_manifests.py` requires both changelogs to carry a section for the version
  in `Cargo.toml`. `release.yml` only ever read the Chinese one, so a release could
  ship with `CHANGELOG.md` left at `## [Unreleased]` and CI would stay green, even
  though AGENTS.md requires the two to stay aligned.

## [0.2.1] - 2026-08-17

### `doctor` can tell a broken credential from a GitHub hiccup

### Fixed
- `gitpic doctor` no longer gates the repository check on the credential check.
  The two answer different questions — `/user` asks "is this credential
  accepted", `/repos/{owner}/{repo}` asks "can it write here" — and an upload
  only ever calls the second kind. Because the repository probe ran only after
  `/user` succeeded, a transient 503 on `/user` reported
  `repo_writable: false` as well, which is indistinguishable from a bad
  credential. Observed live: `gh api user` returned 503 while
  `gh api repos/...` returned `push: true`, and `doctor` still reported
  everything red. Both probes now run concurrently and report independently, so
  that fault reads as `token_valid: false, repo_writable: true` with a
  retryable `NETWORK` code.
- When both probes fail, a definite answer now outranks `NETWORK`, which only
  ever means "could not tell". A 503 on `/user` no longer masks a 401 from the
  repository endpoint, so a genuinely bad credential is still reported as
  `AUTH_FAILED` rather than as something to retry forever.
- The agent skill told agents to send the user to `gh auth login` whenever
  `token_valid` was false. It now says to read the two checks together and
  retry instead when `repo_writable` is true and the code is `NETWORK` — the
  case where `gh auth login` cannot help.

## [0.2.0] - 2026-08-17

### Credentials no longer need to live in the config file

`config.toml` stored the GitHub token in plaintext, which made the file unsafe to
keep in a synced dotfiles repo — and a classic PAT with `repo` scope grants
read/write on every repository the account can reach, with no expiry.

### Breaking
- Config file keys are now validated strictly. A misspelled key or section
  (`dedupe`, `[uplaod]`) previously loaded fine and was silently ignored; it now
  makes every command that reads the config fail with `CONFIG_INVALID` (exit `10`)
  until the file is corrected. **If this error appears right after upgrading, the
  config has been carrying a typo that never took effect** — the message names the
  file and the offending line, and `gitpic config path` / `gitpic config edit`
  keep working so it can be repaired.
- Exit code `10` is new, so the published exit-code contract widens from `1-9` to
  `1-10`. It is purely additive and no existing code changed meaning, but a script
  that exhaustively matches `1-9` needs one more arm.

### Changed
- The credential is resolved from, in order: `GITPIC_TOKEN`, `github.token` in
  the config file, then `gh auth token`. With `gh` logged in, `config.toml` needs
  no secret at all and is safe to sync.
- A `github.token` left in the config keeps working and still takes priority over
  `gh`, so upgrading never silently switches which account uploads. Delete that
  line to switch over.
- `gitpic doctor` reports `token_source` (`env` / `config` / `gh`), so which
  credential is actually in use can be confirmed.
- The credential is resolved lazily, immediately before a request is made, so it
  is never stored in `Config` — whose derived `Debug` could otherwise print it.
  An unavailable credential now surfaces as `token_valid: false` rather than
  `config_ok: false`.
- The `gitpic init` token prompt can be left blank to use `gh`, and its label says
  so. (It is still the first field.)

Note: `gh`'s OAuth token typically carries `gist, read:org, repo, workflow` —
*broader* than writing to one image repo requires. This change keeps the secret
out of a syncable file; it does not narrow the token's scope. For least
privilege, pass a fine-grained token limited to the one repo via `GITPIC_TOKEN`.

### Fixed
- `gitpic paste --name shot.jpg` no longer publishes PNG bytes at a `.jpg` path.
  Clipboard captures are always encoded as PNG, so the extension is now derived
  from that rather than taken from `--name`; GitHub and jsDelivr were serving
  those uploads as `image/jpeg`.
- `gitpic config set upload.link_kind` and the `gitpic init` prompt now reject
  anything other than `cdn`/`raw`. A typo previously reported success and then
  silently produced CDN links forever, because the reader falls back to `cdn`.
- A blank `GITPIC_OWNER`, `GITPIC_BRANCH`, `GITPIC_LINK`, or `GITPIC_REPO` now
  falls through to the config file instead of overriding it with whitespace.
  `GITPIC_OWNER=" "` used to pass the config check and then produce a request
  against `/repos/%20/repo` — a confusing 404 rather than an actionable error.
  Surrounding whitespace is now trimmed too: the blank check looked at the
  trimmed value but stored the untrimmed one, so `GITPIC_OWNER=" me "` requested
  `/repos/%20me%20/repo`.
- A misspelled key or section in `config.toml` is now rejected instead of being
  silently ignored. `dedupe = false` or `[uplaod]` parsed fine and did nothing,
  with `gitpic config get` then showing the default as if the file had never been
  edited — the same class of failure as the two above, on the one input that is
  meant to be hand-edited (`gitpic config edit`). The error names the file and the
  offending line; `gitpic config path` and `gitpic config edit` keep working so the
  file can be repaired.
- A branch name is percent-encoded before it goes into a URL. Git allows `&`, `#`,
  `+`, `%` and `=` in a ref, and each one silently changed what the request meant:
  `#` made the rest of the URL a fragment, `&` started another parameter, `+`
  decoded to a space. The lookup then read the *wrong* ref, which looks like
  "nothing uploaded here yet" — losing deduplication and omitting the sha from the
  upload, so overwriting an existing file failed with a 409. The generated
  Markdown links were affected the same way.
- `gitpic list` now labels a deduplicated upload `(deduped)`, matching the word
  the upload output already used.

### Added
- Exit code `10` / `CONFIG_INVALID`, for a config file that exists but cannot be
  read or parsed. It was previously exit `1` / `GENERAL`, the catch-all that also
  covers clipboard and encoding failures, so nothing could act on it. `3` /
  `CONFIG_MISSING` still means "nothing configured yet" (`gitpic init`); `10` means
  "configured, but the file is broken" (`gitpic config edit`).
- Exit code `1` / `GENERAL` is now documented in both READMEs and the agent skill.
  It was always reachable — clipboard init, PNG encoding, launching `$EDITOR` — but
  the tables started at `2`, so a script built from them mis-classified it.

### Removed
- Dropped the unused `anyhow` and `thiserror` dependencies, along with the
  unreachable `image/webp` and the unused `tokio/fs`, `tokio/io-std`, and
  `clap/env` cargo features. Three crates leave the build graph.

### Docs
- Both READMEs claimed environment variables had the "highest priority". CLI flags
  override them — `GITPIC_LINK=raw gitpic a.png --link cdn` produces a cdn link —
  which is what `src/config.rs` documented all along.
- `GITPIC_OWNER` is documented (it was implemented but appeared in neither README).
- The English README's Install section only offered `cargo install --path .`, which
  cannot work outside a clone, while later sections referred to Homebrew and release
  archives it never mentioned. It now mirrors the Chinese one.
- The demo transcripts showed a `📋 copied to clipboard` line the binary never
  prints (a successful copy is silent; only failure is reported), and abbreviated
  `gitpic init` down to its final line.

### CI
- The release workflow now uploads `gitpic-<target>.*` with
  `fail_on_unmatched_files: true`. Listing four archive names of which two never
  exist on any given platform forced that check off, which meant a release that
  uploaded *nothing* still passed as green.
- `cargo fmt --check` runs on Linux only, since rustfmt's verdict is
  platform-independent, and the redundant `cargo build` step is gone —
  `clippy --all-targets` type-checks the same cfg and `cargo test` links a real
  executable, exercising every native dependency.

## [0.1.8] - 2026-08-14

### Fixed
- Pin `SKILL.md` to LF via `.gitattributes`. A Windows checkout was embedding
  CRLF through `include_str!`, so `gitpic skill install` always treated an
  already-installed copy as outdated.

## [0.1.7] - 2026-08-14

### An install path for the agent skill

`SKILL.md` previously just sat in the repository root with no way to install it —
but Claude Code and Codex both discover skills only at
`<skills-dir>/<name>/SKILL.md`, so the root copy was never loaded. Users had to
copy it by hand, and hand-copies drift: one was found stuck at 0.1.5, missing the
partial-success semantics for multi-image uploads.

### Added
- New `gitpic skill` subcommand: `install` / `print` / `path`. The document is
  embedded with `include_str!`, so an installed copy always matches the version of
  `gitpic` that wrote it.
- `gitpic skill install` detects `~/.claude/skills` and `~/.codex/skills`
  (honouring `CLAUDE_CONFIG_DIR` / `CODEX_HOME`) and prompts before writing;
  `--agent`, `--dir`, and `--yes` skip the prompt. Agents whose skills
  directories are symlinked to one place collapse into a single target instead of
  being written twice. Without a terminal (scripts, CI, agent calls) it returns a
  `USAGE` error rather than hanging or writing unasked.
- Claude Code marketplace manifest, installable with
  `/plugin marketplace add tarnish233/gitpic`.
- Codex plugin manifest, installable with
  `codex plugin marketplace add tarnish233/gitpic`.

### Changed
- Moved `SKILL.md` to `skills/gitpic/SKILL.md`. That is where both plugin formats
  look, so all three distribution channels share one source file with no copies.
  CI now asserts the manifest versions still match `Cargo.toml`.

## [0.1.6] - 2026-08-04

### Link correctness and credential safety
- Fix path and filename handling that produced links which did not resolve.
- Add network timeouts so the command can no longer hang indefinitely.
- Stop mixing terminal colour codes into redirected output.
- Keep links for images that already uploaded when a later one fails.

### Fixed
- Sanitize the `{ext}` placeholder like `{name}`: a filename such as `a.p#ng` no
  longer produces a truncated remote path or a broken link.
- Add request and connect timeouts to the GitHub client. A stalled connection
  previously hung the CLI indefinitely instead of reporting a retryable
  `NETWORK` error.
- Strip ANSI colour codes when stdout/stderr is not a terminal, and honour
  `NO_COLOR` / `CLICOLOR_FORCE`.
- Keep links for images that already uploaded when a later image in the same
  invocation fails. `--json` reports these under a new envelope carrying both
  `results` and `error`. When nothing uploaded, the existing error envelope is
  used unchanged.
- Percent-encode remote paths in API requests and generated URLs, so templates
  containing spaces or non-ASCII characters produce valid links.
- Escape alt text in Markdown and HTML output; `a]b.png` no longer emits broken
  Markdown, and quotes can no longer escape the HTML `alt` attribute.
- Reject a repo spec with extra path segments (`a/b/c`) instead of silently
  setting the repo to `b/c`.
- Reject `--quality` outside 1-100 at parse time, matching
  `config set upload.quality`. `--quality 0` was previously clamped to 1.
- Reject `--stdin` combined with file arguments, and `--stdin` combined with
  `paste`, instead of silently ignoring an input.
- Warn when a branch containing `/` is used with jsDelivr CDN links, where the
  branch/path boundary is ambiguous.

### Changed
- Report a warning when an upload cannot be recorded in local history, at `-v`.

### Performance
- Avoid copying image bytes when compression is disabled.
- Build the upload request body without an intermediate `serde_json::Value`,
  removing one full copy of the base64 payload.
- Hash to hex without a per-byte allocation.

## [0.1.5] - 2026-07-28

### Safer credentials and reliable agent workflows
- Protect configured GitHub tokens from accidental terminal or agent output.
- Make health checks and JSON errors deterministic for scripts and agents.

### Fixed
- Redact configured GitHub tokens from `config get` and interactive prompts.
- Preserve malformed configurations instead of silently replacing them with defaults.
- Compare Git blob hashes before treating an existing remote path as deduplicated.
- Emit JSON for argument errors when `--json` is requested, and make unhealthy
  `doctor` reports exit non-zero.
- Distinguish authentication, permission, remote-not-found, rate-limit, and
  retryable GitHub server errors.

## [0.1.4] - 2026-07-25

### CI
- Bump `actions/checkout` to v5 and `softprops/action-gh-release` to v3
  (Node 24 runtimes) to clear the Node 20 deprecation warnings.

## [0.1.3] - 2026-07-25

### Changed
- `gitpic config set upload.quality` now rejects values outside `1-100`
  instead of silently storing an out-of-range value (it was clamped at
  compression time anyway).

## [0.1.2] - 2026-07-23

### Fixed
- Upload options (`--link`, `--format`, `--no-copy`, `--name`, `--stdin`,
  `--path`, `--repo`, `--compress`, `--max-width`, `--quality`) are now global,
  so they work after a subcommand too, e.g. `gitpic paste --name shot.png --link raw`.
- `--verbose`/`-v` now emits progress diagnostics to stderr (was a no-op).
- `--max-width` resize is honored even when the re-encoded file is not smaller
  (resize intent no longer silently discarded).
- Non-ASCII filenames no longer all collapse to `image`; the remote name falls
  back to the content hash so distinct images stay unique.

### Tests
- Added CLI parsing tests (options after subcommand), a non-ASCII naming test,
  and an image-resize test.

## [0.1.1] - 2026-07-23

### Changed
- Config now lives at `~/.config/gitpic/config.toml` (honors `$XDG_CONFIG_HOME`);
  upload history at `~/.local/share/gitpic/history.jsonl` (honors `$XDG_DATA_HOME`).
- Dropped the `directories` dependency in favor of XDG-style path resolution.

### Packaging
- Homebrew formula now auto-installs shell completions (bash, zsh, fish).
- Added a Chinese README (default) with an English version at `README.en.md`.

## [0.1.0] - 2026-07-22

### Added
- Upload local images to a GitHub repo (image host) and print a Markdown link.
- Sources: file paths, `--stdin`, and clipboard (`gitpic paste`).
- Output: Markdown / HTML / plain URL, with jsDelivr CDN or GitHub raw links.
- Auto-copy result to the clipboard (human mode).
- Content hashing with dedup, and a configurable remote path template.
- Image compression / resizing (`--compress`, `--max-width`, `--quality`).
- Upload history (`gitpic list`) stored as JSONL.
- Shell completion generator (`gitpic completion <shell>`).
- `gitpic doctor` health check, `gitpic init`, and `gitpic config` management.
- Agent-friendly mode: `--json` output with a stable schema and exit codes;
  bundled `SKILL.md`.
- GitHub Actions CI (fmt / clippy / build / test on Linux, macOS, Windows) and a
  tag-triggered multi-platform release workflow.

[0.18.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.18.1
[0.18.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.18.0
[0.17.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.17.0
[0.16.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.16.0
[0.15.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.15.0
[0.14.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.14.1
[0.14.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.14.0
[0.13.2]: https://github.com/tarnish233/gitpic/releases/tag/v0.13.2
[0.13.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.13.1
[0.13.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.13.0
[0.12.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.12.0
[0.11.5]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.5
[0.11.4]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.4
[0.11.3]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.3
[0.11.2]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.2
[0.11.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.1
[0.11.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.11.0
[0.10.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.10.0
[0.9.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.9.0
[0.8.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.8.0
[0.7.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.7.0
[0.6.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.6.0
[0.5.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.5.1
[0.5.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.5.0
[0.4.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.4.0
[0.3.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.3.0
[0.2.3]: https://github.com/tarnish233/gitpic/releases/tag/v0.2.3
[0.2.2]: https://github.com/tarnish233/gitpic/releases/tag/v0.2.2
[0.2.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.2.1
[0.2.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.2.0
[0.1.6]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.6
[0.1.5]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.5
[0.1.4]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.4
[0.1.3]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.3
[0.1.2]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.2
[0.1.1]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.1
[0.1.0]: https://github.com/tarnish233/gitpic/releases/tag/v0.1.0

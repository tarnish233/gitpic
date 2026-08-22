# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  `/plugin marketplace add tarnish233/gitpic-cli`.
- Codex plugin manifest, installable with
  `codex plugin marketplace add tarnish233/gitpic-cli`.

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

[Unreleased]: https://github.com/tarnish233/gitpic-cli/compare/v0.11.4...HEAD
[0.11.4]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.11.4
[0.11.3]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.11.3
[0.11.2]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.11.2
[0.11.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.11.1
[0.11.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.11.0
[0.10.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.10.0
[0.9.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.9.0
[0.8.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.8.0
[0.7.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.7.0
[0.6.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.6.0
[0.5.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.5.1
[0.5.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.5.0
[0.4.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.4.0
[0.3.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.3.0
[0.2.3]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.2.3
[0.2.2]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.2.2
[0.2.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.2.1
[0.2.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.2.0
[0.1.6]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.6
[0.1.5]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.5
[0.1.4]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.4
[0.1.3]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.3
[0.1.2]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.2
[0.1.1]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.1
[0.1.0]: https://github.com/tarnish233/gitpic-cli/releases/tag/v0.1.0

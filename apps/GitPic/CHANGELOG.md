# Changelog — GitPic.app

The macOS app versions independently of the `gitpic` CLI. Each app release pins
the CLI build it embeds; that version is recorded in the bundle's
`GitPicEmbeddedCLIVersion` key and shown in the app's About pane.

The CLI's own changelogs are `CHANGELOG.md` and `CHANGELOG.zh-CN.md` at the
repository root.

## [0.1.1] — 2026-08-20

### A monochrome icon that belongs on macOS

### Changed

- Added a dedicated GitPic application icon: a black, rounded double-photo mark
  on a clean white field, derived from the menu-bar app's stacked-photo concept.
- The app build now creates a complete multi-resolution `.icns` from the checked-in
  1024 px source and declares it through `CFBundleIconFile`, so Finder, Settings,
  and other macOS surfaces use the GitPic icon instead of the generic executable
  icon.

## [0.1.0] — 2026-08-19

First version. Menu-bar app driving the bundled CLI over its `--json` contract.

### Added

- Menu-bar item: upload from the clipboard, pick files, switch link format
  (Markdown / HTML / CDN / Raw), re-copy a recent upload, run `doctor`. Progress,
  success, and failure all report on the status item — its symbol, its tooltip,
  and the main window's status line.
- Main window: target repository, upload settings (all ten CLI config keys),
  history browser, and an About pane showing resolved tool paths.
- `gitpic` is embedded in the bundle and invoked by absolute path.
- `gh` is discovered at launch (Homebrew paths, then a login-shell probe) and its
  directory is prepended to the `PATH` handed to the CLI child process.
- Launch diagnostics at `~/Library/Logs/GitPic.log`.
- `GITPIC_APP_DRY_RUN=1` records what would be uploaded without uploading. Both
  upload entry points honour it.

### Not in this version

- **The notch drop zone.** The panel is written and the platform constraints
  behind it are measured (see below), but a real Finder-to-panel drag was never
  verified end to end, so it does not start with the app. `defaults write
  dev.gitpic.app NotchDropZone -bool true` opts in. With it off the app has no
  drag-and-drop target: upload from the clipboard or the file picker.

### Notes on constraints this version works within

- **A Finder-launched app gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.** The CLI
  resolves `gh` by bare name with no override, so without the discovery step
  above every upload fails with `CONFIG_MISSING`. Measured, not assumed —
  reproducing it requires launching via Finder, since `open(1)` propagates the
  caller's environment and hides the problem.
- **The menu-bar strip delivers no mouse or drag events to any window, at any
  window level.** Any drop target therefore has to hang below it. Tested at
  shielding, statusBar+1, mainMenu+1, popUpMenu, and floating levels.
- **Menu icons need normalising.** `NSMenuItem` draws each image at the image's
  own size, and SF Symbols have per-glyph bounding boxes — 21–28 px wide and
  19–25 px tall at 2x for the symbols in this menu — so the icon column is ragged
  unless every symbol is centred in one shared box. The default `.medium` symbol
  scale also renders heavier than any system menu; `.small` at the menu font's
  point size matches Finder's own metrics. A section header is laid out at the
  icon column rather than the title column, so it needs a spacer image to line up
  with the items under it.
- **The app is ad-hoc signed and is not notarised.** It runs when built locally.
  Downloaded copies are blocked by Gatekeeper until a Developer ID certificate
  exists. The machine's only Apple Development identity is revoked in effect —
  signing with it produces a binary the kernel kills on exec.
- Uploads are serialised through one actor: concurrent CLI processes race on the
  branch ref and surface as an unmapped 409.

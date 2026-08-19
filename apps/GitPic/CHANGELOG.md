# Changelog — GitPic.app

The macOS app versions independently of the `gitpic` CLI. Each app release pins
the CLI build it embeds; that version is recorded in the bundle's
`GitPicEmbeddedCLIVersion` key and shown in the app's About pane.

The CLI's own changelogs are `CHANGELOG.md` and `CHANGELOG.zh-CN.md` at the
repository root.

## [0.1.0] — unreleased

First version. Menu-bar app with a notch drop zone, driving the bundled CLI over
its `--json` contract.

### Added

- Menu-bar item: upload from the clipboard, pick files, switch link format
  (Markdown / HTML / CDN / Raw), re-copy a recent upload, run `doctor`.
- Notch drop zone: drag images onto the island under the notch. The interactive
  area is the strip *below* the menu bar — see the constraint note below.
- Main window: target repository, upload settings (all ten CLI config keys),
  history browser, and an About pane showing resolved tool paths.
- `gitpic` is embedded in the bundle and invoked by absolute path.
- `gh` is discovered at launch (Homebrew paths, then a login-shell probe) and its
  directory is prepended to the `PATH` handed to the CLI child process.
- Launch diagnostics at `~/Library/Logs/GitPic.log`.
- `GITPIC_APP_DRY_RUN=1` records drops without uploading.

### Notes on constraints this version works within

- **A Finder-launched app gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.** The CLI
  resolves `gh` by bare name with no override, so without the discovery step
  above every upload fails with `CONFIG_MISSING`. Measured, not assumed —
  reproducing it requires launching via Finder, since `open(1)` propagates the
  caller's environment and hides the problem.
- **The menu-bar strip delivers no mouse or drag events to any window, at any
  window level.** The drop target therefore hangs below it. Tested at
  shielding, statusBar+1, mainMenu+1, popUpMenu, and floating levels.
- **The app is ad-hoc signed and is not notarised.** It runs when built locally.
  Downloaded copies are blocked by Gatekeeper until a Developer ID certificate
  exists. The machine's only Apple Development identity is revoked in effect —
  signing with it produces a binary the kernel kills on exec.
- Uploads are serialised through one actor: concurrent CLI processes race on the
  branch ref and surface as an unmapped 409.

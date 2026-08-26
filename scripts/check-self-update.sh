#!/usr/bin/env bash
# Install a deliberately-old GitPic.app, run a REAL in-app update, and assert that the
# old process exits and a new one comes back on the new version.
#
# **Run this before any release that touches the update path.** Not as a nicety — this
# script exists because 0.20.0 shipped an in-app updater that downloaded, verified,
# staged and handed off correctly and then *did not quit*, so the swap script's wait
# expired, it renamed the bundle out from under a live process, and `open -a` merely
# reactivated the old build. 243 unit tests and a full `GITPIC_APP_DRY_RUN=1` pass were
# green, and none of them could have caught it: `GITPIC_APP_DRY_RUN=1` returns before the
# quit, `GitPicApp` is an executableTarget that tests cannot import, and the refusal came
# from AppKit ("App termination blocked by modal sheet") rather than from our code. A real
# install was the only thing that could see it, and no real install was run.
#
# So the rule is the narrow one that would have caught it: no release that changes
# `Updater.swift`, `SelfUpdate*.swift`, `UpdateSheet.swift` or the quit goes out until this
# has been run and passed on a real machine. See AGENTS.md.
#
# WHAT IT TOUCHES, AND WHAT IT REFUSES TO
#   * writes only to ~/Applications/GitPic.app and a temp build directory;
#   * never reads, writes, or opens anything in /Applications — the machine's own GitPic
#     (Homebrew's, usually) is recorded before and after and the run fails if it moved;
#   * gives the test copy its own CFBundleIdentifier so Launch Services cannot conflate it
#     with the installed one, and re-signs it ad-hoc;
#   * appends to the machine-wide ~/Library/Logs/GitPic.log and GitPic-update.log, and
#     never truncates either.
#
# IT IS NOT UNATTENDED-SAFE IN ONE RESPECT: it downloads the real published DMG from
# GitHub and installs it, so it needs network and it makes real changes under
# ~/Applications. It drives the UI through System Events, which needs this terminal to
# hold an Accessibility grant.
#
# USAGE
#   scripts/check-self-update.sh            # build, install, update, assert, clean up
#   scripts/check-self-update.sh --keep     # leave the test copy in place for inspection
#   scripts/check-self-update.sh --force    # replace an existing ~/Applications/GitPic.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_APP="$HOME/Applications/GitPic.app"
# Its own identifier so `open` and Launch Services cannot resolve this copy to the one in
# /Applications. Without it the launch can hand the request to the already-running installed
# app and the whole run measures the wrong process (established the hard way).
TEST_BUNDLE_ID="dev.gitpic.app.selfupdatecheck"
# Anything below the published latest makes the app offer an update; a version this absurd
# also makes it obvious in the log which lines are the test's.
OLD_VERSION="0.0.1"
APP_LOG="$HOME/Library/Logs/GitPic.log"
UPDATE_LOG="$HOME/Library/Logs/GitPic-update.log"

KEEP=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --keep)  KEEP=1 ;;
    --force) FORCE=1 ;;
    *) echo "error: unknown argument $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only"

# ---------------------------------------------------------------- preflight

# The one directory this must never be confused about.
case "$TEST_APP" in
  "$HOME"/Applications/*) ;;
  *) fail "refusing to install outside \$HOME/Applications (got $TEST_APP)" ;;
esac

if [[ -e "$TEST_APP" && $FORCE -eq 0 ]]; then
  fail "$TEST_APP already exists. Move it aside, or pass --force to replace it."
fi

# The machine's own copy, recorded so the run can prove it left it alone. Read with
# PlistBuddy rather than opened: nothing here may launch it.
SYSTEM_APP="/Applications/GitPic.app"
system_fingerprint() {
  if [[ -d "$SYSTEM_APP" ]]; then
    local version
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "$SYSTEM_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
    printf '%s %s' "$version" "$(stat -f '%m %i' "$SYSTEM_APP")"
  else
    printf 'absent'
  fi
}
SYSTEM_BEFORE="$(system_fingerprint)"
echo "    /Applications/GitPic.app before: $SYSTEM_BEFORE"

# Where the log is now, so a failure can print only this run's lines.
LOG_MARK=0
[[ -f "$APP_LOG" ]] && LOG_MARK="$(wc -c < "$APP_LOG" | tr -d ' ')"

# The real version, parsed the way build-app.sh parses it.
cargo_version() {
  awk '/^\[package\]/ { inpkg = 1; next }
       /^\[/          { inpkg = 0 }
       inpkg && /^version[[:space:]]*=/ {
         gsub(/^version[[:space:]]*=[[:space:]]*"|"[[:space:]]*$/, ""); print; exit
       }' "$ROOT/Cargo.toml"
}
REAL_VERSION="$(cargo_version)"
[[ -n "$REAL_VERSION" ]] || fail "no [package] version in Cargo.toml"

# ------------------------------------------------------- build the old bundle

# Cargo.toml's version is the app's version, so making the app old means editing it. Saved
# and restored through the trap rather than through git: `git checkout --` here would also
# discard whatever else the working tree had in flight, and this repo is worked by several
# agents at once (AGENTS.md).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gitpic-selfupdate-check.XXXXXX")"
cp "$ROOT/Cargo.toml" "$WORK/Cargo.toml.orig"
cp "$ROOT/Cargo.lock" "$WORK/Cargo.lock.orig"
RESTORED=0
# Set by the restore check in `cleanup` when it could not put Cargo.toml back: the
# pristine copies have to outlive the run so there is something to restore from.
KEEP_WORK=0
TEST_PID=""

cleanup() {
  local code=$?
  set +e
  if [[ $RESTORED -eq 0 ]]; then
    RESTORED=1
    step "restoring Cargo.toml/Cargo.lock and the shared release binary"
    cp "$WORK/Cargo.toml.orig" "$ROOT/Cargo.toml"
    cp "$WORK/Cargo.lock.orig" "$ROOT/Cargo.lock"
    # Checked, not announced. This message used to print unconditionally while the copies
    # above were unchecked (`set +e` is on, and neither had a `||`), so a restore that did
    # not happen was indistinguishable from one that did — and the repository was left at
    # $OLD_VERSION with the script claiming otherwise. Observed once, on 2026-08-25.
    local back
    back="$(cargo_version)"
    if [[ "$back" != "$REAL_VERSION" ]]; then
      # An error and not a warning-on-the-way-past. This used to warn and then fall straight
      # into the rebuild below, which would bake $OLD_VERSION into the shared
      # CARGO_TARGET_DIR — the exact outcome that rebuild exists to prevent — and then exit 0
      # with `PASS` already printed above. So: skip the rebuild, keep $WORK so the pristine
      # copies are still there to restore *from*, and fail the run.
      KEEP_WORK=1
      code=1
      echo "    ERROR: Cargo.toml is at ${back:-<unreadable>}, not $REAL_VERSION." >&2
      echo "    Restore from the copies this run saved, not from git — 'git checkout --'" >&2
      echo "    would also discard whatever else this working tree had in flight, and the" >&2
      echo "    repo is worked by several agents at once (AGENTS.md):" >&2
      echo "      cp $WORK/Cargo.toml.orig $ROOT/Cargo.toml" >&2
      echo "      cp $WORK/Cargo.lock.orig $ROOT/Cargo.lock" >&2
      echo "      (cd $ROOT && cargo build --release)" >&2
    else
      # The release binary lives in a CARGO_TARGET_DIR shared with every other worktree
      # (AGENTS.md), so leaving it built at $OLD_VERSION would make the next agent's
      # build-app.sh fail its version guard on a "stale binary" that this script staled.
      if ! ( cd "$ROOT" && cargo build --release >/dev/null 2>&1 ); then
        code=1
        echo "    ERROR: could not rebuild $REAL_VERSION, so the shared release binary may" >&2
        echo "    still be at $OLD_VERSION. Run 'cargo build --release'." >&2
      fi
    fi
  fi
  if [[ $KEEP -eq 0 ]]; then
    if [[ -n "$TEST_PID" ]] && kill -0 "$TEST_PID" 2>/dev/null; then kill "$TEST_PID"; fi
    # Whatever came back after the update, too — by path, so only copies under
    # ~/Applications are ever signalled.
    pkill -f "^$HOME/Applications/GitPic.app/Contents/MacOS/GitPic$" 2>/dev/null
    sleep 1
    rm -rf "$TEST_APP"
    # The install keeps a rollback copy and may leave a staging directory beside the app.
    rm -rf "$HOME"/Applications/.GitPic-old-* "$HOME"/Applications/.GitPic-update-*
  else
    echo "    --keep: left $TEST_APP in place"
  fi
  if [[ $KEEP_WORK -eq 0 ]]; then rm -rf "$WORK"; else echo "    left $WORK in place" >&2; fi
  if (( code != 0 )) && [[ -f "$APP_LOG" ]]; then
    echo
    echo "--- $APP_LOG (this run) ---"
    tail -c "+$((LOG_MARK + 1))" "$APP_LOG"
    echo "--- $UPDATE_LOG (last 20) ---"
    tail -20 "$UPDATE_LOG" 2>/dev/null
  fi
  exit "$code"
}
trap cleanup EXIT

step "building GitPic.app at $OLD_VERSION (real version is $REAL_VERSION)"
# Whole-line replacement of the [package] version only, anchored, so a `version =` under
# some [dependencies.*] table cannot be hit.
awk -v v="$OLD_VERSION" '
  /^\[package\]/ { inpkg = 1 }
  /^\[/ && !/^\[package\]/ { inpkg = 0 }
  inpkg && /^version[[:space:]]*=/ && !done { print "version = \"" v "\""; done = 1; next }
  { print }
' "$WORK/Cargo.toml.orig" > "$ROOT/Cargo.toml"
[[ "$(cargo_version)" == "$OLD_VERSION" ]] || fail "could not rewrite Cargo.toml's version"

# The binary first, then the bundle: build-app.sh rejects a CARGO_TARGET_DIR/release/gitpic
# whose --version disagrees with Cargo.toml, which is exactly what a stale one is.
( cd "$ROOT" && cargo build --release )
OUT="$WORK/dist-app" "$ROOT/scripts/build-app.sh" >"$WORK/build.log" 2>&1 \
  || { cat "$WORK/build.log"; fail "build-app.sh failed"; }
BUILT="$WORK/dist-app/GitPic.app"
[[ -d "$BUILT" ]] || fail "no bundle at $BUILT"

# What the app will find, asked through the same CLI code the app calls. Doing it here
# rather than after the install means a release feed that cannot be reached fails the run
# with a clear message instead of as a UI timeout.
step "asking the CLI what the latest release is"
# The CLI's own error is kept rather than sent to /dev/null. It used to be discarded and the
# failure reported as "no network, or the release feed is unreachable" — a guess, and on the
# run that prompted this an actively wrong one: the feed was reachable and the real cause was
# an exhausted unauthenticated rate limit (60/hr, shared with anything else on the machine
# touching api.github.com). `update check` already answers precisely — RATE_LIMITED vs
# REMOTE_NOT_FOUND vs NETWORK — so the gate's job is to pass that answer on, not to invent one.
UPDATE_JSON="$("$BUILT/Contents/Resources/gitpic" update check --json 2>"$WORK/update-check.err")" \
  || fail "gitpic update check exited non-zero:
$(cat "$WORK/update-check.err")
${UPDATE_JSON:-（stdout 为空）}"
TARGET_VERSION="$(
  printf '%s' "$UPDATE_JSON" \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["latest"])' 2>/dev/null
)" || fail "update check returned no \"latest\"; its own answer was:
$UPDATE_JSON"
[[ -n "$TARGET_VERSION" ]] || fail "could not read the latest version from update check"
echo "    latest release is $TARGET_VERSION; the test copy will start at $OLD_VERSION"

# ------------------------------------------------------------------ install

step "installing to $TEST_APP with bundle id $TEST_BUNDLE_ID"
rm -rf "$TEST_APP"
mkdir -p "$HOME/Applications"
ditto "$BUILT" "$TEST_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_BUNDLE_ID" \
  "$TEST_APP/Contents/Info.plist" >/dev/null
# Inside-out, and ad-hoc: patching Info.plist invalidates the signature the build made.
codesign --force --sign - "$TEST_APP/Contents/Resources/gitpic" 2>/dev/null
codesign --force --sign - "$TEST_APP" 2>/dev/null
codesign --verify --deep --strict "$TEST_APP" || fail "the re-signed test copy does not verify"

step "launching it the way a user does"
open "$TEST_APP"
for _ in $(seq 1 40); do
  TEST_PID="$(pgrep -f "^$HOME/Applications/GitPic.app/Contents/MacOS/GitPic$" | head -1 || true)"
  [[ -n "$TEST_PID" ]] && break
  sleep 0.5
done
[[ -n "$TEST_PID" ]] || fail "the test copy did not start"
echo "    pid $TEST_PID"

# ------------------------------------------------------------- drive the UI

# One osascript per operation, and never an element stored in a variable. Both rules are
# load-bearing: `set frontmost to true` and `set position of window 1` each leave the
# process answering -1719 to every later `window 1`, recoverable only by relaunching.
ax() { osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $TEST_PID) to $1"; }
# Two menu bars: 1 is the (never drawn) main menu, 2 is the status item.
status_menu() { echo 'menu 1 of menu bar item 1 of menu bar 2'; }

step "waiting for the status item to reach the accessibility tree"
# The pid exists a good second before `menu bar 2` does, and asking too early fails with
# -1719 rather than with "not yet" — so this is a wait and not a sleep. Measured: the
# status-item scene registers ~1-3 s after launch on this machine.
MENU=""
for _ in $(seq 1 40); do
  if [[ "$(ax 'get exists menu bar 2' 2>/dev/null)" == "true" ]]; then MENU=yes; break; fi
  sleep 0.5
done
[[ -n "$MENU" ]] || fail "the status item never appeared in the accessibility tree.
      If every osascript call fails, this terminal probably lacks an Accessibility grant:
      系统设置 ▸ 隐私与安全性 ▸ 辅助功能."

step "打开设置"
# The menu has to be opened before its items can be clicked. System Events does not
# reliably fire a closed menu's item action, and when the click is swallowed the
# update sheet never comes up — measured the hard way: this script's first version
# clicked the items directly and failed at "waiting for the update sheet".
ax "click menu bar item 1 of menu bar 2" >/dev/null
sleep 1
ax "click (first menu item of $(status_menu) whose name is \"打开设置\")" >/dev/null
sleep 2

step "检查更新"
# Same rule as 打开设置: open the menu first, then click. The item's title becomes
# 「有新版本 x.y.z…」 once a check has found something, which is why the click matches
# either prefix — the launch-time check may already have flipped it.
ax "click menu bar item 1 of menu bar 2" >/dev/null
sleep 1
ax "click (first menu item of $(status_menu) whose name starts with \"检查更新\" or name starts with \"有新版本\")" >/dev/null

step "waiting for the update sheet"
SHEET=""
for _ in $(seq 1 60); do
  if [[ "$(ax 'get exists sheet 1 of window 1' 2>/dev/null)" == "true" ]]; then SHEET=yes; break; fi
  sleep 1
done
[[ -n "$SHEET" ]] || fail "the update sheet never appeared (is $OLD_VERSION really older than $TARGET_VERSION?)"

step "waiting for the upgrade route to resolve"
# The action row is 「正在确认升级方式…」 until the route is known, and resolving it can cost
# a 20 s `brew list --cask` — so the probe is the row's shape, not a fixed sleep. Three
# buttons means a route was offered (下载并更新 or 立即更新, then 打开发布页 and 稍后); two
# means `.unavailable`, which is a different failure and worth saying so.
ROUTED=""
BUTTONS=""
for _ in $(seq 1 60); do
  BUTTONS="$(ax 'get count of buttons of group 1 of sheet 1 of window 1' 2>/dev/null || true)"
  [[ "$BUTTONS" == "3" ]] && { ROUTED=yes; break; }
  sleep 1
done
if [[ -z "$ROUTED" ]]; then
  [[ "$BUTTONS" == "2" ]] && fail "the sheet offers no upgrade route here (only 打开发布页 and
      稍后). The log line beginning 'update: no in-app upgrade' says which reason."
  fail "the sheet's action row never settled (found $BUTTONS button(s))"
fi

step "下载并更新"
# Positional, because the sheet's own buttons report their AXDescription as 「按钮」 and
# nothing else — measured. Button 1 is the leading prominent action in either route.
ax 'click button 1 of group 1 of sheet 1 of window 1' >/dev/null

step "confirming in the alert"
ALERT=""
for _ in $(seq 1 30); do
  if [[ "$(ax 'get exists sheet 1 of sheet 1 of window 1' 2>/dev/null)" == "true" ]]; then
    ALERT=yes; break
  fi
  sleep 1
done
[[ -n "$ALERT" ]] || fail "the confirmation alert never appeared"
# Alert buttons *do* carry an AXDescription (unlike the sheet's), so the click can be
# checked rather than merely counted: two buttons, 取消 first because they are indexed
# left-to-right as rendered, and the action second.
ALERT_BUTTONS="$(ax 'get count of buttons of sheet 1 of sheet 1 of window 1')"
[[ "$ALERT_BUTTONS" == "2" ]] || fail "expected 2 buttons in the alert, found $ALERT_BUTTONS"
ACTION_LABEL="$(ax 'get description of button 2 of sheet 1 of sheet 1 of window 1')"
[[ "$ACTION_LABEL" != "取消" ]] \
  || fail "button 2 of the alert is 取消 — the buttons are not in the expected order"
# Braced on purpose: bash 3.2, which is what macOS ships, will read the following 」 into
# the variable name and then die under `set -u` with an unbound variable.
echo "    clicking 「${ACTION_LABEL}」"
ax 'click button 2 of sheet 1 of sheet 1 of window 1' >/dev/null

# --------------------------------------------------------------- the assertions

# THE assertion. 0.20.0 got everything above this line right and stopped here.
step "waiting for pid $TEST_PID to exit (this is the check that 0.20.0 failed)"
GONE=""
for _ in $(seq 1 240); do
  if ! kill -0 "$TEST_PID" 2>/dev/null; then GONE=yes; break; fi
  sleep 1
done
if [[ -z "$GONE" ]]; then
  echo "    pid $TEST_PID is still alive; what it is running now:" >&2
  lsof -p "$TEST_PID" 2>/dev/null | awk '$4 == "txt" { print "      " $NF }' | head -3 >&2
  fail "the app did not quit after handing off — the 0.20.0 bug, or a new one wearing its shape"
fi
echo "    exited"

step "waiting for the reopened app"
NEW_PID=""
for _ in $(seq 1 60); do
  NEW_PID="$(pgrep -f "^$HOME/Applications/GitPic.app/Contents/MacOS/GitPic$" | head -1 || true)"
  [[ -n "$NEW_PID" && "$NEW_PID" != "$TEST_PID" ]] && break
  NEW_PID=""
  sleep 1
done
[[ -n "$NEW_PID" ]] || fail "nothing came back — the script's reopen did not produce a running app"
echo "    pid $NEW_PID"

step "asserting what came back"
INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$TEST_APP/Contents/Info.plist")"
[[ "$INSTALLED" == "$TARGET_VERSION" ]] \
  || fail "the bundle on disk is $INSTALLED, expected $TARGET_VERSION"
# Running from the new bundle and not from the renamed-aside backup: that distinction is
# the whole of the downstream damage the failed quit caused, and `pgrep` on the path alone
# cannot see it — a process whose directory was renamed keeps the old inode.
RUNNING_FROM="$(lsof -p "$NEW_PID" 2>/dev/null | awk '$4 == "txt" && /GitPic$/ { print $NF; exit }')"
[[ "$RUNNING_FROM" == "$TEST_APP/Contents/MacOS/GitPic" ]] \
  || fail "the new process is running from $RUNNING_FROM, not $TEST_APP/Contents/MacOS/GitPic"
# Still a menu-bar app. This is the claim the fix makes when it exits without letting
# `windowWillClose` hand the activation policy back: nothing to hand back, because the
# policy dies with the process and `Main.main()` sets .accessory before run().
BACKGROUND="$(osascript -e "tell application \"System Events\" to get background only of (first application process whose unix id is $NEW_PID)")"
[[ "$BACKGROUND" == "true" ]] || fail "the reopened app is not .accessory (background only = $BACKGROUND)"

step "asserting the machine's own GitPic was not touched"
SYSTEM_AFTER="$(system_fingerprint)"
[[ "$SYSTEM_AFTER" == "$SYSTEM_BEFORE" ]] \
  || fail "/Applications/GitPic.app changed: '$SYSTEM_BEFORE' -> '$SYSTEM_AFTER'"

# ------------------------------------------------- the quits the user presses
#
# Everything above drives 检查更新 → 下载并更新, which reaches the quit through
# `Updater.quitForUpdate`. It therefore says nothing at all about the two affordances a user
# actually presses — 「退出 GitPic」 and ⌘Q — and those are the ones that shipped broken in
# 0.20.0 and stayed broken for two releases. They were held by a source grep alone
# (`QuitPathContractTests`), which cannot see whether the menu item is reachable.
#
# ⌘Q is deliberately not driven here: `keystroke` needs the app frontmost, and the comment
# on `ax` above records that `set frontmost to true` poisons the process into answering
# -1719 to every later `window 1`. The menu item and ⌘Q share one selector and one
# `Updater.quitByUser`, so the menu item is the honest half to assert.
#
# A third route neither of those covers gets its own phase at the end: the `terminate:` that
# AppKit synthesises for a Dock-menu Quit and for the Apple Event a logout or a restart sends.
# That one never enters our code at all, so a sheet refused it long after 「退出 GitPic」 was
# fixed — meaning the app blocked the user logging out while an update sheet was up. It is
# driven with `tell application id … to quit`, which is the same event and needs no frontmost
# app; see 「the quit Apple Event mid-install」.

# Whatever is running from the test path, gone, so the next launch is unambiguous.
kill_test_app() {
  pkill -f "^$HOME/Applications/GitPic.app/Contents/MacOS/GitPic$" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "^$HOME/Applications/GitPic.app/Contents/MacOS/GitPic$" >/dev/null || return 0
    sleep 0.5
  done
  fail "could not stop the app running from $TEST_APP"
}

# The same install the run started with. Factored out rather than repeated because each of
# the phases below needs a fresh old bundle: the app under test has to have an update to
# offer, and the phase before it may have consumed one.
install_old_bundle() {
  rm -rf "$TEST_APP"
  rm -rf "$HOME"/Applications/.GitPic-old-* "$HOME"/Applications/.GitPic-update-*
  mkdir -p "$HOME/Applications"
  ditto "$BUILT" "$TEST_APP"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_BUNDLE_ID" \
    "$TEST_APP/Contents/Info.plist" >/dev/null
  codesign --force --sign - "$TEST_APP/Contents/Resources/gitpic" 2>/dev/null
  codesign --force --sign - "$TEST_APP" 2>/dev/null
  codesign --verify --deep --strict "$TEST_APP" \
    || fail "the re-signed test copy does not verify"
}

# Launch, and leave $TEST_PID pointing at it — `ax` reads that global, so every helper below
# addresses whichever copy was launched last.
launch_and_wait() {
  open "$TEST_APP"
  TEST_PID=""
  for _ in $(seq 1 40); do
    TEST_PID="$(pgrep -f "^$HOME/Applications/GitPic.app/Contents/MacOS/GitPic$" | head -1 || true)"
    [[ -n "$TEST_PID" ]] && break
    sleep 0.5
  done
  [[ -n "$TEST_PID" ]] || fail "the test copy did not start"
  echo "    pid $TEST_PID"
  for _ in $(seq 1 40); do
    [[ "$(ax 'get exists menu bar 2' 2>/dev/null)" == "true" ]] && return 0
    sleep 0.5
  done
  fail "the status item never appeared in the accessibility tree"
}

# 打开设置 → 检查更新 → the sheet, with the route resolved. Same click idiom and the same
# waits-not-sleeps as the main flow above; see those comments for why each one is a poll.
open_update_sheet() {
  ax "click menu bar item 1 of menu bar 2" >/dev/null
  sleep 1
  ax "click (first menu item of $(status_menu) whose name is \"打开设置\")" >/dev/null
  sleep 2
  ax "click menu bar item 1 of menu bar 2" >/dev/null
  sleep 1
  ax "click (first menu item of $(status_menu) whose name starts with \"检查更新\" or name starts with \"有新版本\")" >/dev/null
  for _ in $(seq 1 60); do
    [[ "$(ax 'get exists sheet 1 of window 1' 2>/dev/null)" == "true" ]] && break
    sleep 1
  done
  [[ "$(ax 'get exists sheet 1 of window 1' 2>/dev/null)" == "true" ]] \
    || fail "the update sheet never appeared"
  for _ in $(seq 1 60); do
    [[ "$(ax 'get count of buttons of group 1 of sheet 1 of window 1' 2>/dev/null || true)" == "3" ]] \
      && return 0
    sleep 1
  done
  fail "the sheet's action row never settled"
}

quit_via_status_menu() {
  ax "click menu bar item 1 of menu bar 2" >/dev/null
  sleep 1
  ax "click (first menu item of $(status_menu) whose name is \"退出 GitPic\")" >/dev/null
}

# $1 pid, $2 what it was asked to do, $3 seconds to allow.
expect_gone() {
  local pid="$1" what="$2" limit="$3"
  for _ in $(seq 1 "$limit"); do
    kill -0 "$pid" 2>/dev/null || { echo "    exited"; return 0; }
    sleep 1
  done
  echo "    pid $pid is still alive; what it is running now:" >&2
  lsof -p "$pid" 2>/dev/null | awk '$4 == "txt" { print "      " $NF }' | head -3 >&2
  fail "$what"
}

# The per-user temp directory the app writes to. Asked of the system rather than inherited,
# because a GUI process launched by `open` does not get this shell's environment.
USER_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")"
# Both spellings carry a trailing slash, which would make every path below read
# `…/T//gitpic-mount-…`. Harmless to the compare, since one function produces both
# sides of it, but the paths end up in a failure message a person has to read.
USER_TMP="${USER_TMP%/}"
# Compared before and after rather than asserted empty, so unrelated leftovers on this
# machine cannot fail the run — and so a leak here cannot hide among them.
install_debris() {
  {
    hdiutil info 2>/dev/null | grep -o 'gitpic-mount-[0-9A-Fa-f-]*' || true
    ls -d "$USER_TMP"/gitpic-mount-* 2>/dev/null || true
    ls -d "$USER_TMP"/gitpic-update-*.dmg 2>/dev/null || true
    ls -d "$HOME"/Applications/.GitPic-update-* 2>/dev/null || true
  } | sort -u
}

step "退出 GitPic with the update sheet attached (the 0.20.0 repro)"
# No install started: this is exactly the recipe `Updater.quit` documents — open 设置, run
# 检查更新 until the sheet is up, then quit. AppKit refuses `NSApplication.terminate` while a
# sheet is attached, so before the fix this quit did nothing at all, every time.
kill_test_app
install_old_bundle
launch_and_wait
open_update_sheet
QUIT_PID="$TEST_PID"
quit_via_status_menu
expect_gone "$QUIT_PID" \
  "「退出 GitPic」 did nothing with the update sheet attached — the 0.20.0 bug on the path the
      user actually presses, which no unit test can see" 30
# Nothing should have come back: the user asked to leave, not to update.
sleep 2
BACK="$(pgrep -f "^$HOME/Applications/GitPic.app/Contents/MacOS/GitPic$" | head -1 || true)"
[[ -z "$BACK" ]] || fail "a user quit reopened the app (pid $BACK) — only the update path may"

step "退出 GitPic while an update is installing"
# What this covers: `exit(0)` runs no `defer`, so a quit taken between `hdiutil attach` and
# the handoff has to undo the mount, the staging directory and the download itself.
#
# **Honest about the race.** The install is a 5 MB download plus a `ditto` of a small
# bundle, so it can finish in a couple of seconds and the quit may land after the handoff
# instead of inside staging. The absence assertions below hold either way, and the run
# reports which of the two happened rather than claiming the harder one.
kill_test_app
install_old_bundle
# Captured after the reinstall, not before it: `install_old_bundle` clears any
# `.GitPic-update-*` itself, so a snapshot taken earlier would list one that the reinstall
# then removed and read as a leak having been cleaned rather than never made.
DEBRIS_BEFORE="$(install_debris)"
launch_and_wait
open_update_sheet
QUIT_PID="$TEST_PID"
ax 'click button 1 of group 1 of sheet 1 of window 1' >/dev/null
for _ in $(seq 1 30); do
  [[ "$(ax 'get exists sheet 1 of sheet 1 of window 1' 2>/dev/null)" == "true" ]] && break
  sleep 1
done
ax 'click button 2 of sheet 1 of sheet 1 of window 1' >/dev/null
# The progress row replaces the button row as soon as the first bytes arrive, which is the
# earliest observable moment the install is genuinely in flight.
INSTALLING=""
for _ in $(seq 1 60); do
  if [[ "$(ax 'get count of buttons of group 1 of sheet 1 of window 1' 2>/dev/null || true)" != "3" ]]; then
    INSTALLING=yes; break
  fi
  sleep 0.2
done
[[ -n "$INSTALLING" ]] || fail "the install never started (the sheet still shows its buttons)"
quit_via_status_menu
expect_gone "$QUIT_PID" "「退出 GitPic」 did nothing while an update was installing" 60

# Whether the quit landed inside the install or lost the race to it, said plainly.
sleep 3
AFTER_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$TEST_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
if [[ "$AFTER_VERSION" == "$OLD_VERSION" ]]; then
  echo "    the quit landed inside the install; the bundle is still $OLD_VERSION"
else
  echo "    NOTE: the install completed before the quit landed (bundle is $AFTER_VERSION)," >&2
  echo "    so this run exercised the handoff rather than the mid-install undo. The" >&2
  echo "    absence checks below still apply." >&2
fi

step "asserting the interrupted install left nothing behind"
# `.GitPic-old-*` is deliberately excluded: a completed install keeps one as rollback
# material and removing it is the next launch's job, not this one's.
DEBRIS_AFTER="$(install_debris)"
if [[ "$DEBRIS_AFTER" != "$DEBRIS_BEFORE" ]]; then
  echo "    before:" >&2; echo "${DEBRIS_BEFORE:-      (none)}" | sed 's/^/      /' >&2
  echo "    after:"  >&2; echo "${DEBRIS_AFTER:-      (none)}"  | sed 's/^/      /' >&2
  fail "a quit during an install left an attached image, a staging directory or the download
      behind. An attached image is invisible in Finder (-nobrowse) and survives until
      reboot; the launch sweep only reclaims these after 24 h."
fi
echo "    no mount, no staging directory, no download left"

step "the quit Apple Event mid-install (what a logout sends)"
# The route the two phases above cannot reach. They drive 「退出 GitPic」, which is *our* code
# and never calls `terminate:` at all. A Dock-menu Quit and the Apple Event a logout or a
# restart sends are synthesised by AppKit and do arrive as `terminate:`, which a sheet refuses
# — so with the update sheet up the app used to block logging out, Force Quit the only way
# past it. Two changes close it and neither is correct alone: `allowTerminationWithSheets`
# clears the refusal, and `applicationShouldTerminate` sends what gets through to the one quit
# path so the staging undo still runs. `QuitPathContractTests` holds that both exist; only
# this phase can say whether AppKit agrees.
#
# `tell application id … to quit` rather than clicking the Dock icon's menu: it is the same
# `kAEQuitApplication` event a logout sends, it needs no accessibility tree, and it does not
# have to make the app frontmost — which is what poisons the AX tree for the rest of the run.
kill_test_app
install_old_bundle
DEBRIS_BEFORE="$(install_debris)"
launch_and_wait
open_update_sheet
QUIT_PID="$TEST_PID"
ax 'click button 1 of group 1 of sheet 1 of window 1' >/dev/null
for _ in $(seq 1 30); do
  [[ "$(ax 'get exists sheet 1 of sheet 1 of window 1' 2>/dev/null)" == "true" ]] && break
  sleep 1
done
ax 'click button 2 of sheet 1 of sheet 1 of window 1' >/dev/null
INSTALLING=""
for _ in $(seq 1 60); do
  if [[ "$(ax 'get count of buttons of group 1 of sheet 1 of window 1' 2>/dev/null || true)" != "3" ]]; then
    INSTALLING=yes; break
  fi
  sleep 0.2
done
[[ -n "$INSTALLING" ]] || fail "the install never started (the sheet still shows its buttons)"
# `|| true` because a refused quit is reported as an AppleScript error, and that is a result
# to assert on rather than a reason to abort the run with `set -e`. The explicit timeout keeps
# a refusal fast: the default Apple Event timeout is two minutes, and waiting it out would say
# nothing that ten seconds does not.
QUIT_ERR="$(osascript \
  -e 'with timeout of 10 seconds' \
  -e "tell application id \"$TEST_BUNDLE_ID\" to quit" \
  -e 'end timeout' 2>&1 || true)"
[[ -z "$QUIT_ERR" ]] || echo "    (the event returned: $QUIT_ERR)"
expect_gone "$QUIT_PID" \
  "the quit Apple Event did nothing while the update sheet was attached. This is the route a
      logout takes, so the app would also have blocked logging out — AppKit refuses
      \`terminate:\` while a sheet is up unless preventsApplicationTerminationWhenModal is
      cleared on it (Updater.allowTerminationWithSheets)" 60

step "asserting the Apple Event quit also left nothing behind"
# The half that `applicationShouldTerminate` is responsible for. If it returned .terminateNow
# instead of routing into the one quit path, the process would be gone — the check above would
# pass — and AppKit's own teardown would have run neither the login-child reap nor
# `SelfUpdate.undoInFlightWork()`, leaving exactly what 0.20.1 shipped to stop leaking. So the
# absence check is not a duplicate of the one above; it is the only thing that separates
# "quit" from "quit correctly".
sleep 3
DEBRIS_AFTER="$(install_debris)"
if [[ "$DEBRIS_AFTER" != "$DEBRIS_BEFORE" ]]; then
  echo "    before:" >&2; echo "${DEBRIS_BEFORE:-      (none)}" | sed 's/^/      /' >&2
  echo "    after:"  >&2; echo "${DEBRIS_AFTER:-      (none)}"  | sed 's/^/      /' >&2
  fail "the Apple Event quit left an attached image, a staging directory or the download
      behind — AppKit tore the process down without the staging undo, which is what
      applicationShouldTerminate routing into Updater.quitByUser() exists to prevent."
fi
echo "    no mount, no staging directory, no download left"

echo
echo "PASS  $OLD_VERSION -> $TARGET_VERSION"
echo "      pid $TEST_PID exited, pid $NEW_PID is running $INSTALLED from $RUNNING_FROM"
echo "      /Applications/GitPic.app untouched ($SYSTEM_AFTER)"

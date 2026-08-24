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
TEST_PID=""

cleanup() {
  local code=$?
  set +e
  if [[ $RESTORED -eq 0 ]]; then
    RESTORED=1
    step "restoring Cargo.toml/Cargo.lock and the shared release binary"
    cp "$WORK/Cargo.toml.orig" "$ROOT/Cargo.toml"
    cp "$WORK/Cargo.lock.orig" "$ROOT/Cargo.lock"
    # The release binary lives in a CARGO_TARGET_DIR shared with every other worktree
    # (AGENTS.md), so leaving it built at $OLD_VERSION would make the next agent's
    # build-app.sh fail its version guard on a "stale binary" that this script staled.
    ( cd "$ROOT" && cargo build --release >/dev/null 2>&1 ) \
      || echo "    warning: could not rebuild $REAL_VERSION; run 'cargo build --release'" >&2
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
  rm -rf "$WORK"
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
TARGET_VERSION="$(
  "$BUILT/Contents/Resources/gitpic" update check --json 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["latest"])'
)" || fail "gitpic update check failed — no network, or the release feed is unreachable"
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

echo
echo "PASS  $OLD_VERSION -> $TARGET_VERSION"
echo "      pid $TEST_PID exited, pid $NEW_PID is running $INSTALLED from $RUNNING_FROM"
echo "      /Applications/GitPic.app untouched ($SYSTEM_AFTER)"

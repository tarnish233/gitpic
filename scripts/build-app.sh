#!/usr/bin/env bash
# Build GitPic.app: compile the Swift app, embed the gitpic CLI, sign, assemble.
#
# The embedded CLI is not a convenience. A Finder-launched .app gets
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, so a bare `gitpic` lookup fails; shipping
# the binary inside the bundle and calling it by absolute path is what makes the
# GUI work at all. It is the only tool the app needs: the CLI holds its own
# credential, so there is nothing else to find on PATH at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/apps/GitPic"
# Still not $ROOT/dist. The release workflow stages the CLI archives there and
# asserts the exact set before publishing; keeping the bundle out of that
# directory means a local build can never be mistaken for a CLI artifact.
OUT="${OUT:-$ROOT/dist-app}"
APP="$OUT/GitPic.app"
# The app and the CLI share one version, and Cargo.toml is where it lives.
#
# Read only out of the [package] section: a `version = ` line appears under
# plenty of `[dependencies.*]` tables too, and a whole-file grep would pick up
# whichever came first. Same parse as check_manifests.py's cargo_version().
APP_VERSION="${APP_VERSION:-$(
  awk '/^\[package\]/ { inpkg = 1; next }
       /^\[/          { inpkg = 0 }
       inpkg && /^version[[:space:]]*=/ {
         gsub(/^version[[:space:]]*=[[:space:]]*"|"[[:space:]]*$/, ""); print; exit
       }' "$ROOT/Cargo.toml"
)}"
[[ -n "$APP_VERSION" ]] || { echo "error: no [package] version in Cargo.toml" >&2; exit 1; }

echo "==> building Swift app (release)"
( cd "$PKG" && swift build -c release )
BIN="$(cd "$PKG" && swift build -c release --show-bin-path)/GitPicApp"
[[ -x "$BIN" ]] || { echo "error: $BIN missing" >&2; exit 1; }

echo "==> resolving the gitpic binary to embed"
GITPIC_BIN="${GITPIC_BIN:-}"
if [[ -z "$GITPIC_BIN" ]]; then
  if [[ -x "$ROOT/target/release/gitpic" ]]; then
    GITPIC_BIN="$ROOT/target/release/gitpic"
  else
    echo "    no target/release/gitpic; building it"
    ( cd "$ROOT" && cargo build --release --locked )
    GITPIC_BIN="$ROOT/target/release/gitpic"
  fi
fi
[[ -x "$GITPIC_BIN" ]] || { echo "error: gitpic binary not found at $GITPIC_BIN" >&2; exit 1; }
CLI_VERSION="$("$GITPIC_BIN" --version | awk '{print $2}')"
# The one runtime check that the merged version is real rather than asserted.
#
# APP_VERSION comes from Cargo.toml; CLI_VERSION comes from asking the binary
# that is about to be copied into the bundle. Those two agreeing is the whole
# claim of a unified release, and nothing else verifies it — a stale
# target/release/gitpic (or a GITPIC_BIN pointing somewhere else) would otherwise
# ship silently inside an app stamped with a version it does not contain.
if [[ "$CLI_VERSION" != "$APP_VERSION" ]]; then
  echo "error: embedded gitpic is $CLI_VERSION but this build is $APP_VERSION" >&2
  echo "       $GITPIC_BIN is stale — rebuild it (cargo build --release) or set GITPIC_BIN" >&2
  exit 1
fi
echo "    embedding gitpic $CLI_VERSION from $GITPIC_BIN"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitPic"
cp "$GITPIC_BIN" "$APP/Contents/Resources/gitpic"
chmod +x "$APP/Contents/Resources/gitpic"

echo "==> compiling AppIcon.icon (Icon Composer)"
ICON_DOC="$PKG/AppIcon.icon"
[[ -d "$ICON_DOC" ]] || { echo "error: $ICON_DOC missing" >&2; exit 1; }
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
# 14.0 matches LSMinimumSystemVersion: actool emits the Tahoe glass
# appearances in Assets.car and flattened bitmaps in the icns for older macOS.
xcrun actool --compile "$ICON_TMP" \
  --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 14.0 --standalone-icon-behavior all \
  --output-partial-info-plist "$ICON_TMP/p.plist" \
  "$ICON_DOC"
[[ -f "$ICON_TMP/AppIcon.icns" && -f "$ICON_TMP/Assets.car" ]] || {
  echo "error: actool did not emit AppIcon.icns / Assets.car" >&2
  exit 1
}
cp "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ICON_TMP/Assets.car" "$APP/Contents/Resources/Assets.car"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>GitPic</string>
  <key>CFBundleIdentifier</key><string>dev.gitpic.app</string>
  <key>CFBundleName</key><string>GitPic</string>
  <key>CFBundleDisplayName</key><string>GitPic</string>
  <!-- The UI is Simplified Chinese throughout, and AppKit has to be told so.
       AppKit localizes its *own* strings — the Edit menu's Undo/Redo titles, the
       open panel's buttons and sidebar — against the localizations the bundle
       declares, and a bundle that declares none is treated as English. That is why
       a Chinese app came up with \`Cancel\` / \`Open\` and an English \`Undo\`
       sitting next to 剪切/拷贝/粘贴.
       zh-Hans alone, not zh-Hans + en: there is no English UI here to fall back
       to, so someone running an English system is better served by one consistent
       language than by Chinese panes with English buttons. -->
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array><string>zh-Hans</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>GitPicEmbeddedCLIVersion</key><string>$CLI_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu-bar app: no Dock icon. Also means the app is never active, which is why
       the open panel has to borrow .regular for its lifetime — see AppActivationPolicy. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The Finder right-click entry. Read by Launch Services from this plist and
       routed to \`NSApp.servicesProvider\` — see ServiceProvider.swift for why a
       Service rather than an app extension or a FinderSync plug-in.

       **NSRequiredContext is what makes the item appear at all.** Without it the service
       registers, caches, and can even be invoked by name through NSPerformService — and
       is still absent from Finder's context menu. Established by declaring five variants
       in one bundle and looking at the menu: the only one missing was the one with this
       key removed. It is not optional and it is not a restriction you can skip.

       NSSendFileTypes rather than NSSendTypes: it limits the item to files whose type
       conforms to public.image, which is the whole ask — an entry that also showed up on
       folders and .txt files would be worse than none. That combination was verified in
       the same sweep, so the image filter costs nothing here. It is still not a guarantee
       about what reaches the pasteboard, so ImageFilter checks again.

       NSMessage is the selector name minus its \`:userData:error:\` tail, so it must
       stay equal to \`FinderServiceStatus.message\`; the app logs a warning at launch if
       the two have drifted. NSPortName matches CFBundleName above (the sweep showed it is
       harmless either way; Safari and Xcode both set it).

       **The title below is the authority for the 设置 switch, not just a label.** \`pbs\`
       files a service's on/off state under a key built from the bundle id, this title,
       and NSMessage, and \`FinderService.menuItemTitle\` reads this very entry back to
       build it — so the switch cannot disagree with the menu. What renaming it *does*
       break is existing state: the old key is orphaned, and everyone who had turned the
       item off gets it back on. Rename only when that is acceptable. -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict><key>default</key><string>GitPic 上传至图床</string></dict>
      <key>NSMessage</key><string>uploadImagesToGitPic</string>
      <key>NSPortName</key><string>GitPic</string>
      <key>NSRequiredContext</key>
      <dict><key>NSTextContent</key><string>FilePath</string></dict>
      <key>NSSendFileTypes</key>
      <array><string>public.image</string></array>
      <key>NSServiceDescription</key>
      <string>把选中的图片上传到 GitPic 图床，并把链接放进剪贴板。</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> signing"
# Ad-hoc by default, and that is a measured choice rather than laziness.
#
# This machine has two "Apple Development" identities; `security find-identity -v`
# annotates one CSSMERR_TP_CERT_REVOKED and lists the other as valid. Signing with
# the seemingly-valid one still produces a binary the kernel SIGKILLs on exec
# (exit 137), and `spctl -a -t exec` reports CSSMERR_TP_CERT_REVOKED for the
# bundle — the identity is revoked in effect. Ad-hoc signing runs fine locally
# because a locally-built bundle carries no com.apple.quarantine attribute.
#
# Consequence to keep in mind: an ad-hoc signature changes on every rebuild, so
# any TCC grant (screen recording, accessibility) would have to be re-approved
# each build. GitPic needs none of those, so nothing is lost here.
#
# Override with GITPIC_SIGN_ID=<sha1|name> once a real Developer ID exists; that
# is also the point at which notarised distribution becomes possible.
SIGN_ID="${GITPIC_SIGN_ID:--}"

# Inside-out: the embedded CLI first, then the bundle.
codesign --force --sign "$SIGN_ID" "$APP/Contents/Resources/gitpic"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

# Report, do not fail: an unnotarised app is expected to fail assessment, and it
# still launches locally. This line is here so the limitation stays visible.
if ! spctl -a -t exec "$APP" >/dev/null 2>&1; then
  echo "    note: fails Gatekeeper assessment (expected without a Developer ID)."
  echo "          Runs locally; would be blocked if downloaded by someone else."
fi

echo
echo "built  $APP"
echo "app    $APP_VERSION"
echo "cli    $CLI_VERSION  (embedded)"
echo "signed $SIGN_ID"
echo
echo "run it the way users will (Finder launch, minimal PATH):"
echo "  open \"$APP\""

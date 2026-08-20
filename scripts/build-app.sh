#!/usr/bin/env bash
# Build GitPic.app: compile the Swift app, embed the gitpic CLI, sign, assemble.
#
# The embedded CLI is not a convenience. A Finder-launched .app gets
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, so a bare `gitpic` lookup fails; shipping
# the binary inside the bundle and calling it by absolute path is what makes the
# GUI work at all. (`gh` is found separately at runtime — see ToolDiscovery.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/apps/GitPic"
# Deliberately NOT $ROOT/dist: the CLI release job asserts `ls gitpic-*.sha256`
# counts exactly 4 there, so an app artifact landing beside it fails the release.
OUT="${OUT:-$ROOT/dist-app}"
APP="$OUT/GitPic.app"
# Single source of truth for the app version, deliberately separate from
# Cargo.toml: the app and the CLI version independently. check_manifests.py welds
# the Cargo version to the plugin manifests, so the app must never appear there.
APP_VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "$PKG/VERSION")}"

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
echo "    embedding gitpic $CLI_VERSION from $GITPIC_BIN"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitPic"
cp "$GITPIC_BIN" "$APP/Contents/Resources/gitpic"
chmod +x "$APP/Contents/Resources/gitpic"

echo "==> building the app icon"
ICON_SOURCE="$PKG/Resources/AppIcon-1024.png"
[[ -f "$ICON_SOURCE" ]] || { echo "error: $ICON_SOURCE missing" >&2; exit 1; }
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/GitPic.iconset"
mkdir -p "$ICONSET"
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  read -r side name <<< "$spec"
  sips --resampleHeightWidth "$side" "$side" "$ICON_SOURCE" \
    --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/GitPic.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>GitPic</string>
  <key>CFBundleIdentifier</key><string>dev.gitpic.app</string>
  <key>CFBundleName</key><string>GitPic</string>
  <key>CFBundleDisplayName</key><string>GitPic</string>
  <key>CFBundleIconFile</key><string>GitPic.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>GitPicEmbeddedCLIVersion</key><string>$CLI_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu-bar app: no Dock icon. Also means the app is never active, which is
       why the notch drop view returns true from acceptsFirstMouse. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
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

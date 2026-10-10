#!/usr/bin/env bash
# build-meet42.sh — release build of meet42 as a small app bundle (meet42.app, the CLI is its executable), signed
# with a persistent Developer ID, the Hardened Runtime and meet42's own identifier and entitlements.
#
# Why this matters: meet42 is a plain command-line binary (no .app bundle) that needs macOS Calendar,
# Microphone, Speech Recognition and Screen Recording access. macOS reads the permission-prompt wording from
# the binary's embedded __TEXT,__info_plist section, and keys each grant to its code-signing identity. So a
# shippable meet42:
#   1. embeds Resources/meet42-Info.plist at link time (-sectcreate),
#   2. is signed with a PERSISTENT Developer ID (not the ad-hoc signature `swift build` applies, whose hash
#      changes on every build and makes macOS forget the user's grants),
#   3. uses the identifier com.work42.meet42, so prompts and grants belong to "meet42", and
#   4. carries Resources/meet42.entitlements (microphone + calendar): under the Hardened Runtime, which
#      notarization requires, macOS denies both without a prompt unless the entitlement is present.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/build-meet42.sh [--configuration release]
# Prints the path of the built meet42.app as its last line. Without DEVELOPER_ID it signs ad-hoc.
set -euo pipefail

CONFIG="release"
if [[ "${1:-}" == "--configuration" && -n "${2:-}" ]]; then CONFIG="$2"; fi

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$PKG_DIR/Resources/meet42-Info.plist"
ENTITLEMENTS="$PKG_DIR/Resources/meet42.entitlements"
IDENTIFIER="com.work42.meet42"

cd "$PKG_DIR"

echo "==> swift build (-c $CONFIG)" >&2
swift build -c "$CONFIG" --product meet42 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" >&2

BIN="$(swift build -c "$CONFIG" --product meet42 --show-bin-path)/meet42"
echo "==> built $BIN" >&2

# Wrap the binary in meet42.app: macOS shows permission prompts (notably Screen & System Audio) reliably
# only for an app bundle. The app has no window and no Dock icon (LSUIElement); the CLI is its executable.
APP="$PKG_DIR/.build/bundle/meet42.app"
VERSION="$(sed -n 's/^let meet42Version = "\(.*\)"$/\1/p' "$PKG_DIR/Sources/meet42/main.swift")"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/meet42"
cp "$PLIST" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
  -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
echo "==> bundled $APP (version $VERSION)" >&2

if [[ -z "${DEVELOPER_ID:-}" ]]; then
  echo "WARNING: DEVELOPER_ID not set — signing ad-hoc." >&2
  echo "         macOS permission grants will NOT persist across rebuilds." >&2
  codesign --force --sign - --identifier "$IDENTIFIER" "$APP" >&2
  echo "$APP"
  exit 0
fi

echo "==> codesign ($IDENTIFIER, Hardened Runtime, entitlements)" >&2
codesign --force --options runtime --timestamp \
  --identifier "$IDENTIFIER" --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" "$APP" >&2
codesign -dv "$APP" 2>&1 | sed 's/^/    /' >&2
echo "$APP"

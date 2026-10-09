#!/usr/bin/env bash
# build-meet42.sh — release build of the meet42 CLI with its embedded Info.plist, signed with a persistent
# Developer ID, the Hardened Runtime and meet42's own identifier and entitlements.
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
# Prints the path of the built binary as its last line. Without DEVELOPER_ID it leaves the ad-hoc signature.
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

if [[ -z "${DEVELOPER_ID:-}" ]]; then
  echo "WARNING: DEVELOPER_ID not set — leaving the ad-hoc signature in place." >&2
  echo "         macOS permission grants will NOT persist across rebuilds." >&2
  echo "$BIN"
  exit 0
fi

echo "==> codesign ($IDENTIFIER, Hardened Runtime, entitlements)" >&2
codesign --force --options runtime --timestamp \
  --identifier "$IDENTIFIER" --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" "$BIN" >&2
codesign -dv "$BIN" 2>&1 | sed 's/^/    /' >&2
echo "$BIN"

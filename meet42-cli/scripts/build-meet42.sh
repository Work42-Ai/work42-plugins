#!/usr/bin/env bash
# build-meet42.sh — release build of the standalone meet42 CLI with its own
# embedded Info.plist + persistent Developer-ID signature.
# (meet42-plugin-conversion, M1/s7.)
#
# Why this script exists: meet42 is a plain CLI binary (no .app bundle), but it
# needs TCC access to Calendar / Microphone / Screen Recording / Speech. TCC
# reads usage-description strings from the binary's embedded `__TEXT
# __info_plist` section, and keys the grant to the binary's code-sign identity.
# So a shippable meet42 must:
#   1. embed meet42-Info.plist via -sectcreate at link time, and
#   2. be signed with a PERSISTENT Developer ID (NOT the ad-hoc signature
#      `swift build` applies) — otherwise every rebuild gets a new cdhash and
#      macOS resets the user's TCC grant.
#
# ⚠️ This cannot be exercised by `swift build` / CI without signing assets. It
# documents + automates the real release path; run it on a machine with the
# Developer ID identity in its keychain. The `meet42` executable product it
# signs is added in s9 — until then this builds Meet42Kit/Meet42CalendarSync.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#     scripts/build-meet42.sh [--configuration release]
set -euo pipefail

CONFIG="release"
if [[ "${1:-}" == "--configuration" && -n "${2:-}" ]]; then CONFIG="$2"; fi

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$PKG_DIR/Resources/meet42-Info.plist"

cd "$PKG_DIR"

echo "==> swift build (-c $CONFIG)"
# Embed the Info.plist into the linked binary's __TEXT,__info_plist section so
# TCC can read the usage descriptions for a bundle-less CLI.
swift build -c "$CONFIG" --product meet42 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"

BIN="$(swift build -c "$CONFIG" --product meet42 --show-bin-path)/meet42"
echo "==> built $BIN"

if [[ -z "${DEVELOPER_ID:-}" ]]; then
  echo "WARNING: DEVELOPER_ID not set — leaving the ad-hoc signature in place." >&2
  echo "         TCC grants will NOT persist across rebuilds. Set DEVELOPER_ID" >&2
  echo "         to a 'Developer ID Application: …' identity for a shippable build." >&2
  exit 0
fi

echo "==> codesign with persistent Developer ID (hardened runtime)"
codesign --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID" "$BIN"
codesign -dv "$BIN" 2>&1 | sed 's/^/    /'
echo "==> done"

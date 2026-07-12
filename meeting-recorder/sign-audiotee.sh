#!/usr/bin/env bash
# sign-audiotee.sh — re-apply the STABLE self-signed identity to the audiotee
# binary after a rebuild. Run this after every `swift build`.
#
# Why: an ad-hoc binary's TCC grant (Microphone + Screen & System Audio
# Recording) is keyed to its cdhash, which changes on every build — so the
# grant evaporates and macOS silently denies capture. Signing with a fixed
# self-signed cert gives a stable "designated requirement" (identifier + cert
# leaf hash), so the TCC grant persists across rebuilds and into launchd.
#
# No hardened runtime on purpose: that would additionally require the mic
# entitlement. Plain signing lets TCC alone govern access.
#
# Setup (done once, by setup.sh) created the cert + dedicated keychain under
# $SIGNDIR and wrote the keychain password to $SIGNDIR/kc-pass (chmod 600, NOT
# committed). We read it from there so no secret lives in this (public) script.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SIGNDIR="$HOME/.local/state/meeting-recorder/signing"
KC="$SIGNDIR/audioteemic-signing.keychain-db"
KCPASS_FILE="$SIGNDIR/kc-pass"
CN="audioteemic-signing"
ID="com.euf.audioteemic"
BIN="${1:-$HOME/src/audiotee/.build/release/audiotee}"

[[ -f "$KC" ]]         || { echo "signing keychain missing ($KC) — run setup.sh first"; exit 1; }
[[ -f "$KCPASS_FILE" ]]|| { echo "keychain password file missing ($KCPASS_FILE) — run setup.sh first"; exit 1; }
[[ -x "$BIN" ]]        || { echo "binary not found: $BIN"; exit 1; }
KCPASS="$(cat "$KCPASS_FILE")"

security unlock-keychain -p "$KCPASS" "$KC"
codesign --force --keychain "$KC" --sign "$CN" --identifier "$ID" "$BIN"

echo "signed: $BIN"
codesign -d -r- "$BIN" 2>&1 | grep "designated =>"

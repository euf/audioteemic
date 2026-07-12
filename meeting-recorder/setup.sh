#!/usr/bin/env bash
# setup.sh — bootstrap the meeting recorder on a fresh Mac (macOS 14.2+).
#
# Idempotent: builds audiotee, creates a STABLE self-signed signing identity
# (so TCC grants survive rebuilds), signs + installs the binary, installs the
# hotkey helper and the launchd agent. Prints the few steps macOS won't let a
# script do (permissions, hotkey, calendar config).
#
#   bash meeting-recorder/setup.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

BUNDLE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$BUNDLE/.." && pwd)"                 # audiotee repo root (has Package.swift)
STATE="$HOME/.local/state/meeting-recorder"
SIGNDIR="$STATE/signing"
BIN_DIR="$HOME/.local/bin"
LABEL="com.eugene.zoom-recorder"                 # must match record-meeting.sh / meeting-toggle
KC="$SIGNDIR/audioteemic-signing.keychain-db"
CN="audioteemic-signing"; ID="com.euf.audioteemic"
mkdir -p "$STATE" "$SIGNDIR" "$BIN_DIR"; chmod 700 "$SIGNDIR"
step() { printf '\n▶ %s\n' "$1"; }

step "Checking deps…"
command -v swift  >/dev/null || { echo "✗ need Swift (install Xcode / Command Line Tools)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "✗ need ffmpeg (brew install ffmpeg)"; exit 1; }
command -v terminal-notifier >/dev/null || echo "  (optional: brew install terminal-notifier for notifications)"

step "Building audiotee (release)…"
( cd "$REPO" && swift build -c release )
BUILT="$REPO/.build/release/audiotee"
[[ -x "$BUILT" ]] || { echo "✗ build produced no binary at $BUILT"; exit 1; }

if [[ -f "$KC" && -f "$SIGNDIR/kc-pass" ]]; then
  step "Signing identity already present — skipping creation."
else
  step "Creating stable self-signed code-signing identity ($ID)…"
  PASS="$(openssl rand -hex 16)"; printf '%s' "$PASS" > "$SIGNDIR/kc-pass"; chmod 600 "$SIGNDIR/kc-pass"
  ( cd "$SIGNDIR"
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
      -subj "/CN=$CN" -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
    # -legacy: Apple's Security importer can't read OpenSSL-3 default PKCS#12 MAC/cipher.
    openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PASS" -name "$CN" 2>/dev/null
    rm -f key.pem cert.pem )
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p "$PASS" "$KC"
  security set-keychain-settings "$KC"                       # no auto-lock
  security unlock-keychain -p "$PASS" "$KC"
  EXIST="$(security list-keychains -d user | sed 's/[",]//g' | xargs)"
  security list-keychains -d user -s "$KC" $EXIST            # add to search list, keep others
  security import "$SIGNDIR/id.p12" -k "$KC" -P "$PASS" -A -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
  echo "  identity created."
fi

step "Signing + installing binary → $BIN_DIR/audiotee…"
bash "$BUNDLE/sign-audiotee.sh" "$BUILT" >/dev/null
cp "$BUILT" "$BIN_DIR/audiotee"
xattr -c "$BIN_DIR/audiotee" 2>/dev/null || true            # a fresh copy is killed on exec otherwise
bash "$BUNDLE/sign-audiotee.sh" "$BIN_DIR/audiotee" >/dev/null   # re-sign IN PLACE
"$BIN_DIR/audiotee" --list-devices >/dev/null && echo "  binary runs ✓"

step "Installing hotkey helper → $BIN_DIR/meeting-toggle…"
install -m755 "$BUNDLE/meeting-toggle" "$BIN_DIR/meeting-toggle"

step "Installing launchd agent ($LABEL)…"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
sed "s#__WATCH_SH__#$BUNDLE/zoom-meeting-watch.sh#; s#__STATE__#$STATE#g" \
    "$BUNDLE/com.eugene.zoom-recorder.plist.template" > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST" && echo "  loaded ✓"

cat <<EOF

✅ Installed. Files live under: $BIN_DIR (binaries), $STATE (state+signing), $PLIST (agent).

Remaining MANUAL steps (macOS blocks scripts from doing these):

1. PERMISSIONS — System Settings → Privacy & Security, grant BOTH, then fully
   quit + reopen the granting app:
     • Microphone
     • Screen & System Audio Recording   (the system-audio tap)
   Interactive runs attribute to the terminal app; the launchd/hotkey path may
   need 'audiotee' itself enabled there. Verify end-to-end:
     bash $BUNDLE/coclock-accept.sh
   (frame_delta=0 = PASS.)

2. HOTKEY ⌃⌥⌘R (for Meet/Teams/browser — launchd only catches desktop Zoom):
   Shortcuts.app → new shortcut → Run Shell Script → exactly:
     "\$HOME/.local/bin/meeting-toggle"
   then assign the ⌃⌥⌘R keyboard shortcut.

3. CALENDAR NAMING (optional) — filenames get the meeting title if you put your
   private ICS URL into:  ~/.config/calendar-sync/ics_url
   Otherwise files are named by date-time only.

After any 'swift build': re-run  bash $BUNDLE/sign-audiotee.sh
EOF

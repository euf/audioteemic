#!/bin/bash
# coclock-accept.sh — acceptance test for the co-clock capture (audiotee --mic).
#
# Records ONE co-clocked stereo clip while YOU play music on the speakers and
# talk a bit, then measures whether the L<->R offset stays flat (= no drift).
#
# Deliberately simple + hang-proof: one background process tracked by PID, a
# fixed recording window, then SIGINT and a forced kill -9 fallback so it can
# never wedge. The audiotee log is always shown so a failure is self-diagnosing.
#
#   bash "$VAULT/scripts/record/coclock-accept.sh" [seconds]   (default 90)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
SECS="${1:-15}"
AUDIOTEE="${MEETING_REC_AUDIOTEE:-$HOME/src/audiotee/.build/release/audiotee}"
STATE="$HOME/.local/state/meeting-recorder/coclock"; mkdir -p "$STATE"
LOG="$STATE/audiotee.log"; CAP="$STATE/capture.f32"
[[ -x "$AUDIOTEE" ]] || { echo "✗ audiotee not found at $AUDIOTEE"; exit 1; }

echo "▶ Recording ${SECS}s. NOW: play music on your SPEAKERS (not headphones) and talk a bit."
echo "  The mic must physically hear the speakers, or drift can't be measured."
echo "  (this window will just sit here while it records — that's normal, not a hang)"
rm -f "$CAP"
"$AUDIOTEE" --mic >"$CAP" 2>"$LOG" &
AT=$!

# Fixed recording window, then a stop that CANNOT hang.
sleep "$SECS"
kill -INT "$AT" 2>/dev/null || true
for _ in $(seq 1 20); do kill -0 "$AT" 2>/dev/null || break; sleep 0.1; done
kill -9 "$AT" 2>/dev/null || true
wait "$AT" 2>/dev/null || true

echo; echo "── audiotee log (tail) ──"; tail -n 12 "$LOG"

bytes=$(stat -f%z "$CAP" 2>/dev/null || echo 0)
frames=$(( bytes / 8 ))
echo; echo "captured $bytes bytes (~$(( frames / 48000 ))s stereo)"
if (( bytes < 100000 )); then
  echo "✗ Almost nothing captured. If the log stops at tap setup, the system-audio"
  echo "  tap is blocked → enable your TERMINAL app in System Settings → Privacy →"
  echo "  Screen & System Audio Recording, then FULLY quit + reopen the terminal."
  exit 1
fi

# ── PRIMARY verdict: frame-lock (definitive; needs no acoustic bleed) ──
read -r FL_DELTA FL_MISMATCH FL_FRAMES FL_CB < <(python3 - "$LOG" <<'PY'
import sys, json
vals = ("0", "0", "0", "0")
for line in open(sys.argv[1]):
    if 'frame-lock summary' not in line:
        continue
    try:
        c = json.loads(line.strip())["data"]["context"]
    except Exception:
        continue
    vals = (c.get("frame_delta", "0"), c.get("mismatch_callbacks", "0"),
            c.get("mic_frames", "0"), c.get("callbacks", "0"))
print(*vals)
PY
)
echo; echo "── frame-lock (PRIMARY drift check) ──"
echo "  callbacks=$FL_CB  frames/stream=$FL_FRAMES  frame_delta=$FL_DELTA  mismatch_callbacks=$FL_MISMATCH"
if [[ "$FL_FRAMES" == "0" ]]; then
  echo "✗ No frame-lock summary in log — capture didn't run. See log above."; exit 1
fi
# Drift = a GROWING frame offset. frame_delta≈0 over the whole run = locked.
# (Old two-process design would show thousands of samples of delta here.)
if [[ "${FL_DELTA#-}" -le 480 && "$FL_MISMATCH" -le 2 ]]; then
  echo "✅ PASS — mic & system stayed sample-locked. No drift. (This is the definitive result.)"
  PASS=1
else
  echo "✗ FAIL — frame counts diverge (delta=$FL_DELTA, mismatch=$FL_MISMATCH) → not locked."
  PASS=0
fi

# Channel levels — informational; flags a silent side without hiding the drift
# verdict above (frame-lock is valid even if a channel is silent).
read -r LRMS RRMS < <(python3 "$DIR/xcorr-drift.py" --rms "$CAP")
echo; echo "  channel levels: L(mic)=$LRMS  R(system)=$RRMS"
python3 -c "import sys; sys.exit(0 if float('$RRMS')>=1e-5 else 1)" \
  || echo "  ⚠ system channel silent → for real capture enable Screen & System Audio Recording (terminal app)."
python3 -c "import sys; sys.exit(0 if float('$LRMS')>=1e-5 else 1)" \
  || echo "  ⚠ mic channel silent → enable Microphone (terminal app)."

# ── SECONDARY: acoustic cross-check (only meaningful with speaker→mic bleed) ──
echo; echo "── acoustic cross-check (optional; needs the mic to hear the speakers) ──"
if (( frames >= 25 * 48000 )); then
  python3 "$DIR/xcorr-drift.py" --raw "$CAP" | tail -n +2 || true
else
  echo "  clip <25s — skipped. frame-lock above is the real verdict."
fi

echo
if [[ "$PASS" == 1 ]]; then
  echo "✅ Co-clock capture validated — ready to wire into record-meeting.sh."; exit 0
fi
exit 1

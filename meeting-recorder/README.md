# meeting-recorder — Fellow-backup Zoom recorder (co-clock, free/OSS)

A macOS meeting recorder used as **insurance** for a Fellow bot: when Fellow fails to
transcribe a call, you have a local stereo recording to re-upload. Free, no cloud, **no
BlackHole** (output routing untouched → AirPods↔speakers auto-switch keeps working).

It is the wrapper ("обвязка") around [`audiotee`](../README.md) — the system-audio tap in
this repo — plus its **`--mic` co-clock mode**, which is the whole point (see below).

## Why co-clock (the core idea)

A meeting has two sides: **you** (microphone) and **them** (system audio). Capturing them
as two independent processes on two hardware clocks makes them drift apart — measured up to
**~4.8 s of L↔R desync over a 72-min call**. `audiotee --mic` puts the built-in mic and the
system tap into **one private aggregate device on one master clock** (mic = master, tap
follows) and delivers both in a single IOProc callback with equal frame counts, so every
output frame pairs `mic[i]` with `system[i]`. Result: interleaved stereo **`[L=mic,
R=system]`**, drift structurally impossible (verified `frame_delta=0` over 89 s).

`ffmpeg` encodes that stream straight to `.m4a`. On stop the file is renamed to the meeting
title (from your calendar) or date-time.

## Quick start (fresh Mac, macOS 14.2+)

```bash
git clone https://github.com/euf/audioteemic ~/src/audiotee
cd ~/src/audiotee                       # (checkout the branch with --mic if not default)
brew install ffmpeg terminal-notifier   # sox NOT needed
bash meeting-recorder/setup.sh          # builds, signs, installs binary + launchd + hotkey
```
Then do the 3 manual steps `setup.sh` prints (permissions, hotkey, optional calendar URL)
and verify:
```bash
bash meeting-recorder/coclock-accept.sh   # expect: frame_delta=0 → PASS
```

## What each file is

| file | role |
|---|---|
| `record-meeting.sh` | core: `start`/`stop`/`toggle`/`manual-toggle`/`status`; runs `audiotee --mic \| ffmpeg → m4a`, renames on stop |
| `zoom-meeting-watch.sh` | launchd worker (every 5 s): desired-state — Zoom meeting **or** manual flag → start/stop |
| `com.eugene.zoom-recorder.plist.template` | launchd agent (paths filled in by `setup.sh`) |
| `meeting-toggle` | hotkey (⌃⌥⌘R) helper; flips the manual flag + kicks the worker (installed to `~/.local/bin`) |
| `sign-audiotee.sh` | re-apply the stable code-signing identity — **run after every `swift build`** |
| `setup.sh` | one-shot bootstrap (build → sign → install → launchd) |
| `calendar-title.py` | resolves the current meeting's title for the filename (optional) |
| `fetch-calendar.py` | ICS fetcher used by `calendar-title.py`; reads the URL from `~/.config/calendar-sync/ics_url` |
| `coclock-accept.sh` + `xcorr-drift.py` | acceptance test: proves no drift (frame-lock) |
| `calls-reconcile.py` | (vault-specific, optional) flags recordings Fellow never transcribed |

## Where things live on the system (nothing scattered)

- **Binaries:** `~/.local/bin/audiotee` (signed), `~/.local/bin/meeting-toggle`
- **State + signing:** `~/.local/state/meeting-recorder/` — pid files, `latest.log`, `capture.m4a` (in-flight), and `signing/` (keychain + cert + `kc-pass`, **local, never committed**)
- **launchd agent:** `~/Library/LaunchAgents/com.eugene.zoom-recorder.plist`
- **Recordings:** `~/Library/Mobile Documents/com~apple~CloudDocs/Meeting Recordings/` (iCloud) or `~/Recordings/meeting-backups/`; override with `MEETING_REC_OUTDIR`
- **Scripts:** this folder (run from the clone), or copied into your own dotfiles/vault
- **Calendar secret:** `~/.config/calendar-sync/ics_url` (private ICS URL, local only)

## Signing & permissions (the fiddly part)

An **ad-hoc** binary's TCC grant is keyed to its content hash → every rebuild drops it.
`setup.sh` creates a **stable self-signed identity** (`com.euf.audioteemic`, in a dedicated
keychain under `signing/`) so the grant survives rebuilds and reaches launchd. Two rules:

- **After every `swift build`, run `sign-audiotee.sh`** (re-applies the identity).
- **Installing = copy + `xattr -c` + re-sign in place.** A freshly `cp`-ed self-signed
  binary is killed on first exec (Gatekeeper/provenance) and silently produces nothing.

Permissions needed: **Microphone** + **Screen & System Audio Recording**. Interactive runs
attribute the tap to the **terminal app**; the launchd/hotkey path attributes to the
**signed binary** — grant both contexts. CLI tools often get no prompt: enable manually.

## Env overrides

`MEETING_REC_OUTDIR`, `MEETING_REC_AUDIOTEE` (binary path), `MEETING_REC_MIC` (input-device
name substring), `MEETING_REC_ZOOM_PROC` (meeting process name, default `CptHost`),
`MEETING_REC_FETCHCAL` (path to fetch-calendar.py).

## Notes / limits

- File completes on **graceful stop** (worker/hotkey always SIGINTs). A hard crash mid-call
  loses it (ffmpeg buffers audio-only mp4). Accepted for insurance.
- On **speakers**, the mic also hears the far side (acoustic bleed) → L = you + faint echo.
  Fine for a transcript; since the channels are co-clocked, it can be removed offline later
  (echo cancellation using R as reference) — not done in capture (recording stays raw).
- **Only desktop Zoom** is auto-detected; Meet/Teams/browser → the ⌃⌥⌘R hotkey.
- The `com.eugene.*` label is just a launchd label; rename in the plist template,
  `record-meeting.sh`, and `meeting-toggle` if you like (keep all three in sync).

# AudioTee — co-clocked mic + system audio (euf fork)

A fork of **[makeusabrew/audiotee](https://github.com/makeusabrew/audiotee)** that adds
**co-clocked microphone capture** alongside the system-audio tap, so you can record both
sides of a call as one drift-free stereo stream.

Upstream AudioTee captures macOS **system audio** via a Core Audio process tap and streams
raw PCM to `stdout` (metadata/logs to `stderr`). This fork keeps all of that and adds the
one thing it couldn't do: capture your **microphone at the same time, on the same clock**.

## What this fork adds

- **`--mic`** — include the built-in microphone as a sub-device of the tap's private
  aggregate device (mic = clock master, tap drift-follows) and emit interleaved stereo
  **`[L = mic, R = system]`**. Because both streams are delivered in one IOProc callback on
  one clock, they stay sample-locked — no cross-recorder drift.
- **`--input-name <substr>`** — pick a specific input device (default: the built-in mic).
- **`--list-devices`** — list input devices with their Core Audio UIDs.
- **[`meeting-recorder/`](meeting-recorder/)** — a complete, reproducible Fellow-backup
  Zoom recorder built on `--mic` (launchd trigger, ⌃⌥⌘R hotkey, stable code-signing,
  one-shot `setup.sh`). Start there to stand the whole thing up on a fresh Mac.

## Why co-clock matters

Recording mic and system as two separate processes means two independent hardware clocks.
They drift: measured up to **~4.8 s of L↔R desync over a 72-minute call**, which ruins any
attempt to line the two sides up (or to cancel echo later). One aggregate device on one
master clock makes drift structurally impossible — verified `frame_delta = 0` over 89 s
(both channels deliver identical frame counts every callback).

This directly answers upstream **[issue #8](https://github.com/makeusabrew/audiotee/issues/8)**
("Allow input device recording"). The `--mic` changes are isolated to `Sources/` and could
be cherry-picked into an upstream PR.

## Build

```bash
swift build -c release
# → .build/release/audiotee
```
macOS 14.2+ (Core Audio taps). First run prompts for Screen & System Audio Recording (and,
with `--mic`, Microphone).

## Usage

```bash
# system audio only (upstream behaviour)
audiotee > system.pcm

# mic + system, co-clocked, as stereo f32le @48k
audiotee --mic > both.f32
audiotee --mic | ffmpeg -f f32le -ar 48000 -ac 2 -i pipe:0 -c:a aac out.m4a

# split the channels afterwards
ffmpeg -i out.m4a -map_channel 0.0.0 you.wav -map_channel 0.0.1 others.wav
```

For the full upstream API (process include/exclude, sample-rate conversion, mute behaviour,
the structured stdout/stderr protocol), see the
**[upstream README](https://github.com/makeusabrew/audiotee#readme)** — this fork does not
change any of it.

## Credit & license

All the hard Core Audio work is [@makeusabrew](https://github.com/makeusabrew)'s. This fork
only adds the mic co-clock path and a personal recorder around it, and follows
[upstream](https://github.com/makeusabrew/audiotee)'s license.

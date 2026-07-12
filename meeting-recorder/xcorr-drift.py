#!/usr/bin/env python3
"""Measure the L<->R time offset of a stereo recording along its length.

Purpose: verify the co-clock capture (audiotee --mic) actually removes the
cumulative drift that the old two-process (sox + separate audiotee) design
accumulated. Feeds on the acoustic bleed: on speakers the mic (L) hears the
system (R), so L and R share content and cross-correlate.

PASS  = the L<->R offset is ~constant along the recording (flat line).
FAIL  = the offset grows with time (that is clock drift, the old bug).

Usage: xcorr-drift.py <stereo file .m4a/.wav> [--sr 8000]
Needs: ffmpeg on PATH, numpy. Prints a per-window table + verdict.
"""
import subprocess, sys, tempfile, os, argparse
import numpy as np


def load_raw_stereo(path, sr):
    """Read a raw interleaved f32le stereo file; return (L, R) at native sr.

    (No resampling — `sr` is informational; the file is assumed 48 kHz.)
    """
    x = np.fromfile(path, dtype=np.float32)
    x = x[: (len(x) // 2) * 2].reshape(-1, 2)
    return x[:, 0].copy(), x[:, 1].copy()


def load_channels(path, sr):
    """Decode L and R to mono float arrays at sr via ffmpeg."""
    out = {}
    with tempfile.TemporaryDirectory() as d:
        lp, rp = os.path.join(d, "l.f32"), os.path.join(d, "r.f32")
        cmd = [
            "ffmpeg", "-y", "-v", "error", "-i", path,
            "-filter_complex", "[0:a]channelsplit=channel_layout=stereo[l][r]",
            "-map", "[l]", "-ar", str(sr), "-c:a", "pcm_f32le", "-f", "f32le", lp,
            "-map", "[r]", "-ar", str(sr), "-c:a", "pcm_f32le", "-f", "f32le", rp,
        ]
        subprocess.run(cmd, check=True)
        out["L"] = np.fromfile(lp, dtype=np.float32)
        out["R"] = np.fromfile(rp, dtype=np.float32)
    return out["L"], out["R"]


def gcc_phat(a, b, maxlag):
    """Return (lag_samples, confidence). +lag => R leads L."""
    N = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    A = np.fft.rfft(a, N)
    B = np.fft.rfft(b, N)
    X = A * np.conj(B)
    X /= np.abs(X) + 1e-9
    cc = np.fft.irfft(X, N)
    cc = np.concatenate((cc[-maxlag:], cc[: maxlag + 1]))
    lags = np.arange(-maxlag, maxlag + 1)
    k = int(np.argmax(np.abs(cc)))
    conf = float(np.abs(cc[k]) / (np.median(np.abs(cc)) + 1e-9))
    return int(lags[k]), conf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--sr", type=int, default=8000)
    ap.add_argument("--maxlag-sec", type=float, default=8.0)
    ap.add_argument(
        "--raw", action="store_true",
        help="input is raw interleaved f32le stereo @48kHz (not a container)")
    ap.add_argument(
        "--rms", action="store_true",
        help="print 'L_rms R_rms' of a raw f32 stereo file and exit")
    a = ap.parse_args()

    if a.rms:
        L, R = load_raw_stereo(a.file, 48000)
        lr = float(np.sqrt((L ** 2).mean())) if len(L) else 0.0
        rr = float(np.sqrt((R ** 2).mean())) if len(R) else 0.0
        print(f"{lr:.6f} {rr:.6f}")
        return 0

    if a.raw:
        L, R = load_raw_stereo(a.file, 48000)
        # Boxcar-decimate 48k -> 8k (factor 6): cheap anti-alias + downsample,
        # keeps the windowed analysis identical to the container path.
        f = 6
        L = L[: (len(L) // f) * f].reshape(-1, f).mean(1).astype(np.float32)
        R = R[: (len(R) // f) * f].reshape(-1, f).mean(1).astype(np.float32)
        a.sr = 8000
    else:
        L, R = load_channels(a.file, a.sr)
    n = min(len(L), len(R))
    L, R = L[:n], R[:n]
    dur = n / a.sr
    if dur < 30:
        print(f"WARNING: only {dur:.0f}s — need ~90s+ to see drift", file=sys.stderr)

    maxlag = int(a.maxlag_sec * a.sr)
    # Adaptive window: long enough for a confident correlation peak, short
    # enough to place several windows along a short acceptance clip.
    win = int(min(40.0, max(15.0, dur / 5.0)) * a.sr)
    print(f"file={os.path.basename(a.file)}  dur={dur:.0f}s  sr={a.sr}")
    print(f"{'t_sec':>7} {'offset_ms':>10} {'conf':>7}   (>0 = R/system leads L/mic)")
    pts = []
    for frac in np.linspace(0.02, 0.97, 20):
        s = int(frac * n)
        e = min(s + win, n)
        if e - s < 20 * a.sr:
            continue
        aw, bw = L[s:e], R[s:e]
        if np.sqrt((aw ** 2).mean()) < 1e-4 or np.sqrt((bw ** 2).mean()) < 1e-4:
            print(f"{s/a.sr:7.0f} {'(silent)':>10}")
            continue
        lag, conf = gcc_phat(aw, bw, maxlag)
        ms = lag / a.sr * 1000
        flag = "  low-conf" if conf < 8 else ""
        print(f"{s/a.sr:7.0f} {ms:10.1f} {conf:7.1f}{flag}")
        if conf >= 8:
            pts.append((s / a.sr, ms))

    print()
    if len(pts) < 3:
        print("VERDICT: INCONCLUSIVE — too few confident windows.")
        print("  Likely no acoustic bleed (headphones?) or too quiet.")
        print("  Re-run on SPEAKERS with speech/music playing out loud.")
        return 2

    t = np.array([p[0] for p in pts])
    m = np.array([p[1] for p in pts])
    slope, intercept = np.polyfit(t, m, 1)  # ms per sec
    total = slope * dur
    spread = m.max() - m.min()
    resid = (m - (slope * t + intercept)).std()
    print(f"confident windows : {len(pts)}")
    print(f"offset spread     : {spread:.0f} ms")
    print(f"drift slope       : {slope*1000:.2f} ms per 1000 s")
    print(f"extrapolated total: {total:.0f} ms across {dur:.0f}s")
    print(f"linearity residual: {resid:.0f} ms")
    print()
    # PASS if the trend is essentially flat. Old bug was ~1000 ms/1000s.
    if abs(slope) * 1000 <= 40 and spread <= 150:
        print("VERDICT: PASS — offset is flat. Co-clock removed the drift.")
        return 0
    print("VERDICT: FAIL — offset grows with time (clock drift persists).")
    print("  Co-clock did not lock the tap to the mic; consider offline resync.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

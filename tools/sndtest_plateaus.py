#!/usr/bin/env python3
"""sndtest_plateaus - find each SNDTEST segment's STEADY-STATE content directly.

WHY THIS EXISTS, and it is not a convenience wrapper. A transcript-timed aligner
(an earlier, retired tool) placed each segment's measurement window from the transcript's own measured
`ENDSEG art=` timeline plus an onset SNAP of +/-200 ms. That is sound when a
recording tracks its transcript, but two of these recordings do not:

  * the MiSTer transcript has NO `ENDSEG art=` for SEG 00 (the core recorded
    blank), so the checker falls back to a shorter SEG 00 and every later
    prediction starts ~0.4 s early;
  * the MiSTer run paces 13 % faster overall (74.1 s of ARTIC against the
    machine's 85.3 s), so the offset grows past the snap radius;
and the consequence is not a small bias - a window can straddle two segments.
On the core's SNDTEST recording the aligner's SEG 20 (FM 10 kHz) reports
-25.4 dBFS while the segment's actual steady level is -22.4, and its SEG 01
reports -27.1 dBFS while the FM tone it is supposed to measure sits at -28.0
with a louder neighbouring segment inside the same window.

THIS tool does not use the timeline at all. It finds the constant-level plateaus
in the recording itself (a run of >= `--min-s` seconds whose 20 ms RMS stays
within `--tol-db`), reports each one's level and dominant frequency, and
classifies SINE vs SQUARE from the 3rd harmonic (an OPN FM carrier with ALG 7
and no modulator is a pure sine, 3f ~ -80..-130 dB; an SSG square is -9.5 dB),
which is what separates an FM segment from an SSG one when the timeline is the
thing under suspicion. The SSG volume sweep's four rows are then paired with the
FM TL sweep's first row by CLASS, not by predicted time.

USAGE
  python3 tools/sndtest_plateaus.py REC [REC...] [--min-s 0.8] [--tol-db 1.5]
"""

import argparse
import subprocess
import sys
import numpy as np

SR = 48000
BLOCK_MS = 20


def load(path):
    p = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1",
                        "-ar", str(SR), "-f", "s16le", "-"], capture_output=True)
    if p.returncode != 0:
        sys.exit(f"ffmpeg failed on {path}: {p.stderr.decode()[:200]}")
    return np.frombuffer(p.stdout, dtype="<i2").astype(np.float64) / 32768.0


def db(v):
    return 20.0 * np.log10(max(float(v), 1e-12))


def tone(seg, f):
    """Amplitude in dBFS of the component at f (Hann-windowed Goertzel)."""
    n = len(seg)
    w = seg * np.hanning(n)
    k = np.arange(n)
    c = np.cos(2 * np.pi * f * k / SR)
    s = np.sin(2 * np.pi * f * k / SR)
    return db(2.0 * np.hypot(np.dot(w, c), np.dot(w, s)) / np.sum(np.hanning(n)))


def dominant(seg):
    w = seg * np.hanning(len(seg))
    F = np.abs(np.fft.rfft(w))
    f = np.fft.rfftfreq(len(seg), 1 / SR)
    m = f > 50.0
    i = np.argmax(F[m])
    return float(f[m][i]), db(F[m][i] / (np.sum(np.hanning(len(seg))) / 2))


def plateaus(x, min_s, tol_db):
    D = int(SR * BLOCK_MS / 1000)
    n = len(x) // D
    rms = np.sqrt((x[:n * D].reshape(n, D) ** 2).mean(axis=1))
    lv = np.array([db(v) for v in rms])
    out, i = [], 0
    while i < n:
        j = i
        while j + 1 < n and abs(lv[j + 1] - lv[i]) < tol_db:
            j += 1
        if (j - i + 1) * BLOCK_MS / 1000.0 >= min_s and lv[i] > -70.0:
            out.append((i * BLOCK_MS / 1000.0, (j + 1) * BLOCK_MS / 1000.0,
                        float(np.median(lv[i:j + 1]))))
            i = j + 1
        else:
            i += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recs", nargs="+")
    ap.add_argument("--min-s", type=float, default=0.8)
    ap.add_argument("--tol-db", type=float, default=1.5)
    a = ap.parse_args()

    for rec in a.recs:
        x = load(rec)
        print(f"\n## {rec}  ({len(x)/SR:.3f} s)")
        for s, e, lvl in plateaus(x, a.min_s, a.tol_db):
            seg = x[int(s * SR):int(e * SR)]
            f0, a1 = dominant(seg)
            a3 = tone(seg, 3.0 * f0)
            kind = "SQUARE" if (a3 - a1) > -20.0 else "sine"
            print(f"  {s:7.2f}-{e:7.2f}  {e-s:5.2f} s  {lvl:7.1f} dBFS  "
                  f"f0={f0:8.1f} Hz 3f-1f={a3-a1:+7.1f} dB  {kind}")


if __name__ == "__main__":
    main()

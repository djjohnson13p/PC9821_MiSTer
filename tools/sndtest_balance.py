#!/usr/bin/env python3
"""sndtest_balance - the paired SNDTEST board-balance table, from the recordings.

WHAT IT MEASURES.  The one gain stage no chip model can speak for: the -86
board's SSG:FM summing ratio.  The die stops at its pins (the SSG leaves on the
separate mono ANALOG pin 27, `o_analog = volume_lut[vol_a/b/c]`,
fmopna_impl.c:2438-2441; FM+ADPCM leave as the YM3016 DAC word), so the ratio
between the two paths is the BOARD's analog network.  The WITHIN-SIDE ratio
SSG(max)/FM(max) is immune to the two recorders' unrelated gains - both terms
come out of one recording - which is what makes the paired captures comparable
at all.

WHY IT DOES NOT USE TRANSCRIPT-TIMED WINDOWS (a retired aligner's).  It did, and that
produces a 0.9 dB error, because the aligner anchors on "the program's first
significant sound" and SEG 00 (the MARK) IS SILENT BY DESIGN: sndtest.s writes
it with all three SSG volumes 0 (`W 08 00`, `W 09 00`, `W 0A 00` in the SEG 00
block of every transcript).  The first sound in every recording is therefore
SEG 01's FM tone, while the CSV's t0 for SEG 01 is measured from SEG 00's start
- so every align window measures segment n+1.  On the XE10 that reads SEG 01 at
-28.5 dBFS where the FM tone it is supposed to measure sits at -21.2 (checked
below), and it is why the first cut of this table read the machine's
SSG(max)/FM(max) as -9.70 dB instead of -8.79.

WHAT IT DOES INSTEAD.  It finds the recordings' steady-state plateaus directly
(see tools/sndtest_plateaus.py for the primitive), classifies each one SINE or
SQUARE from the 3rd harmonic, and takes the SSG(max) and FM(max) terms from the
SNDTEST volume/TL sweeps BY CLASS, not by predicted time.  Two further pairs in
the same recordings - the SSWP/FSWP frequency sweeps, and the SEG 07/SEG 01
volume/TL pair - are reported as independent cross-checks, since a correct
answer must not depend on which pair carries it.

USAGE
  python3 tools/sndtest_balance.py REC [REC ...]   # the recordings (WAV/FLAC; not in the repo)
"""

import subprocess
import sys
import numpy as np

SR = 48000
BLOCK_MS = 20
MIN_S = 0.8
TOL_DB = 1.5
TONES = (100.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 10000.0)
# The probe's OWN frequencies per sweep row (sndtest_check.py recomputes and
# checks them against the write log): FSWP is exact to the F-NUM, SSWP's top is
# TP 0x010 -> 7800 Hz and 0x00C -> 10400 Hz, NOT a round 8/10 kHz.
FSWP_HZ = {100: 100.082, 250: 250.098, 500: 500.195, 1000: 1000.391,
           2000: 2000.781, 4000: 4001.562, 8000: 8003.125, 10000: 10000.521}
SSWP_HZ = {100: 100.000, 250: 250.100, 500: 499.200, 1000: 998.400,
           2000: 2012.903, 4000: 4025.806, 8000: 7800.000, 10000: 10400.000}

DEFAULT_RECS = ()  # recordings are not committed: pass them on the command line


def load(path):
    p = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1",
                        "-ar", str(SR), "-f", "s16le", "-"], capture_output=True)
    if p.returncode != 0:
        sys.exit(f"ffmpeg failed on {path}: {p.stderr.decode()[:200]}")
    return np.frombuffer(p.stdout, dtype="<i2").astype(np.float64) / 32768.0


def db(v):
    return 20.0 * np.log10(max(float(v), 1e-12))


def level(x, a, b, frac=0.6):
    """RMS in dBFS over the interior `frac` of a plateau."""
    seg = x[int(a * SR):int(b * SR)]
    n = len(seg)
    m = int(n * (1.0 - frac) / 2)
    return db(np.sqrt((seg[m:n - m] ** 2).mean()))


def dominant(x, a, b):
    n = int((b - a) * SR)
    seg = x[int(a * SR):int(a * SR) + n]
    w = np.hanning(n)
    F = np.abs(np.fft.rfft(seg * w))
    f = np.fft.rfftfreq(n, 1 / SR)
    m = f > 50.0
    i = np.argmax(F[m])
    return float(f[m][i]), db(F[m][i] / (np.sum(w) / 2))


def harmonic(x, a, b, f):
    n = int((b - a) * SR)
    seg = x[int(a * SR):int(a * SR) + n]
    w = seg * np.hanning(n)
    k = np.arange(n)
    c = np.cos(2 * np.pi * f * k / SR)
    s = np.sin(2 * np.pi * f * k / SR)
    return db(2.0 * np.hypot(np.dot(w, c), np.dot(w, s)) / np.sum(np.hanning(n)))


def plateaus(x):
    D = int(SR * BLOCK_MS / 1000)
    n = len(x) // D
    rms = np.sqrt((x[:n * D].reshape(n, D) ** 2).mean(axis=1))
    lv = np.array([db(v) for v in rms])
    out, i = [], 0
    while i < n:
        j = i
        while j + 1 < n and abs(lv[j + 1] - lv[i]) < TOL_DB:
            j += 1
        if (j - i + 1) * BLOCK_MS / 1000.0 >= MIN_S and lv[i] > -70.0:
            out.append((i * BLOCK_MS / 1000.0, (j + 1) * BLOCK_MS / 1000.0))
            i = j + 1
        else:
            i += 1
    return out


def analyse(path):
    x = load(path)
    recs = []
    for a, b in plateaus(x):
        f0, a1 = dominant(x, a, b)
        h3 = harmonic(x, a, b, 3.0 * f0)
        kind = "SQ" if (h3 - a1) > -20.0 else "si"
        recs.append(dict(a=a, b=b, f0=f0, lvl=level(x, a, b), kind=kind, h3=h3 - a1))
    # the volume/TL sweeps: the ~440 Hz plateaus, split by class (6 FM TL rows,
    # 4 SSG volume rows - the probe's own SEC_FM_TL / SEC_SSG_VOL). The 3rd
    # harmonic at 1320 Hz is well inside the band, so the class is measured.
    near = [r for r in recs if 430.0 < r["f0"] < 450.0]
    fm_pitch = sorted([r for r in near if r["kind"] == "si"], key=lambda r: r["a"])
    ssg_pitch = sorted([r for r in near if r["kind"] == "SQ"], key=lambda r: r["a"])
    # The frequency sweeps, assigned by the probe's own section order
    # (sndtest.s runs SEC_FM_SWEEP then SEC_SSG_SWEEP, 8 rows each): the top two
    # SSWP rows sit at 7800 Hz and 10400 Hz, where the 3rd harmonic is at or
    # above Nyquist and CANNOT be measured, so their class is positional and
    # their h3 column is reported as such rather than guessed from a threshold.
    sw = [r for r in recs
          if any(abs(r["f0"] - f) < 0.02 * f for f in list(FSWP_HZ.values()) + list(SSWP_HZ.values()))]
    sw = sorted(sw, key=lambda r: r["a"])
    def sweep(rows, table):
        out = {}
        for r in rows:
            hit = [k for k, f in table.items() if abs(r["f0"] - f) < 0.02 * f]
            if len(hit) == 1:
                out.setdefault(hit[0], []).append(r["lvl"])
        return {t: sum(v) / len(v) for t, v in out.items()}
    fm_sw, ssg_sw = sw[:8], sw[8:16]
    return dict(path=path, fm=fm_pitch, ssg=ssg_pitch,
                fswp=sweep(fm_sw, FSWP_HZ), sswp=sweep(ssg_sw, SSWP_HZ),
                fswp_rows=fm_sw, sswp_rows=ssg_sw, dur=len(x) / SR)


DRUM_ROWS = ("BD il=1F", "BD il=17", "SD il=1F", "SD il=17", "TOP il=1F", "TOP il=17",
             "HH il=1F", "HH il=17", "TOM il=1F", "TOM il=17", "RIM il=1F", "RIM il=17")


def transients(x, thr_db=-15.0, win_ms=5.0, gap_s=0.3):
    """The rhythm section's hits: the only transients in the recording.

    Returns [(t, peak_dbfs)] with peaks above `thr_db`, merged within `gap_s`.

    The default threshold is deliberately HIGH: the rhythm rows are the only
    events in the recording louder than -15 dBFS (they peak at -6..-13, while
    everything else - the SSG's key-on edges, the MARK's absences, the QL rows'
    transients - stays below -17). Lower it and the pairing shifts, which is
    exactly how the probe's IL law came to be doubted in the first place.
    """
    W = int(SR * win_ms / 1000.0)
    n = len(x) // W
    env = np.abs(x[:n * W].reshape(n, W)).max(axis=1)
    lv = np.array([db(v) for v in env])
    out, i = [], 0
    while i < n:
        if lv[i] > thr_db:
            j = i
            while j + 1 < n and lv[j + 1] > thr_db:
                j += 1
            k = i + int(np.argmax(lv[i:j + 1]))
            out.append((k * W / SR, float(lv[k])))
            i = j + 1
        else:
            i += 1
    merged = []
    for t, v in out:
        if merged and t - merged[-1][0] < gap_s:
            if v > merged[-1][1]:
                merged[-1] = (t, v)
        else:
            merged.append((t, v))
    return merged


def drums(path):
    """-> {row: [peak dBFS over the row's two hits]} for the 12 rhythm rows."""
    hits = transients(load(path))
    if len(hits) != 2 * len(DRUM_ROWS):
        print(f"    note: {path} has {len(hits)} transients above the threshold, "
              f"expected {2*len(DRUM_ROWS)} (a machine with no rhythm loaded has none)")
    rows = {}
    for i, name in enumerate(DRUM_ROWS):
        pair = hits[2 * i:2 * i + 2]
        rows[name] = [v for _t, v in pair]
    return rows


def main():
    args = [a for a in sys.argv[1:] if a != "--drums"]
    if not args:
        sys.exit("usage: sndtest_balance.py [--drums] REC [REC ...]  (SNDTEST recordings, WAV/FLAC)")
    if "--drums" in sys.argv:
        for r in (args or list(DEFAULT_RECS)):
            d = drums(r)
            print(f"\n## {r}: rhythm hit PEAKS (dBFS), the only transients in the file")
            for name in DRUM_ROWS:
                print(f"  {name:<10} " + " ".join(f"{v:7.1f}" for v in d[name]))
        return
    recs = args or list(DEFAULT_RECS)
    rows = []
    for r in recs:
        rows.append(analyse(r))

    print("## SSG(max)/FM(max), the board's SSG:FM summing ratio (dB)")
    print("   each ratio is taken INSIDE one recording, so the recorders' gains cancel")
    print(f"{'recording':<40} {'SSG07/FM01':>11} {'SSWP/FSWP':>11} {'SSG07':>8} {'FM01':>8}")
    for d in rows:
        head = d["ssg"][0]["lvl"] - d["fm"][0]["lvl"] if d["ssg"] and d["fm"] else float("nan")
        # the frequency sweeps use the same patch at nominal 0 dB, so they are a
        # second, independent carrier of the same ratio.
        sw = (d["sswp"][100] - d["fswp"][100]
              if 100 in d["sswp"] and 100 in d["fswp"] else float("nan"))
        print(f"{d['path']:<40} {head:>+11.2f} {sw:>+11.2f} "
              f"{d['ssg'][0]['lvl']:>8.2f} {d['fm'][0]['lvl']:>8.2f}")
        if len(d["fswp_rows"]) != 8 or len(d["sswp_rows"]) != 8:
            print(f"    !! section split is {len(d['fswp_rows'])}/{len(d['sswp_rows'])}, expected 8/8")

    print("\n## the FM TL sweep (SNDTEST SEG 01..06, nominal -6.02 dB per TL step)")
    print(f"{'recording':<40} " + " ".join(f"TL{t:<2d}" for t in (0, 8, 16, 24, 32, 48)))
    for d in rows:
        v = [p["lvl"] for p in d["fm"]]
        print(f"{d['path']:<40} " + " ".join(f"{x:7.2f}" for x in v))
    print("   steps:")
    for d in rows:
        v = [p["lvl"] for p in d["fm"]]
        print(f"{d['path']:<40} " + " ".join(f"{v[i+1]-v[i]:+7.2f}" for i in range(len(v) - 1)))

    print("\n## the SSG volume sweep (SNDTEST SEG 07,08,09,0A; die table -8.07/-11.45/-11.66 dB)")
    print(f"{'recording':<40} " + " ".join(f"{n:>7}" for n in ("vol15", "vol12", "vol08", "vol04")))
    for d in rows:
        v = [p["lvl"] for p in d["ssg"]]
        print(f"{d['path']:<40} " + " ".join(f"{x:7.2f}" for x in v))
    for d in rows:
        v = [p["lvl"] for p in d["ssg"]]
        print(f"{d['path']:<40} " + " ".join(f"{v[i+1]-v[i]:+7.2f}" for i in range(len(v) - 1)))

    print("\n## the frequency sweeps, dBFS relative to each side's own 100 Hz row")
    print(f"{'recording':<40} {'side':<5} " + " ".join(f"{t:>7.0f}" for t in TONES))
    for d in rows:
        for name, sw in (("FM", d["fswp"]), ("SSG", d["sswp"])):
            if 100 not in sw:
                continue
            base = sw[100]
            print(f"{d['path']:<40} {name:<5} "
                  + " ".join(f"{sw[t] - base:+7.2f}" if t in sw else f"{'--':>7}"
                             for t in TONES))

    print("\n## the 3rd-harmonic test behind the SINE/SQUARE split (dB below the fundamental)")
    print("   a pure OPN FM carrier is a sine (~-80 dB); an SSG square is -9.5 dB")
    for d in rows:
        print(f"  {d['path']:<40} FM vol-sweep rows: "
              + " ".join(f"{p['h3']:+6.1f}" for p in d["fm"])
              + " | SSG vol-sweep rows: "
              + " ".join(f"{p['h3']:+6.1f}" for p in d["ssg"]))
        print(f"  {'':<40} FSWP rows:        "
              + " ".join(f"{p['h3']:+6.1f}" for p in d["fswp_rows"])
              + " | SSWP rows:        "
              + " ".join((f"{p['h3']:+6.1f}" if p["h3"] > -40.0 else f"{'n/a':>6}")
                         for p in d["sswp_rows"]))

    print("\n## the FM TL00 reference, three ways (a correct answer must not depend on which)")
    for d in rows:
        a = d["fm"][0]["lvl"] if d["fm"] else float("nan")
        b = d["fswp"].get(100, float("nan"))
        print(f"  {d['path']:<40} SEG01={a:7.2f}  FSWP100={b:7.2f}  delta={a-b:+5.2f}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Prove the FIR engine's 34-bit accumulator (ACCW in pc9821_audio_fir_engine.sv) is exact.

|acc| <= 32768 * sum|coefficient| over one run, per stage and (for the polyphase stage C)
per phase. The coefficient tables are read from the shipped sources; ACCW is read from the
engine. The accumulator holds the true sum when that bound is below 2^(ACCW-1).

Usage: python3 tools/check_fir_acc_bound.py     (exit 0 = exact, 1 = a bound is exceeded)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AUD = ROOT / "src/pc9821/audio"


def table(src: str, name: str) -> list[int]:
    m = re.search(r"localparam \[18\*(\d+)-1:0\] " + name + r" = \{(.*?)\};", src, re.S)
    v = [int(x, 16) for x in re.findall(r"18'sh([0-9a-f]+)", m.group(2))]
    v = [x - (1 << 18) if x >= 1 << 17 else x for x in v]
    return v[::-1]  # index 0 is the lowest slice


def main() -> int:
    eng = (AUD / "pc9821_audio_fir_engine.sv").read_text()
    accw = int(re.search(r"localparam integer ACCW = (\d+);", eng).group(1))
    out = (AUD / "pc9821_audio_out.sv").read_text()
    b, c = table(out, "COEFF_B"), table(out, "COEFF_C")
    h = [1, 5, 15, 35, 65, 101, 135, 155, 155, 135, 101, 65, 35, 15, 5, 1]
    worst = {
        "A (cic4, 16 taps)": sum(x << 7 for x in h),
        "B (19 taps)": sum(abs(b[i if i <= 9 else 18 - i]) for i in range(19)),
    }
    for ph in range(5):
        idx = [5 * k + ph for k in range(247)]
        worst[f"C phase {ph} (247 taps)"] = sum(abs(c[i if i <= 617 else 1234 - i]) for i in idx)
    ok = True
    for name, s in worst.items():
        bound = 32768 * s
        fits = bound <= (1 << (accw - 1))
        ok &= fits
        print(f"{name:24s} sum|c|={s:7d}  bound={bound:.4g}  limit 2^{accw-1}={1 << (accw - 1):.4g}  {'ok' if fits else 'EXCEEDED'}")
    # Stage A runs without the output clamp (SAT = 0): its accumulator must stay inside the
    # 16-bit result window [-2^32, 2^32) (SHIFT+15 = 32), i.e. never reach +2^32.
    a_pos = 32767 * sum(x << 7 for x in h)
    a_neg = -32768 * sum(x << 7 for x in h)
    a_ok = a_pos < (1 << 32) and a_neg >= -(1 << 32)
    print(f"A without clamp: acc in [{a_neg}, {a_pos}] vs [-2^32, 2^32)  {'ok' if a_ok else 'EXCEEDED'}")
    ok &= a_ok
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

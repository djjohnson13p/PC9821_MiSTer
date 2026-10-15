#!/usr/bin/env python3
"""Measure the REAL YM2608 ADPCM-A (rhythm) ROM's decoded peaks and the post-gain
levels that reach the FM+ADPCM junction clamp in the PC-9801-86 core.

Decoder: ymfm adpcm_a_channel::clock() (ymfm_adpcm.cpp) and adpcm_a_channel::output()
(ymfm_adpcm.cpp ~223-243); qemu hw/audio/fmopn.c ADPCMA_calc_chan / vol_mul / vol_shift
agree byte-for-byte. The jt10_adpcma_lut.v LUT is the same delta arithmetic precomputed
(verified: all 392 entries == (2n+1)*S_STEPS[step]/8). Expected values come ONLY from the
ROM image + the reference decoder/gain laws, never from our RTL as self-evidence.

ROM image: the canonical MAME/FBNeo YM2608 mask ROM (sha256 53afd0fa...), identical to
OPNA_ADPCM.ROM -- the file passed to build_pack.py --rhythm.

Usage: tools/research/adpcm_a_levels.py [OPNA_ADPCM.ROM] [jt10_adpcma_lut.v]
(defaults: bios/OPNA_ADPCM.ROM and this tree's src/opna LUT)
"""
import re, hashlib, sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[2]
ROM_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else _ROOT / "bios/OPNA_ADPCM.ROM"
LUT_PATH = (Path(sys.argv[2]) if len(sys.argv) > 2
            else _ROOT / "src/opna/jt12/hdl/adpcm/jt10_adpcma_lut.v")

# ymfm s_steps (ymfm_adpcm.cpp) -- ADPCM-A 1.1^N step table.
S_STEPS = [16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,
118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,
724,796,876,963,1060,1166,1282,1411,1552]
STEP_INC = [-1,-1,-1,-1,2,5,7,9]

def clamp(v, lo, hi): return max(lo, min(hi, v))

def sign12(v):
    v &= 0xfff
    return v if v < 0x800 else v - 0x1000

# ---- cross-check A: jt10_adpcma_lut.v == ymfm delta formula -----------------
def parse_lut(path):
    text = re.sub(r"//[^\n]*", "", path.read_text())   # drop commented-out values
    lut = {}
    for m in re.finditer(r"lut\[9'o([0-7]+)_(\d)\]\s*=\s*12'o([0-7]+)", text):
        lut[(int(m.group(1), 8), int(m.group(2)))] = int(m.group(3), 8)
    return lut

# ---- cross-check B: jt08_adpcm_gain.v == ymfm/qemu gain ---------------------
def rtl_gain(acc, vol):
    """jt08_adpcm_gain.v, modelled exactly. pcm_in is the 16-bit sign-extended
    12-bit accumulator; the product is signed 16x16; pcm3 = pcm2_mul[16:1] is
    floor(product/2) for this range (a part-select of a 16-bit-range product); then
    arithmetic >>> (vol>>3); then &~3. Mute when (vol>>3)>=8 i.e. vol>=64."""
    acc16 = sign12(acc)
    mul = 0 if vol >= 64 else (15 - (vol & 7))
    pcm3 = (acc16 * mul) >> 1                 # == pcm2_mul[16:1] (floor, 16-bit range)
    v = pcm3 >> (vol >> 3)                    # arithmetic shift (distributed >>>1)
    v &= ~3
    v &= 0xffff
    return v if v < 0x8000 else v - 0x10000

def ymfm_gain(acc, vol):
    """ymfm adpcm_a_channel::output() == qemu vol_mul/vol_shift."""
    if vol >= 63:
        return 0
    mul = 15 - (vol & 7)
    shift = 5 + (vol >> 3)
    return ((sign12(acc) * 16 * mul) >> shift) & ~3

# ---- decoder (ymfm clock()) ------------------------------------------------
def decode(rom, start, end):
    """Decode bytes [start, end] INCLUSIVE, high nibble first then low nibble."""
    acc = 0; step = 0; out = []
    for addr in range(start, end + 1):
        b = rom[addr]
        for nib in ((b >> 4) & 0xf, b & 0xf):
            n = nib & 7
            delta = (2 * n + 1) * S_STEPS[step] // 8
            if nib & 8: delta = -delta
            acc = (acc + delta) & 0xfff
            out.append(sign12(acc))
            step = clamp(step + STEP_INC[n], 0, 48)
    return out

def main():
    rom = ROM_PATH.read_bytes()
    print(f"ROM {ROM_PATH}  sha256 {hashlib.sha256(rom).hexdigest()}")

    lut = parse_lut(LUT_PATH)
    lut_mm = 0
    for step in range(49):
        for n in range(8):
            if lut.get((step, n)) != (2*n+1)*S_STEPS[step]//8:
                lut_mm += 1
    maxdelta = max((2*n+1)*S_STEPS[step]//8 for step in range(49) for n in range(8))
    print(f"jt10 LUT: {len(lut)} entries, {lut_mm} mismatches vs ymfm delta formula "
          f"(0 = byte-identical); max |delta| = {maxdelta} (0x{maxdelta:X}) > 0x7FF")

    gain_mm = 0; gain_vols = set()
    for vol in range(95):
        for acc in range(-2048, 2048):
            if rtl_gain(acc, vol) != ymfm_gain(acc, vol):
                gain_mm += 1; gain_vols.add(vol)
    print(f"jt08_adpcm_gain vs ymfm/qemu: {gain_mm} mismatches over acc x vol; "
          f"divergent vols = {sorted(gain_vols)}")

    instr = [("bass drum",0x0000,0x01bf),("snare drum",0x01c0,0x043f),
             ("top cymbal",0x0440,0x1b7f),("high hat",0x1b80,0x1cff),
             ("tom tom",0x1d00,0x1f7f),("rim shot",0x1f80,0x1fff)]
    print("\n%12s %8s %8s %8s | %8s %8s | %9s %9s" % (
        "drum","start","end","bytes","|acc|pk","acc_hi","gain@0","gain@TL20"))
    rows = []
    for name, s, e in instr:
        accs = decode(rom, s, e)
        pk = max(abs(a) for a in accs)
        g0 = max(abs(ymfm_gain(a, 0)) for a in accs)          # vol=0: IL=0x1f, TL=0x3f
        g20 = max(abs(ymfm_gain(a, 63 - 0x20)) for a in accs) # TL=0x20 -> vol=31
        rows.append((name, pk, max(accs), g0))
        print("%12s %#8x %#8x %8d | %8d %8d | %9d %9d" % (
            name, s, e, e-s+1, pk, max(accs), g0, g20))

    peaks = sorted((r[3] for r in rows), reverse=True)
    print("\nworst-case overlap sums at vol=0 (all peaks aligned):")
    for k in range(1, 4):
        s = sum(peaks[:k])
        print(f"  {k} drum(s): {s:6d} ({s/32767:6.1%} of +-32767) "
              f"{'CLIPS' if s > 32767 else 'ok'}")

if __name__ == "__main__":
    main()

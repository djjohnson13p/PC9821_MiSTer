#!/usr/bin/env python3
"""Convert a CUE sheet and its BIN file(s) into ONE .PCD image for the core's CD-ROM drive.

WHY ONE FILE. hps_io mounts one file per OSD slot, so the track layout a CUE keeps in a separate
text file has to travel inside the image. A PCD is a 2352-byte header followed by the disc as raw
2352-byte sectors, LBA 0 first:

  offset 0     the header sector (2352 bytes; the first 2048 are read by the drive at mount)
                  0  "PC98CD01"
                  8  track count            9  first track number
                 12  lead-out LBA (u32 LE)
                 16  4 bytes per entry (tracks, then the lead-out): u32 LE =
                       control (0x14 data / 0x10 audio) | LBA << 8 (24 bits)
                       | 0x80000000 for a MODE2 track
                512  per entry: the LBA, u32 big-endian      (READ TOC, LBA form)
               1024  per entry: 00 M S F of LBA + 150         (READ TOC, MSF form)
               1536  per entry: the same M S F in BCD         (NEC drivers' BCD form)
  offset 2352  disc sector 0, 1, ... as raw 2352-byte sectors

This is the layout of the Zet98 core's converter (Zet98_486_MiSTer's pc98_cd_image.py @3843bd5,
read as a FORMAT DESCRIPTION only - none of its code is used here), so a PCD from either tool
mounts in either core. src/pc9821/storage/pc9821_atapi.sv reads the header fields above and
serves a data sector's MODE1 user data from raw offset +16.

WHAT IS NEW HERE: MIXED SECTOR SIZES IN ONE BIN, AND PREGAP. A CUE may describe one BIN whose
tracks have different sector sizes - e.g. track 01 MODE1/2048 (cooked) followed by AUDIO tracks
(raw 2352) - and its INDEX times count SECTORS of each track's own size. The file is therefore
walked track by track: a track occupies the file from its first INDEX (00 if present, else 01)
up to the next track's first INDEX, at its own sector size (NP2kai's CUE reader does the same
walk: NP2kai diskimage/cddfile.c, the per-track sector_size loop). A PREGAP (and
POSTGAP) is NOT in the file: it is generated as silent sectors on the disc, so every later LBA
moves by its length - again NP2kai's rule (cdd_cue.c's pregapoffset).

COOKED DATA SECTORS ARE EXPANDED TO RAW 2352-BYTE MODE1 SECTORS (the choice, and why). The
alternative was a per-track sector size in the header, so the drive would find a 2048-byte
sector at a variable stride. That moves a track-table walk and a second multiplier into the
RTL for every read; a uniform 2352 stride is one constant multiply (2352 = 2048+256+32+16) and
the header the drive already reads. The cost is 15% more bytes on the SD card for the data
track, which is nothing next to a CD's audio. A wrapped sector gets the 12-byte sync, the
header (BCD M:S:F of LBA+150, mode 1) and its 2048 bytes; the 288-byte EDC/ECC tail is ZERO by
default (the drive never reads it - it has no READ CD) and correct with --ecc, which computes
the ECMA-130 EDC (CRC-32, polynomial 0x8001801B) and the RSPC P/Q parity, so the image is also a
valid raw disc for other tools.

Usage:
  tools/cue2pcd.py GAME.cue [GAME.pcd] [--ecc] [--force]
  tools/cue2pcd.py GAME.cue --info          # the parsed layout and the TOC, no output
  tools/cue2pcd.py --selftest               # synthetic CUEs (mixed sizes, PREGAP) round-trip
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys
import tempfile
from dataclasses import dataclass, field

RAW = 2352
MAGIC = b"PC98CD01"
SIZES = {"MODE1/2048": 2048, "MODE1/2352": RAW, "MODE2/2048": 2048, "MODE2/2336": 2336,
         "MODE2/2352": RAW, "AUDIO": RAW}


def msf_frames(text: str) -> int:
    m = re.fullmatch(r"(\d+):(\d+):(\d+)", text.strip())
    if not m:
        raise ValueError(f"bad M:S:F time {text!r}")
    mm, ss, ff = (int(x) for x in m.groups())
    if ss >= 60 or ff >= 75:
        raise ValueError(f"bad M:S:F time {text!r}")
    return (mm * 60 + ss) * 75 + ff


def msf(lba_plus_150: int) -> tuple[int, int, int]:
    return lba_plus_150 // 4500, (lba_plus_150 // 75) % 60, lba_plus_150 % 75


def bcd(v: int) -> int:
    return (v // 10) << 4 | (v % 10)


@dataclass
class Track:
    number: int
    mode: str
    file: str
    big_endian: bool
    index0: int | None = None
    index1: int | None = None
    pregap: int = 0
    postgap: int = 0
    # filled by layout()
    file_offset: int = 0       # byte offset of its first INDEX in the file
    file_sectors: int = 0      # sectors it occupies in the file (from its first INDEX)
    disc_lba: int = 0          # the TOC address: INDEX 01 on the disc
    disc_first: int = 0        # first disc sector of the track incl. PREGAP

    @property
    def size(self) -> int:
        return SIZES[self.mode]

    @property
    def audio(self) -> bool:
        return self.mode == "AUDIO"

    @property
    def control(self) -> int:
        return 0x10 if self.audio else 0x14


@dataclass
class Disc:
    tracks: list[Track] = field(default_factory=list)
    leadout: int = 0


def resolve(base: str, name: str) -> str:
    """The FILE's path; CUEs written on Windows often differ from the file name in case only."""
    path = os.path.join(base, name)
    if os.path.exists(path):
        return path
    folded = [f for f in os.listdir(base) if f.lower() == name.lower()]
    return os.path.join(base, folded[0]) if len(folded) == 1 else path


def parse_cue(path: str) -> Disc:
    base = os.path.dirname(os.path.abspath(path))
    disc = Disc()
    cur_file, big = None, False
    with open(path, encoding="latin-1") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.upper().startswith(("REM", "CATALOG", "TITLE", "PERFORMER",
                                                    "SONGWRITER", "ISRC", "FLAGS", "CDTEXTFILE")):
                continue
            m = re.match(r'FILE\s+(?:"([^"]+)"|(\S+))\s+(\S+)$', line, re.I)
            if m:
                kind = m.group(3).upper()
                if kind not in ("BINARY", "MOTOROLA"):
                    raise ValueError(f"FILE type {kind} is not supported (BINARY / MOTOROLA only)")
                cur_file = resolve(base, m.group(1) or m.group(2))
                big = kind == "MOTOROLA"
                continue
            m = re.match(r"TRACK\s+(\d+)\s+(\S+)$", line, re.I)
            if m:
                if cur_file is None:
                    raise ValueError("TRACK before any FILE")
                mode = m.group(2).upper()
                if mode not in SIZES:
                    raise ValueError(f"track mode {mode} is not supported")
                disc.tracks.append(Track(int(m.group(1)), mode, cur_file, big))
                continue
            m = re.match(r"INDEX\s+(\d+)\s+(\S+)$", line, re.I)
            if m:
                if not disc.tracks:
                    raise ValueError("INDEX before any TRACK")
                n, t = int(m.group(1)), msf_frames(m.group(2))
                if n == 0:
                    disc.tracks[-1].index0 = t
                elif n == 1:
                    disc.tracks[-1].index1 = t
                continue   # INDEX 02+ are sub-indices inside the track: nothing to lay out
            m = re.match(r"(PREGAP|POSTGAP)\s+(\S+)$", line, re.I)
            if m:
                if not disc.tracks:
                    raise ValueError(f"{m.group(1)} before any TRACK")
                setattr(disc.tracks[-1], m.group(1).lower(), msf_frames(m.group(2)))
                continue
            raise ValueError(f"unrecognised CUE line: {line!r}")
    if not 1 <= len(disc.tracks) <= 99:
        raise ValueError("a disc has 1..99 tracks")
    for a, b in zip(disc.tracks, disc.tracks[1:]):
        if b.number != a.number + 1:
            raise ValueError(f"track {b.number} does not follow track {a.number}")
    for t in disc.tracks:
        if t.index1 is None:
            raise ValueError(f"track {t.number} has no INDEX 01")
        if t.index0 is not None and t.index0 > t.index1:
            raise ValueError(f"track {t.number}: INDEX 00 after INDEX 01")
    layout(disc)
    return disc


def layout(disc: Disc) -> None:
    """File offsets (the mixed-size walk) and disc LBAs (PREGAP/POSTGAP generated)."""
    by_file: dict[str, list[Track]] = {}
    for t in disc.tracks:
        by_file.setdefault(t.file, []).append(t)
    for name, tracks in by_file.items():
        size = os.path.getsize(name)
        offset, prev = 0, None
        for t in tracks:
            start = t.index0 if t.index0 is not None else t.index1
            if prev is None:
                # Sectors before the first track's first INDEX in a file belong to nothing on
                # the disc layout NP2kai builds either; there are none in a well-formed CUE.
                if start != 0:
                    offset = start * t.size
            else:
                pstart = prev.index0 if prev.index0 is not None else prev.index1
                prev.file_sectors = start - pstart
                if prev.file_sectors <= 0:
                    raise ValueError(f"track {t.number} starts before track {prev.number}")
                offset += prev.file_sectors * prev.size
            t.file_offset = offset
            prev = t
        rest = size - offset
        if rest < 0 or rest % prev.size:
            raise ValueError(f"{name}: track {prev.number} has {rest} bytes, not a whole number "
                             f"of {prev.size}-byte sectors (check the CUE's modes/INDEX times)")
        prev.file_sectors = rest // prev.size
    lba = 0
    for t in disc.tracks:
        t.disc_first = lba
        before_index1 = (t.index1 - t.index0) if t.index0 is not None else 0
        t.disc_lba = lba + t.pregap + before_index1
        lba += t.pregap + t.file_sectors + t.postgap
    disc.leadout = lba
    if disc.leadout >= 1 << 20:
        raise ValueError("disc too long for the drive's 20-bit LBA")


# ---- ECMA-130 EDC/ECC (--ecc) ----
def _edc_table() -> list[int]:
    table = []
    for i in range(256):
        e = i
        for _ in range(8):
            e = (e >> 1) ^ (0xD8018001 if e & 1 else 0)   # 0x8001801B, bit-reversed
        table.append(e)
    return table


EDC = _edc_table()
GF_EXP = [0] * 512
GF_LOG = [0] * 256
_x = 1
for _i in range(255):
    GF_EXP[_i] = _x
    GF_LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D   # x^8 + x^4 + x^3 + x^2 + 1, ECMA-130 annex A
for _i in range(255, 512):
    GF_EXP[_i] = GF_EXP[_i - 255]


def _gmul(a: int, b: int) -> int:
    return 0 if a == 0 or b == 0 else GF_EXP[GF_LOG[a] + GF_LOG[b]]


def edc(data: bytes) -> int:
    e = 0
    for byte in data:
        e = EDC[(e ^ byte) & 0xFF] ^ (e >> 8)
    return e


def _rs_parity(symbols: list[int]) -> tuple[int, int]:
    """The two parity symbols p0 (at the second-to-last position) and p1 (last) of a
    Reed-Solomon codeword over GF(2^8) whose check matrix is H = [[1..1],[a^(n-1)..a^0]]
    (ECMA-130 annex A): sum(c_i) = 0 and sum(c_i * a^(n-1-i)) = 0, n = len(symbols) + 2."""
    n = len(symbols) + 2
    s0 = 0
    s1 = 0
    for i, v in enumerate(symbols):
        s0 ^= v
        s1 ^= _gmul(v, GF_EXP[n - 1 - i])
    # unknowns x (position n-2, weight a^1) and y (position n-1, weight a^0):
    #   x + y = s0 ;  a*x + y = s1   =>  x = (s0 + s1) / (1 + a) , y = s0 + x
    inv = GF_EXP[255 - GF_LOG[1 ^ 2]]
    x = _gmul(s0 ^ s1, inv)
    return x, s0 ^ x


def _rs_fill(sector: bytearray) -> None:
    # P parity: for each lane and each of the 43 columns, the 24 data symbols at word index
    # row*43 + col, rows 0..23, then 2 parity symbols stored at words 1032 + col and 1075 + col.
    for lane in range(2):
        for col in range(43):
            syms = [sector[12 + 2 * (row * 43 + col) + lane] for row in range(24)]
            p0, p1 = _rs_parity(syms)
            sector[12 + 2 * (24 * 43 + col) + lane] = p0
            sector[12 + 2 * (25 * 43 + col) + lane] = p1
    # Q parity: for each lane and each of the 26 diagonals, the 43 symbols at word index
    # (44*m + 43*d) mod 1118, m = 0..42, then 2 parity symbols at words 1118 + d and 1144 + d.
    for lane in range(2):
        for d in range(26):
            syms = [sector[12 + 2 * ((44 * m + 43 * d) % 1118) + lane] for m in range(43)]
            q0, q1 = _rs_parity(syms)
            sector[12 + 2 * (1118 + d) + lane] = q0
            sector[12 + 2 * (1144 + d) + lane] = q1


def mode1_sector(user: bytes, lba: int, with_ecc: bool) -> bytes:
    m, s, f = msf(lba + 150)
    sector = bytearray(RAW)
    sector[0:12] = b"\x00" + b"\xff" * 10 + b"\x00"
    sector[12:16] = bytes((bcd(m), bcd(s), bcd(f), 1))
    sector[16:2064] = user
    if with_ecc:
        sector[2064:2068] = struct.pack("<I", edc(sector[0:2064]))
        _rs_fill(sector)
    return bytes(sector)


def header(disc: Disc) -> bytes:
    h = bytearray(RAW)
    h[0:8] = MAGIC
    h[8] = len(disc.tracks)
    h[9] = disc.tracks[0].number
    struct.pack_into("<I", h, 12, disc.leadout)
    entries = [(t.control, t.disc_lba, t.mode.startswith("MODE2")) for t in disc.tracks]
    entries.append((disc.tracks[-1].control, disc.leadout, False))
    for i, (ctrl, lba, mode2) in enumerate(entries):
        struct.pack_into("<I", h, 16 + 4 * i, ctrl | (lba << 8) | (0x80000000 if mode2 else 0))
        struct.pack_into(">I", h, 512 + 4 * i, lba)
        m, s, f = msf(lba + 150)
        h[1024 + 4 * i:1028 + 4 * i] = bytes((0, m, s, f))
        h[1536 + 4 * i:1540 + 4 * i] = bytes((0, bcd(m), bcd(s), bcd(f)))
    return bytes(h)


def sectors(disc: Disc, with_ecc: bool):
    """Yield every disc sector, LBA 0 first, as 2352 raw bytes."""
    handles: dict[str, object] = {}
    lba = 0
    try:
        for t in disc.tracks:
            silent = bytes(RAW)
            for _ in range(t.pregap):
                yield silent if t.audio else mode1_sector(bytes(2048), lba, with_ecc)
                lba += 1
            h = handles.get(t.file) or handles.setdefault(t.file, open(t.file, "rb"))
            h.seek(t.file_offset)
            for _ in range(t.file_sectors):
                data = h.read(t.size)
                if len(data) != t.size:
                    raise ValueError(f"{t.file}: short read in track {t.number}")
                if t.size == RAW:
                    if t.audio and t.big_endian:
                        data = bytes(b for pair in zip(data[1::2], data[0::2]) for b in pair)
                    yield data
                elif t.mode == "MODE1/2048" or t.mode == "MODE2/2048":
                    yield mode1_sector(data, lba, with_ecc)
                else:
                    raise ValueError(f"track {t.number}: {t.mode} cannot be stored raw")
                lba += 1
            for _ in range(t.postgap):
                yield silent if t.audio else mode1_sector(bytes(2048), lba, with_ecc)
                lba += 1
    finally:
        for h in handles.values():
            h.close()
    assert lba == disc.leadout


def describe(disc: Disc) -> str:
    out = []
    for t in disc.tracks:
        m, s, f = msf(t.disc_lba + 150)
        out.append(f"track {t.number:2d} {t.mode:<10} {'audio' if t.audio else 'data '} "
                   f"LBA {t.disc_lba:7d} {m:02d}:{s:02d}:{f:02d}  file +{t.file_offset} "
                   f"x{t.file_sectors} @{t.size}  pregap {t.pregap} postgap {t.postgap}")
    m, s, f = msf(disc.leadout + 150)
    out.append(f"lead-out LBA {disc.leadout} {m:02d}:{s:02d}:{f:02d}")
    return "\n".join(out)


def convert(cue: str, out: str, with_ecc: bool) -> Disc:
    disc = parse_cue(cue)
    tmp = out + ".part"
    with open(tmp, "wb") as o:
        o.write(header(disc))
        for sector in sectors(disc, with_ecc):
            o.write(sector)
    os.replace(tmp, out)
    return disc


# ---- self-test: synthetic discs, every rule above checked against independent arithmetic ----
def selftest() -> int:
    fails = 0

    def check(cond, what):
        nonlocal fails
        if not cond:
            fails += 1
            print("SELFTEST FAIL:", what)

    def user(lba, i):
        return (lba * 7 + i * 3 + (i >> 8)) & 0xFF

    def pcm(n, i):
        return (n * 31 + i * 5) & 0xFF

    with tempfile.TemporaryDirectory(dir=os.environ.get("CUE2PCD_TMP")) as d:
        # one BIN: 12 cooked MODE1 sectors, 5 audio (track 2, after a 2 s PREGAP), then an
        # INDEX 00 run of 3 audio sectors and 4 more for track 3
        data = bytes(user(l, i) for l in range(12) for i in range(2048))
        a2 = bytes(pcm(2, i) for i in range(5 * RAW))
        a3 = bytes(pcm(3, i) for i in range(7 * RAW))
        with open(os.path.join(d, "x.bin"), "wb") as f:
            f.write(data + a2 + a3)
        with open(os.path.join(d, "x.cue"), "w") as f:
            f.write('FILE "x.bin" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                    '  TRACK 02 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 00:00:12\n'
                    '  TRACK 03 AUDIO\n    INDEX 00 00:00:17\n    INDEX 01 00:00:20\n')
        for with_ecc in (False, True):
            out = os.path.join(d, f"x{int(with_ecc)}.pcd")
            disc = convert(os.path.join(d, "x.cue"), out, with_ecc)
            img = open(out, "rb").read()
            check(len(img) == RAW * (1 + 12 + 150 + 5 + 7), "file length (header + every sector)")
            check(img[0:8] == MAGIC and img[8] == 3 and img[9] == 1, "magic / track count / first")
            # track 2 starts after 12 data sectors + 150 generated; track 3's INDEX 01 is 3 into
            # its INDEX 00 run, 5 audio sectors after track 2's start
            check([t.disc_lba for t in disc.tracks] == [0, 162, 170], "TOC LBAs")
            check(disc.leadout == 12 + 150 + 5 + 7, "lead-out")
            check(struct.unpack_from("<I", img, 12)[0] == disc.leadout, "header lead-out")
            check(struct.unpack_from("<I", img, 16 + 4)[0] == 0x10 | (162 << 8), "entry 1 word")
            check(struct.unpack_from(">I", img, 512 + 8)[0] == 170, "entry 2 BE LBA")
            check(img[1024 + 8:1028 + 8] == bytes((0, 0, 4, 20)), "entry 2 MSF (320 = 0:04:20)")
            check(img[1536 + 12:1540 + 12] == bytes((0, 0, 0x04, 0x24)),
                  "lead-out BCD (174 + 150 = 324 frames = 0:04:24)")
            # a cooked sector: sync, BCD header, user data at +16
            s5 = img[RAW * (1 + 5):RAW * (2 + 5)]
            check(s5[0:12] == b"\x00" + b"\xff" * 10 + b"\x00", "sync")
            check(s5[12:16] == bytes((0x00, 0x02, 0x05, 1)), "MODE1 header of LBA 5 (00:02:05)")
            check(s5[16:2064] == bytes(user(5, i) for i in range(2048)), "user data at +16")
            # the PREGAP is silence; the audio is copied raw
            check(img[RAW * (1 + 12):RAW * (1 + 162)] == bytes(150 * RAW), "PREGAP silence")
            check(img[RAW * (1 + 162):RAW * (1 + 167)] == a2, "track 2 audio")
            check(img[RAW * (1 + 167):RAW * (1 + 174)] == a3, "track 3 audio incl. INDEX 00")
            if with_ecc:
                check(struct.unpack_from("<I", s5, 2064)[0] == edc(s5[0:2064]), "EDC")
                check(any(s5[2076:]), "ECC present")
            else:
                check(not any(s5[2064:]), "EDC/ECC zero by default")
        # the EDC against the published CRC check value of its polynomial (reflected 0x8001801B,
        # init 0, no final xor: "123456789" -> 0x6EC2EDC4)
        check(edc(b"123456789") == 0x6EC2EDC4, "EDC check value")
        # the RS code: every P column and Q diagonal must have a zero syndrome
        sec = bytearray(mode1_sector(bytes(user(9, i) for i in range(2048)), 9, True))
        ok = True
        for lane in range(2):
            for col in range(43):
                syms = [sec[12 + 2 * (row * 43 + col) + lane] for row in range(26)]
                s0 = s1 = 0
                for i, v in enumerate(syms):
                    s0 ^= v
                    s1 ^= _gmul(v, GF_EXP[25 - i])
                ok &= s0 == 0 and s1 == 0
            for dg in range(26):
                syms = [sec[12 + 2 * ((44 * m + 43 * dg) % 1118) + lane] for m in range(43)]
                syms += [sec[12 + 2 * (1118 + dg) + lane], sec[12 + 2 * (1144 + dg) + lane]]
                s0 = s1 = 0
                for i, v in enumerate(syms):
                    s0 ^= v
                    s1 ^= _gmul(v, GF_EXP[44 - i])
                ok &= s0 == 0 and s1 == 0
        check(ok, "RSPC syndromes zero")
        # rejected inputs
        with open(os.path.join(d, "bad.cue"), "w") as f:
            f.write('FILE "x.bin" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                    '  TRACK 02 AUDIO\n    INDEX 01 00:00:13\n')
        try:
            parse_cue(os.path.join(d, "bad.cue"))
            check(False, "a size that is not whole sectors must be rejected")
        except ValueError:
            pass
    print("cue2pcd selftest:", "PASS" if fails == 0 else f"FAIL ({fails})")
    return 0 if fails == 0 else 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cue", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--ecc", action="store_true", help="compute EDC/ECC for wrapped data sectors")
    ap.add_argument("--info", action="store_true", help="print the layout; write nothing")
    ap.add_argument("--force", action="store_true", help="overwrite an existing output")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not a.cue:
        ap.error("a CUE sheet is required")
    if a.info:
        print(describe(parse_cue(a.cue)))
        return 0
    out = a.out or os.path.splitext(a.cue)[0] + ".pcd"
    if os.path.exists(out) and not a.force:
        ap.error(f"refusing to overwrite {out} (--force)")
    disc = convert(a.cue, out, a.ecc)
    print(describe(disc))
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

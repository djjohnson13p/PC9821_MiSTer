#!/usr/bin/env python3
"""Convert a VFDD (VFD1.00) sparse floppy container to a flat raw 2HD image.

Format (NP2kai diskimage/fd/fdd_head_vfdd.h, and verified against the file):
  head:  verID[8] + memo[128] + write_protect:16 + spdrv:16 + dmy[80]  = 220 bytes
  table: 160*26 entries x 12 bytes {C,H,R,N,D,DDAM,flMF,flHD,dataPoint:32} = 49920
  tail:  32 bytes
Data sectors are 1<<(7+N) bytes at dataPoint; a sector the table does not
point at is filled with the table's own D pattern byte.
"""
import sys, struct
if len(sys.argv) != 3 or sys.argv[1] in ('-h', '--help'):
    print(__doc__)
    print('usage: vfdd2raw.py <in.fdd> <out.hdm>')
    raise SystemExit(0 if len(sys.argv) > 1 else 2)
src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
assert d[:8] == b'VFD1.00\x00', 'not a VFDD container'
BASE = 220
entry = {}
fill = 0xff
for trk in range(160):
    for sec in range(26):
        o = BASE + (trk*26 + sec)*12
        C,H,R,N,D,DDAM,flMF,flHD = d[o:o+8]
        dp, = struct.unpack_from('<i', d, o+8)
        if R == 0: continue
        if dp > 0:
            entry[(C, H, R)] = (dp, 1 << (7 + (N & 7)))
            fill = D
# PC-98 2HD 1232 KB: 77 cylinders x 2 heads x 8 sectors x 1024 B
CYL, HEADS, SPT, SZ = 77, 2, 8, 1024
out = bytearray()
present = 0
for c in range(CYL):
    for h in range(HEADS):
        for s in range(1, SPT+1):
            e = entry.get((c, h, s))
            if e:
                dp, sz = e
                out += d[dp:dp+sz].ljust(SZ, bytes([fill]))
                present += 1
            else:
                out += bytes([fill]) * SZ
open(dst, 'wb').write(out)
print(f'  present sectors: {present} / {CYL*HEADS*SPT}')
print(f'  fill pattern 0x{fill:02x};  wrote {len(out)} bytes -> {dst}')
assert len(out) == 1261568, f'expected 1261568, got {len(out)}'
# sanity: the BPB and the boot signature
print(f'  sector 0 head: {bytes(out[:16]).hex(" ")}')
print(f'  boot signature @510: {bytes(out[510:512]).hex(" ")}  (55aa = bootable)')

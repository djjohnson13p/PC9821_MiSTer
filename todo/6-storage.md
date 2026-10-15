# 6. Storage: IDE/ATA, FDC, CD-ROM

59. **Floppy: D88 FORMAT and 2HS/rpm media gating are not implemented.** **KNOWN GAP.** Working:
    two drives mounted and changed live from the OSD (no reset; NP2kai's media-change class), D88
    and raw images (every headerless size in NP2kai's `fdd_xdf.c` table, 2D/2DD/2HD D88 types),
    reads and writes over DMA or PIO with the result landing in the image file, raw FORMAT
    (NP2kai `fdd_formatinit_xdf`), the 2DD port window (`0xC8-0xCC`, IRQ10, DMA channel 3)
    selected by the `0x00BE` strap. Not implemented: **D88 FORMAT / WRITE ID answers IC0|NW
    (write-protected)** because it needs a track rebuild and file growth; the WRITE DELETED DATA
    mark in a D88 header; the 1.44 MB 2HS/rpm gating (the `0x04BE` rpm register's role in NP2kai's
    per-command checks); the 2D D88 track fold; FDI/DIM container headers. A READ or WRITE cut off
    by a DOR reset leaves the medium mid-sector until the next mount. Capture-pending: the
    unselected window's byte and the `0x94`/`0xCC` control byte (`ioprobe` has the rows), and
    `0x055C` with both drives powered (empty, then a diskette in drive 2).

66. **In-game disk-load latency (Touhou 5 dialogue loads).** **CAPTURE-PENDING.** The FPGA path
    is priced (`tb_pc9821_ata_th5load`, `tb_pc9821_block_hostcost`): a 64-sector sequential read
    costs ~0.16 host handshakes per sector, the per-sector-command loop ~0.19, and a write is one
    handshake per sector (host-bound: the ARM writes each 512-byte sector to the image). The
    remaining seconds look like firmware pacing: the IDE ROM's `0x01F3` settle delay (up to ~4 s
    per paying call, skipped only when work-area `0x5BA` names the drive) and the host-side HPS
    round trip. **Next:** run `idelat` on the core and compare with the machine's
    `docs/probes/IDELAT-clean.TXT`, and log `[0xDA060]`/`[0x59A]`/`[0x5BA]` at each settle entry
    during one dialogue load.

102. **The block adapter's `win_flush` window re-mount has no fail-first test.** **UNVERIFIED
    (INFERRED).** The read-ahead window is re-mounted on a flush; a stale re-mount would serve
    blocks from the wrong image silently. **Next:** a bench that fails with the re-mount broken
    and passes with it, its expected bytes taken from the image, never from the RTL.

106. **CD-ROM: what works and what is unverified.** **UNVERIFIED (INFERRED) for the NEC drivers
    named below.** The drive is ATAPI as IDE bank 1's master (the one hard disk then sits on bank
    0), with ISO and PCD images (`tools/cue2pcd.py` converts mixed-mode CUE/BIN) mounted live from
    the OSD and CD-DA audio streamed to the mixer; every answer follows NP2kai `cbus/ideio.c` and
    `cbus/atapicmd.c`, with two departures sourced from the Xe10's IDE ROM (power-on ERROR `0x01`,
    and an ERROR read that leaves STATUS.ERR set) (`tb_pc9821_atapi`). Verified on hardware:
    `NECCD.SYS` + MSCDEX read data and play CD-DA, and Policenauts runs. **Open:**
    (a) `NECCDM.SYS` and `NECCDD.SYS` are untested; (b) while a CD-DA track plays, NECCD answers
    file reads with `CDR101: Not ready` - NEC driver behaviour that matches NP2kai's drive model,
    so a game that streams data during audio cannot; (c) `PATACD.SYS` reads files but rejects the
    IOCTL calls some games make directly; (d) the CD-DA output level against a real drive, and how
    a CD-equipped Xe10 places its drive, are capture-pending; (e) booting from CD is not
    supported (no reference establishes it). CD test builds run at 75 MHz for margin
    (`--custom --clk-sys-mhz 75`): 80 MHz CD builds stalled intermittently in the Policenauts
    intro.

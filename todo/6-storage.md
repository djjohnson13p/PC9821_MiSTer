# 6. Storage: IDE/ATA, FDC, CD-ROM

59. **FDC: re-capture with both drives powered.** **CAPTURE-PENDING.** An equipped but empty
    drive answers NP2kai's `SE|NR` recalibrate, so the BIOS marks both drives present
    (`[0x55C] = 0x03`, `pc9821_fdc.sv`); the Xe10 captures read `0x01`, but drive 1 was unpowered
    when they were taken. Also uncaptured: the unselected 2DD/2HD window's byte and the
    `0x94`/`0xCC` control byte (`ioprobe` has the rows). **Done when:** `0x055C` and those rows are
    captured with both drives powered (empty, then a diskette in drive 2) and
    `tb_pc9821_fdc_conform` pins them.

66. **In-game disk-load latency (Touhou 5 dialogue loads).** **CAPTURE-PENDING.** The FPGA path
    is priced (`tb_pc9821_ata_th5load`, `tb_pc9821_block_hostcost`); the remaining seconds look
    like firmware pacing (the IDE ROM's `0x01F3` settle delay, skipped only when work-area
    `0x5BA` names the drive) and the HPS round trip. **Done when:** `idelat` on the core is
    compared with the machine's `docs/probes/IDELAT-clean.TXT`, and `[0xDA060]`/`[0x59A]`/`[0x5BA]`
    are logged at each settle entry during one dialogue load.

102. **The block adapter's `win_flush` window re-mount has no fail-first test.** **UNVERIFIED
    (INFERRED).** A stale re-mount after a flush would serve blocks from the wrong image
    silently (`pc9821_block_io.sv`). **Done when:** a bench fails with the re-mount broken and
    passes with it, its expected bytes taken from the image.

106. **CD-ROM: what works and what is unverified.** **UNVERIFIED (INFERRED) for NECCDM/NECCDD.**
    ATAPI on bank 1's master, the hard disk always bank 0's (fixed layout, owner 2026-10-11; the
    stock Xe10's and NP2kai's, `tb_pc9821_ide_layout`); answers follow NP2kai `ideio.c`/`atapicmd.c`
    (`tb_pc9821_atapi`). Hardware-verified: `NECCD.SYS` + MSCDEX read data and play CD-DA. Open:
    `NECCDM`/`NECCDD` untested, `PATACD.SYS` rejects some IOCTLs, the CD-DA level against a real
    drive, no CD boot. **Done when:** the NEC drivers are run and the level is captured.

# 6. Video: display, GDC/CRTC raster, drawing

62. **PEGC 256-colour: the display works, the plane engine does not.** **KNOWN GAP (partial).**
    Implemented: the `0xE0000` register file, the banked windows and the flat aperture over the
    512 KiB packed VRAM in SDRAM, the packed 640x400 8bpp scanout with page flip through the
    SCROLL start word, the 256-entry palette, and masked SDRAM byte writes fast enough for a full
    frame (`tb_pc9821_pegc_scanout`, `tb_pc9821_pegc_scan_dot`, `tb_pc9821_pegc_store_rate`). DOOM
    runs in 256 colours (`docs/probes/PEGC.TXT` shows it enters the mode by its own port writes).
    **Not implemented:** the PEGC plane engine (`0xE0104-0xE0118`; plane mode reads open bus), and
    the firmware/diagnostic PEGC paths. Open divergences: the palette read-back (NP2kai vs MAME,
    capture-pending), and NP2kai's packed line wrapping at `LOW15` within a line where the core
    continues into the next page (MAME agrees with the core). The engine has no single trusted
    reference (NP2kai disclaims it, MAME and QEMU disagree), so building it needs an
    evidence decision first.

63. **Most GDC2 (graphics GDC) drawing commands are accepted but not executed.** **KNOWN GAP
    (partial).** Implemented: SCROLL and display control, and the WRITE family (`0x20-0x3F`: WDAT,
    VECTW, CSRW, WRITE) through the GRCG/EGC/plain paths, with the machine's own cursor advance
    (`tb_pc9821_gdc2_write` replays the ITF's GVRAM pattern test and the conformance capture's
    WDAT rows). **Not implemented:** FIGD line/rectangle/arc/circle drawing, the CURD read-back's
    five-byte shape, and the FIFO/drawing-busy timing. The GDC conformance suite's capture
    (`docs/probes/gdc-conformance/`, re-derived by `tools/gen_gdc_compare_vectors.py`) lists the
    rows the Xe10 passes and the core does not, by class (`WDAT_WORD`, `FIGD_ROP`, `ADDR_PLANE`,
    `CURD`, `CURS_MASK`, `MASK_ORDER`, `DOT`, `MASK`, `FIFO_TURN`, `STATE`). Software that draws
    with the GDC itself rather than through the CPU, GRCG or EGC renders incompletely.

68. **The `pixel_ce` video chain is multi-cycle but not constrained as such.** **KNOWN GAP (by
    design).** The chain only changes on the pixel enable, but there is no safe SDC multicycle
    selector for it, so it is timed as single-cycle. **Next:** leave unless a safe selector is
    found.

85. **GDC SYNC raster residuals.** **UNVERIFIED (INFERRED).** The raster is guest-programmable:
    `pc9821_crtc.sv` derives the totals, active area, porches and VSYNC width from the master
    GDC's eight SYNC bytes with NP2kai's `gdc_updateclock()` arithmetic and its 24 kHz clamp
    (`tb_pc9821_gdc_sync_raster`). Residuals: (a) the clamp does not rescale the active counts
    the way NP2kai does (identical for every in-range block); (b) the 15 kHz and 31 kHz modes are
    not modelled - this is a 24 kHz machine; (c) the slave GDC's own SYNC block drives nothing
    (NP2kai derives from the master only), unverified against the chip. **Next:** capture the
    SYNC bytes other titles program (trap the eight bytes after an `out 0x62,0Fh`).

113. **GRCG presentation bubble: a timing fix that costs one clk_sys per GRCG store.**
     **DECISION (OWNER).** Presenting the GRCG's latched form (and a registered capture pulse)
     takes the route decode off the GVRAM write-enable's worst `clk_sys` cone and improved the
     worst draw in a 4-seed A/B on an older tree; a build behaved identically on hardware. The cost
     is +1 clk_sys per GRCG store (a fixed cycle, so its time scales with the clock), which the
     GVRAM latency contract tolerates (it is a floor: faster than the machine is legal).
     **Remaining to land:** re-pin `tb_pc9821_gvram_porta_equiv`'s stream model by +1 cycle on the
     GRCG presentation cycles, re-measure at 80 MHz, and enforce the period as a time rather than
     a cycle count.

# 6. Video: display, GDC/CRTC raster

85. **GDC SYNC raster residuals.** **UNVERIFIED (INFERRED).** `pc9821_crtc.sv` derives the
    raster from the master GDC's SYNC bytes with NP2kai's `gdc_updateclock()` arithmetic and its
    24 kHz clamp (`tb_pc9821_gdc_sync_raster`). Open: (a) the clamp does not rescale the active
    counts as NP2kai does (identical for every in-range block); (b) the slave GDC's SYNC block
    drives nothing, unverified against the chip. **Done when:** the SYNC bytes other titles
    program are trapped (the eight bytes after `out 0x62,0Fh`) and any out-of-range or
    slave-only case is either matched or shown not to occur.

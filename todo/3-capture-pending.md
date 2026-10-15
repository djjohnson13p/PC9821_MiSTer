# 3. Capture-pending hardware questions

A software model exists, but no machine measurement settles it. Each item names the
measurement that would. Unless stated otherwise the status is **CAPTURE-PENDING**. The
probes are in `tools/hwprobe/`; a missing probe has to be written (run it on the core
first, then on the machine).

15. **Analog palette register width and mirror.** **CAPTURE-PENDING.** Is `0xA8` a full 8-bit
    index in analog 16-colour mode, and do `0xAA/AC/AE` return the full 8-bit DAC byte or a 4-bit
    nibble (and which nibble)? The existing read-back capture ran in digital mode, so it does not
    settle this. The read-back mirror is 16 entries, seeded zero-extended. **Next:** switch to
    analog mode (`0x6A`), write and read the palette registers, restore `0x6A`; if the registers
    are write-only, measure the DAC output on screen instead.

16. **`0xA8` width test in analog mode.** **CAPTURE-PENDING.** Part of item 15: write `AB`,
    read back `AB` (8-bit index) or `0B` (4-bit), in analog mode.

17. **GDC `mode1` (`0x68`) read model.** **CAPTURE-PENDING.** The DOS-prompt read is `0x18`;
    NP2kai's reset value is `0x98`, which the RTL seeds. The open question is the read model
    (raw latch, encoded, or `0x18`), not the power-on value. **Next:** a read-only `0x68` capture
    on a fresh boot, before and after a known mode write.

18. **OPNA `0x18E` read with extended select `0x0F`.** **CAPTURE-PENDING.** Four candidate
    answers: QEMU returns `0x80`; NP2kai the register shadow `s.reg[0x10f]` (`0x00` at reset);
    this core the ADPCM-B data bus; the YM2608 die-shot model (nukeykt's YM2608-LLE,
    `fmopna_impl.c`) the internal bus echo of the last byte written to any port (so
    `write 0x188=0x0F; read 0x18A/0x18E` would return `0x0F`). **Next:** `opnapro`'s extended
    rows, as reset and after a `5A` marker write.

19. **OPNA status-2 (`0x18C`) timer bits: masked by the `0x110` flag register or not?**
    **CAPTURE-PENDING.** QEMU masks bits 1:0 (`fmopn.c`); NP2kai does not (`opna.c`); the RTL
    follows NP2kai. **Next:** `opnapro` with `0x110 <- 0x1F` against its control row; identical
    rows mean unmasked.

20. **`0x18A` read after `0x188 = 0x0F` / `0x08`.** **CAPTURE-PENDING.** A stable `00` is
    NP2kai's reset shadow; `FF` is the SSG-register-15 / ADPCM-B-level seed; two different
    reads mean a data bus is advancing. **Next:** `opnapro`.

21. **`0x0433`: IDE connect flag or IRQ-pending?** **CAPTURE-PENDING.** The RTL follows
    NP2kai's connect-flag form (`device_present ? 0x02 : 0x00`). The only capture (`0433=00`,
    bank 0, no drive) does not discriminate. **Next:** read `0x0433` with a drive present on the
    selected bank, and with an IDE interrupt pending.

22. **CRTC horizontal porch split.** **CAPTURE-PENDING.** The raster is guest-programmable and
    follows NP2kai's field mapping (`pc9821_crtc.sv`, `tb_pc9821_gdc_sync_raster`): for the
    power-on SYNC block, active 640, front porch 128, sync 56 and back porch 24 dots. Only the
    totals (640 active of an 848-dot line) are measured; the split is not. **Next:** scope HSYNC
    on the video output and measure the porches in dots.

23. **GDC status bit 6 (blank) duty.** **CAPTURE-PENDING.** The RTL drives a per-FRAME blank
    (~31.4 % of a frame). The machine's own 2M-sample histogram measures 23.40 %, which after the
    capture's x1.048 sampling bias is exactly 208/848 = the HORIZONTAL blank of one line - a
    per-line signal. One known consumer: Rusty's `OP.COM` waits for four bit-6 edges between
    `0xA4` page strobes (4 lines on the machine, 4 frames on the core). **Next:** sample `0xA0`
    bit 6 against a raster tick at a known offset inside a line.

24. **Game-port opposite-direction priority and discharge table.** **CAPTURE-PENDING.** With
    up+down (or left+right) both held, does the PC-9801-86/-118 game port report the minimum
    discharge (up/left wins; `pc9821_gameport.sv`) or the maximum (down/right wins; NP2kai
    `board118.c`)? **Next:** timestamped polls of the axis bits after a trigger write, for each
    direction, the two opposite pairs and idle, with a real joystick.

25. **EGC 3-byte unaligned store order.** **UNVERIFIED (INFERRED) - optional cross-check.** The
    RTL decomposes an unaligned 3-byte beat into byte units, as NP2kai `memegc.c` does
    (`tb_pc9821_egc_width`, `tb_pc9821_egc_conformance`). **Next (optional):** a CPU-fed shifted
    EGC write, once as four byte stores and once as one unaligned dword store at an address
    = 1 mod 4; diff the VRAM read-back (the byte-store path is ground truth).

26. **GDC SCROLL partition walk past partition 2.** **UNVERIFIED (INFERRED).** The core walks
    partitions 3/4 and wraps to 1, as NP2kai `vram/makegrph.c` does. **Next:** program SCROLL
    (`0x70` via `0xA2`) with four distinct partition starts on the machine and photograph rows
    200-399.

27. **`0x0432` bit-7 encoding.** **CAPTURE-PENDING.** One capture answers the task file with
    bit 7 clear (`0x01` -> `0x064E = 0x50`); the RTL floats the bus when it is clear. **Next:**
    write `0x0432` in `{00, 01, 02, 03, 2A, 80}` and read `0x064E`/`0x0640`/`0x074C`/`0x074E`
    after each (`ideprobe` is the natural home).

28. **`0x043F` read-back encoding.** **CAPTURE-PENDING.** The read is value-dependent
    (`docs/probes/EMS.TXT`: write `20` -> `C4`, `80` -> `C5`, `82` -> `C7`, `C4` -> `CB`) but
    under-determined; the firmware never reads `0x043F`. **Next:** a full write/read sweep of
    `0x043F`, then a bench.

29. **`0x074E` with another unit or head selected.** **CAPTURE-PENDING.** The machine reads
    `0x00` with the bank mapped and `0x0F` unmapped, and the RTL answers that. **Next:** read it
    with `0x064C = 0xB0` (the slave selected).

30. **`0x060` (text GDC status) bit 6.** **CAPTURE-PENDING.** As item 23 for the text GDC: the
    machine's duty is the horizontal blank (23.4 %), the core models the frame blank (~31.4 %).
    **Next:** only if a consumer appears; otherwise leave documented.

31. **`0xE0000` answering nothing.** **CAPTURE-PENDING.** Possibly a mode artefact: the
    intensity plane is reachable only in analog modes. **Next:** re-read `0xE0000` in analog
    mode before changing the memory map.

32. **Calendar (uPD4990A) bit order.** **VERIFIED (HW) - settled.** `docs/probes/TRS.TXT` holds a
    write-then-read-back of the clock that matches 6 of 6 fields, and `tb_pc9821_calendar_protocol`
    replays it byte for byte. Nothing further is owed.

33. **Drive IDENTIFY words.** **VERIFIED (HW) - landed.** The machine's 256-word IDENTIFY page
    is in `docs/probes/IDE.TXT` (`IDW` rows) and the core's IDENTIFY follows it, except the
    capability words the PIO-only core cannot execute (DMA/UDMA/security), which are
    deliberately not advertised (`tb_pc9821_ata_advertised`). Nothing further is owed.

34. **`0xDA000`/`0x1E8E` IDE work-RAM gate.** **VERIFIED (HW), one residual.** `DA000-DBFFF` is
    RAM only while `0x1E8E` bit 0 is set (`docs/probes/SHADOWW.TXT`); gate-off reads `FF` and
    drops stores, and the RAM survives. `DC000-DFFFF` reads `FF` with the gate clear
    (`docs/probes/SHADOW.TXT`). **Next:** the gate-ON state of `DC000-DFFFF` (modelled as `FF`):
    write a marker at `0xDC000` with `0x1E8E = 0x81` and read it back.

35. **`0x989x` write behaviour.** **CAPTURE-PENDING.** Only reads are captured
    (`0x9894/0x9892 = 0xF0`; `0x9890/0x9896/0x98E0` read `FF`). **Next:** an opt-in write-then-read
    of those ports.

36. **`0x6C` and the `0x60-0x6F` decode.** **CAPTURE-PENDING.** `0x6C` is the last port a guest
    hits that nothing answers; the decode skips `0x66` and `0x6C`. **Next:** read `0x60-0x6F` on
    the machine.

37. **CG window even offsets.** **CAPTURE-PENDING.** NP2kai reads the low page for even
    offsets, QEMU round-trips them, the RTL drops the write and reads zero. **Next:** capture
    reads and writes of consecutive offsets across the `0xA4000` window.

38. **OPNA ADPCM-B over the data bus.** **UNVERIFIED (INFERRED).** The external ADPCM-B RAM is
    not fitted (`adpcm_din = 8'h00`) but the register-0x08 bus-fed path is wired, so a bus-fed
    ADPCM-B stream may not be silent. **Next:** a bench driving the bus-fed path; if a title uses
    it, this is a real subsystem gap.

40. **PCM86 and the 8237 DMA.** **UNVERIFIED (INFERRED).** Whether PCM86 playback can be fed by
    DMA is unconfirmed. **Next:** read NP2kai `sound/pcm86c.c`, and a capture if needed.

94. **Software-DIP store: the machine's own post-POST state.** **CAPTURE-PENDING.** Both
    configuration stores (the 24-byte software-DIP bank at `0x841E-0x8F1E` and the CG-RAM
    record at `0x810-0x81D`) are re-seeded from the power-up image on every machine reset, and
    the record cells are a static read-only view with a write-through read echo, so the ITF's
    marker/sum check passes for either model (`tb_pc9821_pram`, `tb_pc9821_cg_read_path`,
    `tb_pc9821_iobus`). The price: a guest SETUP change does not survive a reset on the core,
    where the machine's battery-backed store keeps it. Two machine facts are still unmeasured:
    (a) the core ends a boot with `0x851E = 0xE3` (the firmware's merge with port `0x31`) where
    the machine reads `0x02` (`docs/probes/PORTS.TXT`), i.e. whether the machine drops that data
    write; (b) whether the ITF's KANJI CG RAM test (POST stage `1A`) leaves the record at code
    `0x2056` wiped or intact on the machine. **Next:** `probe2 /RDBACK` on `0x851E`, and one read
    of code `0x2056` rows `0..0xD` after a warm reset on a Xe10.

97. **The `0x0461` window's page 0/1: alias or hole.** **CAPTURE-PENDING.**
    `docs/probes/WIN.TXT` reads the window base as `0xFFFF` with page 0 selected, where the core
    maps the window onto RAM at `0x00000`. Either the machine has no page-0 alias or the word
    really is `0xFFFF`; the capture cannot separate them. **Next:** read the word at physical
    `0x00000` directly, then with `0x0461 = 0x00` read it through the window at `0x80000`, then
    restore `0x0461 = 0x08` (refuse when the probe's own code sits in pages 8/9). Equal reads mean
    the alias is real; `0xFFFF` means pages 0/1 are a hole.

98. **`0x043B` bit 2: the 15-16 MiB system space's polarity.** **CAPTURE-PENDING.** `sys16m_en`
    (`0x043B` bit 2) switches the PEGC window at `0xF00000`, the `0xF80000-0xF9FFFF` hole and the
    `0xFA0000-0xFFFFFF` mirror. Every capture only reads `0x043B` (`WIN.TXT`, `RDBACK.TXT`); the
    RTL's polarity is from NP2kai `io/necio.c` and QEMU's `pc98-mem.c`. **Next:** with A20 open,
    read `0xA0000`/`0xF00000`/`0xF80000`/`0xFA0000`/`0xFFFFFF` through a flat (unreal-mode)
    segment, flip bit 2, read again and restore; add a bit-3 control in case bit 2 is not the
    live bit (`memmap` and `a20map` already carry the unreal-mode code).

99. **Machine settings the OSD cannot yet offer.** **CAPTURE-PENDING.** Three settings are left
    out of the OSD for want of a reference: (a) the SETUP item -> (software-DIP index, bit) map -
    the Xe10's SETUP menu calls one accessor per DIP index (`BANK3@0x21ED-0x230F`) but its item
    descriptor table is not decoded; (b) the mouse-interface mode, `sdip[2]` bit 5, which the
    ITF copies to port `0x7FDB` bit 6 (NP2kai `mouseif.c` models it; the core's mouse ignores it);
    (c) the chipset feature select, `sdip[2]` bit 4, which the ITF writes to port `0xF4` (the core
    decodes `0xF4` as a read-only `0xFC`). Also open: a PC-speaker volume setting that preserves
    the DIP byte's bit 5 mirror and bit 7 parity. **Next:** decode the SETUP item table; capture
    `0x7FDB` and `0xF4` on the machine with each bit clear and set.

110. **The DIP store's write-side parity bits.** **CAPTURE-PENDING.** The ITF's repair installs
    its factory DIP tables (`BANK4@0x480C`/`0x4818`) through the port writes; the store now lets
    those writes set each register's parity bit (only `0x841E` bit 1 is withheld), supported by
    the firmware's own parity-bit writers and `docs/probes/RDBACK.TXT`. **Next:** `probe2 /RDBACK`
    at `0x8B1E` and `0x881E` (write `0x7F`/`0xDC`, read back); if the machine masks those bits on
    write, the RTL change reverses.

112. **Memory-switch cell `0x79` at a second RAM size.** **CAPTURE-PENDING.** Cell `0x79` holds
    the extended-memory size in MiB; the only measurement is `0x1E` on a 32 MiB Xe10 (total - 2).
    The core answers total - 2 at every size (`pc9821_iobus.sv` `msw_79_strap`, `0x0E` at the
    16 MiB default). **Next:** a read-only `probe2 /MEMSW` on a machine with a different installed
    size (or the SETUP screen's extended-memory value beside the cell read).

114. **Masked-request withdraw on the acking access: IRQ15 still unmeasured.** **VERIFIED (HW),
    one line open.** `irqwd` (`docs/probes/IRQWD.TXT`) measured: IRQ0 clears while masked when
    the PIT output falls; IRQ1 (keyboard, `0x41`) and IRQ9 (IDE, `0x64E`) withdraw on their acking
    reads; IRQ12 holds; IRQ2 holds (`VSYNC.TXT`). `pc9821_pic`'s `WD_MASK` implements exactly
    those lines (`tb_pc9821_pit_irq_clear`, `tb_pc9821_irq_withdraw`). IRQ15 (calendar, `0x128`)
    did not trigger because the calendar interrupt was not enabled. **Next:** enable the calendar
    interrupt and re-run `irqwd`'s IRQ15 section. IRQ12 and IRQ2 must stay pure edge.

121. **IDE bank placement under Linux's `pc98ide` driver.** **CAPTURE-PENDING.** The Linux/98
    IDE driver (`pc98_ide.c`) writes `0` to `0x432` and identifies units on bank 0 only. In the
    default build the CD-ROM is bank 1's master and the disk bank 0's, so the driver finds the
    disk. In a `--no-cdrom` build the one disk sits on bank 1, as `docs/probes/IDE.TXT` measured
    on a Xe10 whose disk is on the second connector, and that driver finds nothing. **Next:** boot
    the same Linux image on a Xe10 with its disk on the second connector: if it finds the disk,
    the `0x432` bank model is wrong; also check that it lists only `hda`, and run `ideprobe` in
    that setup.

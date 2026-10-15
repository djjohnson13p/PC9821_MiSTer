# 2. Probe corrections and re-runs

Measurements whose first capture was invalid or incomplete. The probes are in
`tools/hwprobe/`; the captures in `docs/probes/`.

10. **The PIT channel-0 divisor read, and one-byte write retention.** **CAPTURE-PENDING.**
    `probe2 /PIT` originally self-rejected (`docs/probes/PITPH.TXT`): its own raw-byte read moved
    the 8254 read phase (NP2kai `io/pit.c`: `latchcmd`, `pit_getstat`, `pit_setflag`). The fixed
    probe re-calibrates the byte order and prints `coherent pairs = ACC/TRY`; its re-run
    (`docs/probes/PIT-fixed.TXT`) reads a coherent but out-of-range `divisor = FFE5`, i.e. a
    stable read artifact, not a tear. The PIT *rate* does not depend on it: the PIT:ARTIC ratio
    is 8:1 (the documented 2.4576 MHz), and the firmware's own channel-0 program (control word
    `0x36`, divisor `0x6000` with BIOS work-area `0x0501` bit 7 clear, as every capture shows)
    gives 100 Hz; the sound drivers' tick follows port `0x42` bit 5 (`0x94` measured, divisor
    `0x00F6`), which `tb_pc9821_pit_driver_rate` pins. **Still open:** (a) a coherent in-range
    scan that explains `FFE5`; (b) whether a one-byte write retains the other count byte - QEMU
    `hw/timer/i8254.c`, NP2kai `io/pit.c` and MAME `pit8253.cpp` zero it, this core retains it.
    No probe timing uses the divisor. **Next:** re-run `probe2 /PIT` on a fresh boot; its
    Experiment 2/3/4 rows answer (b) once the scan gate passes.

11. **VSYNC delivery while in service: held and delivered at the EOI.** **VERIFIED (HW) -
    answered; kept for its citations.** The first `/VSYNC` run left IRQ2 masked and proved
    nothing; the fixed section unmasks it for its window and restores the IMR. On the Xe10
    (`docs/probes/VSYNC.TXT`) `VC hold` reads `irqs_pre_eoi=0 irqs_post_eoi=1 irqs_next_edge=1`:
    an edge that arrives while IRQ2 is in service is **held and delivered at the EOI**, which is
    this core's `ir_latch` model (NP2kai `io/pic.c` discards it and defers to the next frame,
    which is wrong for this machine). `VA idle`/`VB load` read `frames=30 irqs=30` - no dropped
    VSYNC interrupts. Nothing further is owed.

13. **GDC light-pen (LPEN) read-back needs a repeat before it is trusted.** **NEEDS
    RE-VERIFICATION.** One capture: master `C0` popped `FF FF FF`; slave `C0` popped
    `00 00 F0`; slave `E0` popped `28 40 F8 01 00`. NP2kai and the RTL expect zero LPEN slots,
    and the slave's `F0` may be live pen/beam state rather than a constant. **Next:** repeat the
    LPEN reads at several reset/frame positions (`probe2`'s GDC section); only then decide
    whether to change the model (item 44).

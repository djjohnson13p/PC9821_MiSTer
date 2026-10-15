# 2. Probe re-runs

Measurements whose first capture was invalid or incomplete. Probes are in `tools/hwprobe/`,
captures in `docs/probes/`.

10. **PIT channel 0: one-byte write retention and the `FFE5` divisor read.** **CAPTURE-PENDING.**
    After a one-byte count write this core keeps the other count byte; QEMU, NP2kai and MAME
    zero it. `docs/probes/PIT-fixed.TXT` also reads an out-of-range `divisor = FFE5`. **Done
    when:** a fresh-boot `probe2 /PIT` run passes its scan gate and its Experiment 2/3/4 rows say
    which retention the machine has; `pc9821_pit.sv` follows it with a fail-first bench.

13. **GDC light-pen (LPEN) read-back.** **NEEDS RE-VERIFICATION.** One capture: master `C0`
    popped `FF FF FF`, slave `C0` `00 00 F0`, slave `E0` `28 40 F8 01 00`; NP2kai and the RTL
    return no LPEN bytes. **Done when:** a repeat at several reset/frame positions (`probe2`'s
    GDC section) shows whether the bytes are constants or live beam state; only then change
    `pc9821_crtc.sv`/`pc9821_gdc2.sv`.

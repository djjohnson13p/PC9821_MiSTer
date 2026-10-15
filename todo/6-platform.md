# 6. Platform: CPU, I/O bus, clocks, fitter

64. **The serial port (8251 at `0x30`/`0x32`) is not modelled.** **KNOWN GAP.** NP2kai models
    it; this core does not, so serial-port software (terminal programs, serial mice, links) sees
    no device. **Next:** decide whether it enters scope.

67. **Faster `idiv`.** **NEEDS RE-VERIFICATION.** An old profile put `idiv` at ~30 % of a sprite
    stall; it is a performance figure, not a correctness claim. **Next:** re-profile on the current
    tree before optimizing (CPU changes go to the z486 fork first).

79. **Upstream `pll_hdmi` negative slack.** **KNOWN GAP (upstream).** The failing paths are in
    the framework's scaler (`sys/ascal.vhd`), not this core, and are positive on some fitter seeds
    and negative on others. `sys/` is frozen; report it upstream.

82. **I/O access cost per port class: machine bus time or the shortest stall.** **DECISION
    (OWNER).** The machine's per-class costs are measured (`docs/probes/IO.TXT`, against the
    1621 ns `0x5F` anchor): default class ~824 ns, IDE PIO data ~824 ns, graphics GDC ~676 ns,
    text GDC ~444 ns, EGC named ~372 ns, EGC register file ~4720 ns (even addresses 8.6-9.4 us,
    odd ones ~825 ns). The `min` I/O-latency profile (the default) charges the FSM floor
    (`IO_MIN_HOLD`, a few clk_sys) for every class except the two the firmware needs for
    correctness: the `0x5F` wait (1621 ns, in both directions) and the 8253. The `iofaithful`
    profile charges the measured table. GVRAM plane accesses are already charged the machine's
    measured time in every build (`pc9821_gvram_arb.sv`, `docs/probes/GFX2.TXT`/`GFXB.TXT`).
    **Open:** whether more classes should carry machine time by default, and the EGC file's
    address-parity split (resolve the mechanism before setting floors). `ioprobe_decode.py
    --check-rtl` compares the RTL's table with the capture.

115. **z486 micro-code: the loop-top RNI never fires, so a string REP does not retire per
    iteration.** **DECISION (OWNER) - latency-visible CPU change.** `microsequencer.sv`'s
    `rni_base` fires an `op == 1` retire only when `jump_taken_prev` is set, but a micro-jump has a
    delay slot that clears the flag before the target executes, so ~25 `op == 1` sites never
    retire (uCode 54, 56, 5C, 64, 66, E2, 16C, 17E, 21F, 228, 23C, 244, 251, 257, 266, 26B, 27E,
    292, 298, 2B9, 2BE, 4B6, 4BC, 7E0, 828). Architecture is correct today (`rep_stosd_64k`,
    `rep_stos_intr` in the z486 suite). Two fixes, different blast radius: (a) mark the delay slot
    (uCode 269 `op 7 -> 1`), or (b) let `jump_taken_prev` survive a non-jump micro-step. Either
    moves retirement timing, so it is priced (boot golden, Dhrystone, the `rep_stosd_*` programs)
    and decided as a trade (`docs/trade-candidates.md`). Changes go to the z486 fork first.

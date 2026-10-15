# 5. Owner decisions

Blocked on a maintainer decision, not on work. Latency trades live in
`docs/trade-candidates.md`, not here.

53. **z486 reset-state divergences.** **DECISION (OWNER).** `CR0` resets to `0x00000010` (the
    datasheet says `0x60000010`); `idt_limit`/`gdt_limit` reset to `0x003FF` (datasheet `0xFFFF`).
    The CR0 half is the z486 parameter `RESET_CACHE_DISABLED` (0 today); check the CR0 the ITF
    leaves at the DOS prompt before choosing 1. The limit half is a z486 fork change
    (`segmentation_unit.sv`) plus a passing suite. **Decision:** the parameter, and the limits.

56. **HELP key held through boot.** **DECISION (OWNER).** The framework never reports a key that
    is already down when the core starts, so holding HELP through a boot (SETUP entry) does
    nothing. **Decision:** synthesise the event / add an OSD option, or document it in README's
    known issues.

82. **I/O access cost per port class: machine bus time or the shortest stall.** **DECISION
    (OWNER).** The machine's per-class costs are measured (`docs/probes/IO.TXT`, against the
    1621 ns `0x5F` anchor). The default `min` profile charges the FSM floor except for the `0x5F`
    wait and the 8253; `iofaithful` charges the measured table (`pc9821_iobus.sv`;
    `ioprobe_decode.py --check-rtl` compares them). **Decision:** whether more classes carry
    machine time by default; the EGC register file's address-parity split (even 8.6-9.4 us, odd
    ~825 ns) needs its mechanism resolved before any floor is set.

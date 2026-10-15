# 1. RTL changes ready to implement from machine captures

A capture in `docs/probes/` measures the behaviour and the RTL disagrees with it. Implement
with a fail-first bench whose expected value cites the capture line.

118. **`0xF6` read-back with A20 masked: the Xe10 reads `5E`, the core `5F`.** **VERIFIED (HW).**
   `docs/probes/A20MAP-XE10.TXT`: `0xF6` reads `5E` with A20 masked and released alike; only
   `0xF2` bit 0 tracks the gate. `pc9821_iobus.sv` returns `{7'b0101111, ~a20_enable}`.
   **Done when:** `0xF6` reads the constant `5E`, the gate state shows on `0xF2` only, and a
   fail-first `tb_pc9821_iobus` check pins it.

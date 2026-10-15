# 1. RTL changes ready to implement from machine captures

Each item here is **VERIFIED (HW)**: a capture in `docs/probes/` measures the behaviour and
the RTL disagrees with it. Implement with a fail-first bench whose expected value cites the
capture line.

3. **`0x9A8` is a real latch, not a constant.** **VERIFIED (HW).** The read-back sweep
   (`docs/probes/RDBACK.TXT`) reads `00`, then after writing `01` reads `01`, and after the
   restore reads `00` again. `pc9821_iobus.sv` answers a constant `0x00`. **Next:** add the
   latch (reset value `0x00`, the measured as-found byte) and a fail-first `tb_pc9821_iobus`
   check; the width (1 bit or a byte) needs one more write with high bits set.

118. **`0xF6` read-back with A20 masked: the Xe10 reads `5E`, the core `5F`.** **VERIFIED (HW).**
   `docs/probes/A20MAP-XE10.TXT`: `0xF6` reads `5E` with A20 masked and released alike; only
   `0xF2` bit 0 tracks the gate. `pc9821_iobus.sv` returns `{7'b0101111, ~a20_enable}`, i.e. `5F`
   while masked. **Next:** make `0xF6`'s read the measured constant `5E`, keep the gate state on
   `0xF2` only, with a fail-first `tb_pc9821_iobus` check.

# Timing: where the critical paths are

The core runs past timing closure at every preset (see AGENTS.md, "Timing and area facts"). This
page records where the clk_sys critical paths are on the matched-clock tree (SDRAM controller on
clk_sys, gated-clock CPU throttle, CD drive built in) and which cuts are known to be free in cycles.
It was measured by a path census over 8 fits (4 seeds at 80 MHz `base`, 4 at 85 MHz `--custom
--clk-sys-mhz 85`, one source); worst-corner clk_sys WNS was -6.99..-8.19 ns at 80 MHz and
-8.08..-8.95 ns at 85 MHz, with 4,180-4,191 of 4,191 LABs used (one 80 MHz seed failed to place).

## Always load the SDC before a timing query

A `quartus_sta` session must run `create_timing_netlist; read_sdc; update_timing_netlist` before it
reports anything. A raw `quartus_sta -t` session auto-derives clocks, mis-relates the PLL outputs and
reports phantom cross-domain "worst paths". STA names the PLL outputs `general[0]` (clk_sys: the
platform, the SDRAM controller and, through the `cyclonev_clkena` gate, the CPU) and `general[1]`
(the SDRAM pin clock, from which the SDC derives `PC9821_SDRAM_CLK`).

Read slack at the worst corner: the fit summary reports the slow 100 C model, and the slow -40 C
corner was up to 0.31 ns worse in 3 of 8 fits.

## The tools

- `tools/timing/census.tcl` runs as `QUARTUS_POST_STA_TCL` in a `tools/build.py` or
  `tools/seed_sweep.py` fit (set the variable to the script's absolute path). It loads the SDC and
  writes `output_files/census/` beside the fit: one worst setup path per endpoint for the 4,000 worst
  clk_sys endpoints at the worst corner (`ends_sys.rpt`), the worst hold endpoints, every SDRAM I/O
  path at all four corners, a per-corner summary (`corners.txt`), and `keepdb.tar` (the fitted
  database, so later queries need no re-fit).
- `tools/timing/census.py table|ladder|skew|show|families ENDS_RPT...` classifies every endpoint into
  the cones below, prints each cone's gap to WNS per fit, the WNS "ladder" as cone groups are deleted,
  and clock skew by launch/latch domain. `tools/timing/p0.py ENDS_RPT...` measures the shared
  memory-map prefix (P0). `tools/timing/pathchain.py RPT` parses a `report_timing` file into node
  chains.

## Where the paths are

**The limiter is the platform's memory-map decode, not the CPU.** In most draws the worst slack is set
by one shared prefix, P0: the CPU's `bus_unit.ext_addr_r` -> `peg_high` / `bios_top` /
`sys16m_mirror` (`pc9821_memory_subsystem.sv`) -> `eff_addr` -> `win0_moved` -> `pc9821_memory_map`'s
`d_addr` -> `mem_addr` (a wide mux of base + offset adders) and then one of three consumers:

- **C5**, the PEGC store buffer's address match (`match_idx`, fan-out ~85) -> `ent_data`/`ent_be`
  (the limiter in 4 of 8 fits);
- **C7**, `gvram_window` -> GRCG -> the GVRAM arbiter -> the GVRAM M10K write decode (1 of 8);
- **S2**, the SDRAM controller's arbiter (`arb_pick`/`take_id`) -> `rc_of`'s next-row increment ->
  `rc_chip_buf`, a new rung since the controller moved onto clk_sys (+0.7..+1.6 ns behind WNS, never
  the limiter).

P0 carries 30-356 of the endpoints within 1 ns of WNS in every fit, and the decode from the
`ext_addr_r` launch to the last memory-map node takes 5.7-11.0 ns of a ~19 ns data path, mostly
routing. `ext_addr_r`'s own D cone has +0.8..+1.7 ns of margin over WNS.

Two platform arithmetic cones are occasional limiters, both long carry-chain series: **V1**, the CRTC
raster roots computed combinationally from the guest's SYNC block every cycle (`v_sync` -> `HTOTAL` /
`HACTIVE` / `HFP` adders -> `in_hsync`/`in_vsync`, `pc9821_crtc.sv`), and **FD**, the FDD media seek
offset (`req_u` -> the `raw_ts` shift-add product -> `raw_off` -> `seek_off` -> the image-size compare
-> `foff`, `pc9821_fdd_media.sv`).

**The CPU cones sit behind the platform** by +0.5..+2 ns: C1 (segment limit -> request), C2 (fetch
limit -> prefetch), C4/C4x (the flag/EA/ALU forward and the load-op result forwarded into the EX
view), D2/D2s (the VIPT TLB hit -> issue/stall -> segment unit). The speculative-fetch attribute check
(+1.7..+3.3), the throttle bridge (+1.0..+2.2) and the ATAPI drive (+2.3 or further) are not limiters.
The gated CPU clock costs ~0.1 ns of extra skew on CPU -> platform paths. clk_sys hold and the SDRAM
pin I/O group are positive at every corner (the read-capture window shrinks with the clock: DQ
in-hold +0.70 ns at 80 MHz, +0.46 ns at 85 MHz).

**The ladder is flat.** In a typical draw no single cone is worth more than ~0.1-0.2 ns (C5 and C7 sit
within a few tenths of each other); removing the whole platform group (C5, C7, R1, V1, FD, S2) is worth
an upper bound of about +0.4-0.6 ns at 80-85 MHz, after which the CPU tier sets WNS. A draw can also
put ONE P0 family far ahead (+1.3 ns in one 80 MHz seed), which is what a P0 cut protects against. So
only a SET of cuts moves WNS, and the set that is free in cycles is the platform one.

## Zero-cycle cut candidates, ranked

None of these changes a cycle on any path; all must be measured with a seed sweep per side (one fit
cannot resolve them) and fit-checked for LABs, since the device is full.

1. **P0-c - splice, don't add, in `pc9821_memory_map`'s `mem_addr`.** The window bases are aligned
   (`pack_base` is one of the 1/2/4/.../96 MiB size constants, so `peg_base = pack_base + PACK_BYTES +
   0x80000` has bits [18:0] zero, and the pack-window arms add a short constant above the 1 MiB
   alignment), so `peg_base + (d_addr - 0xF00000)` is `peg_base | d_addr[18:0]` and the other arms are
   ORs too. Removes the `Add13`/`Add14`/`Add16` adders (2-3 ns on the worst P0 paths). ~0 area;
   provable by SAT over every address under the pack-size constraint (`tools/check_decode_equiv.py`).
2. **S2-a - form `rc_next_buf`/`rc_chip_buf` one cycle after the accept** from `addr_buf`, in
   `src/memory/sdram.v`. Their first reader is the row-crossing second ACTIVE, at least tRCD later.
   ~0 area; needs a proof that nothing reads them in accept+1. Worth doing only together with P0-c.
3. **V1-a - register the CRTC's SYNC-block roots** (`HACTIVE`, `HACTIVE+HFP`, `+HSYNC_W`,
   `VACTIVE+VFP`, `+VSYNC_W`, `HTOTAL`) on the same edge as the `v_sync` copy, as the existing
   `s_y_r`/`s_lf_r` seam already does. Equal at every cycle; ~60 flops (~6-7 LABs).
4. **FD-a - latch `raw_off` at the request accept** from the live request fields, as `track_q` already
   is for D88 images (`seek_off` is read only in the state after the accept). ~32 flops (~4 LABs).
5. **P0-b (a CPU change, fork first)** - predecode the address-only window classes (`peg_high`,
   `bios_top`, the `sys16m` range, `win0_in_window`) beside `ext_addr_r` from its D input in
   `bus_unit`, and AND the configuration bits on the platform side. Removes 2-3 LUT levels from every
   P0 path and spends ~1 level of `ext_addr_r`'s +0.8..+1.7 ns D-side margin; ~8 flops.

**Measured after P0-c (3b134fe4, seeds 2-7, census):** C7 (`ext_addr_r` -> the GVRAM M10K write
port, 2,231 endpoints within 1 ns of WNS) set WNS in 5 of 6 seeds; C5 had fallen to +1.8 ns behind.
Two cycle-identical cuts landed on that cone (lane timing-cones): `pc9821_memory_map` decodes every
window flag on both candidate addresses and lets `win0_moved` pick the finished flag
(`region_dec`, proven by `tools/check_memmap_addr_equiv.py`), and `pc9821_gvram_arb` forms the
first live lane, the any-live test and the merge class on each `lane_live` arm with `cap_arm` as
the last select (proven by `tools/check_seq_equiv.py`). Over seeds 2-7 against bf1b6650: C7 limiter
5/6 -> 2/6, mean gap +0.19 -> +0.82 ns, endpoints within 1 ns 2,231 -> 220; WNS mean -7.41 ->
-7.25, worst -7.96 -> -7.55 ns. The next tier is the CPU's (C4/C4x, D2/D2s, TB) and V1.

**Measured after V1-a + FD-a + P0-d (lane plat-timing, on ad9ed84c, seeds 2-7, census).** V1-a
landed in two halves: the roots (8*x, y, HACTIVE, VACTIVE, the block copy) registered on the
frame-boundary edge from the block as it arrives, and every other compare operand registered
each clk_sys from them, one clk_sys behind (harmless at the one dot it lags, proven by
`tools/equiv/crtc_geom_lag.sv`). A first form that registered the whole field map on the edge
moved the 16-level chain to `sync_live -> geom_r` and made V1 worse (-8.3..-9.4 ns): register the
roots, not the function. FD-a latches `raw_off` at the accept. P0-d gives the map the raw address
and eff_addr's arm, so the region flags and the RAM-bound compare select the translation last.
Against 895fb31c (RTL-identical base, census): V1 limiter 4/6 (worst -7.1..-8.4 ns) -> absent
from the 4,000 worst endpoints in every seed; FD -4.4..-4.8 ns -> absent; C7's worst paths no
longer start at `ext_addr_r -> eff_addr` (they start at `win0_sel != 8'h08` or the GRCG's
CPU-datum compare). C4 (CPU) now sets WNS in 6/6 seeds; with it gone (cpu-c4) the platform
tier is C7 and TB, ~0.3-1.3 ns behind.

**Measured after TB + C7-head (lane tb-c7, on b9c0cb06, 80 MHz, seeds 2-7, census).** TB: the
GVRAM arbiter's CPU response (`cpu_resp_valid`, `cpu_dout`, the line strobe) is routed by the
strobes themselves instead of the live owner mux, so the dispatch decode (`gvr_write`/`gdc_own_q`
-> `cc_owns_grcg_comb` -> `own_grcg` -> `cc_owns_plain`) left `z_din`; every term is now a register.
The plain and GRCG strobes imply their owner and the EGC strobe is never beside them
(`tools/check_arb_resp_inv.py`, induction over the real share/arbiter/GRCG/EGC; the routing's
identity under those facts is `tools/equiv/arb_resp_route.sv`). The one state where it differs
from the old mux (an EGC strobe while the live owner has left the EGC) is unreachable under the
bus handshake: z486 holds its request through the ready edge (src/z486/bus_unit.sv
`if (ready) begin`) and the throttle bridge's hold is registered (pc9821_cpu_bus_bridge.sv
`assign p_valid = c_valid && !acc_pend;`), so pc9821_gvram_share cannot grant a GDC visit before
the strobe's cycle. The cut is therefore cycle-identical to the old mux in every legal execution;
`tb_pc9821_egc_resp_owner` guards the routing with a visit granted behind the EGC read. C7-head: pc9821_iobus registers
`win0_sel != 8'h08` (`win0_sel_moved`) on the edges `win0_sel` is written (proven equal every cycle
by `tools/check_win0_moved_inv.py`; the map's outputs by `tools/check_memmap_addr_equiv.py`).
Boot golden unchanged (930544). Against b9c0cb06 (same seeds): WNS mean -5.43 -> -5.27, worst
-5.82 -> -5.66 ns (inside the placer's noise); TB gap to WNS mean +0.65 -> +1.07 ns (absent from
the 4,000 worst endpoints in one seed), endpoints within 1 ns 41 -> 4, and its worst path now
starts at `u_egc|cpu_resp_valid` (a flop) with only the `z_din` mux before the bridge; C7 limiter
1/6 -> 0/6, gap unchanged (+0.48 -> +0.46), its head moved from `win0_sel` to the arbiter's live
dispatch (`line_read -> cc_owns_egc_comb -> own_grcg`, the request side, which cannot be registered
without a cycle) and the GRCG's CPU-datum compare (`bus_unit dout -> gvr_din -> u_grcg Equal1`). No
platform cone sets WNS in any seed (limiters: C4 x2, C4x, D2s, S2, other CPU). ALMs needed 36,377
-> 36,353, LABs mean 4,127 -> 4,133 (worst 4,148 -> 4,152). The datum compare's cut is a CPU
change (register the byte-is-00/FF flags beside `ext_*_dout_r` in `bus_unit`, fork first).

Recommended order: P0-c + S2-a together, then V1-a + FD-a if LABs allow, then P0-b if the P0 rung
remains. Beyond about +0.4 ns the next tier is the CPU's, and its cuts cost cycles: the trades
(registering the store buffer's drain decision, registering `z_ready`, the EX-view forward interlock,
the issue/stall stage, the GRCG presentation register, T28) are in
[`trade-candidates.md`](trade-candidates.md).

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

Recommended order: P0-c + S2-a together, then V1-a + FD-a if LABs allow, then P0-b if the P0 rung
remains. Beyond about +0.4 ns the next tier is the CPU's, and its cuts cost cycles: the trades
(registering the store buffer's drain decision, registering `z_ready`, the EX-view forward interlock,
the issue/stall stage, the GRCG presentation register of todo item 113) are in
[`trade-candidates.md`](trade-candidates.md).

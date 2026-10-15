# Trade candidates - resource wins that cost latency or performance

The device (Cyclone V 5CSEBA6, the DE10-Nano) is **LAB-bound**: the shipping build uses all but
a few dozen of its 4,191 LABs, so area is the currency that buys every feature still missing.
Some of the cheapest area wins are paid for in **latency** or **performance** rather than in
behaviour. Those are the maintainer's call, so a contributor who finds one prices both sides and
adds a row here instead of rejecting it silently. The T-numbers are stable IDs: code cites them.

**Two rules decide what may land and what must be raised:**

- **Latency / performance trades are RAISED.** If a change costs time but the guest sees the
  same values, price both sides and add a row. Where the machine's own measured cost for that
  path is known (`docs/probes/IO.TXT` per-class times, `GFXB.TXT`/`GFX2.TXT` per-word rates,
  `IDELAT-clean.TXT`), quote it - a cost that stays **under the machine's number** is
  fidelity-neutral and the easy case to accept.
- **Behaviour changes are OUT OF SCOPE.** A value read differently (a same-cycle consumer seeing
  the previous value after an asynchronous read becomes registered), a feature removed, or a
  capture-pinned timing exceeded is not a trade, whatever the area win.

**Standing precedents** (so the question need not be re-asked):

- *Input-path latency* is cheap: host-to-core input (USB HID polling on the MiSTer) already
  varies by milliseconds, so up to ~1 ms added in the core is acceptable for area. The same
  values in the same order still apply.
- *Storage latency* is especially malleable: the real drives are slow. Prefer a cost a capture
  already bounds, and note that a stall on a device that waits on `rdy` loses no data.
- *The I/O stall budget* is selectable at compile time (`IO_LATENCY_PROFILE`; the `iofaithful`
  preset charges the machine's captured per-class times), so it is an A/B, not a debate.
- *Main-RAM latency* in the ballpark of a 486/33 on 60 ns FPM DRAM is fine.

Whole-design area numbers are noisy (placement moves ~30 LABs between seeds; synthesis
re-optimises unrelated partitions), so price a candidate **module-alone** with
`tools/res_exp_map.py` and confirm a LAB claim with a seed sweep per side.

## The table

| # | Candidate | Win | Cost | Machine's number | State |
|---|---|---|---|---|---|
| T1 | I/O stall budget: charge each port class the machine's captured time instead of the short FSM floor | 0 for the min profile (const-folds away); +28 ALMs for the faithful profile | every priced access 4.5-10x slower (~117x for the EGC file's even read) | `docs/probes/IO.TXT`, per class and direction - that is the point | **Runnable as an A/B**: `build_profile.py iofaithful`. `tb_pc9821_io_latency_profile` pins every class against the capture. The min profile already charges the machine's 1621 ns on the `0x5F` wait port the firmware's delay loops are calibrated on. |
| T2 | `pc9821_iobus`'s software-DIP store -> block memory, the two `beep_vol` banks mirrored in flops | -383 registers, ~-350 ALMs | none (class-1 read); an OSD "Reset DIPs" colliding in the same cycle with a guest write may leave one byte unchanged (the guest write wins, as before) | n/a (internal) | **Landed.** |
| T3 | z486 paging TLB array -> clocked memory, with a front end that pre-reads from the address register's next value so hits stay cycle-exact | -34 LABs, -652 ALMs, -1,285 registers, +8 M10K (measured, same source) | zero on every contract (Dhrystone, boot golden, suite); a refused live pre-read pays the pre-existing walk route (one cycle on a read, more on a write), unmeasured where it fires and never seen in Dhrystone | a real i486 pays a two-level PDE+PTE walk in external memory on every TLB miss; this pays one internal cycle on the unpredicted subset | **Landed** (now part of the z486 fork). Values protected by always-on fuses and `tb_pc9821_z486_tlb_window`. |
| T4 | EGC's two 32x32 operand buffers -> simple dual port | 0 LABs | - | - | **Refuted**: the access pattern needs two read ports. |
| T5 | Palette `disp` table -> memory (registered read) | attractive | moves a dot in the video pipeline | - | **Refused (behaviour)**: no spare pipeline stage. (The `live` table moved instead, T13.) |
| T6 | `pc9821_kbd`'s 128-entry key-state dedup array -> clocked MLAB | 275 -> 228 ALMs, 277 -> 204 registers (fit entity) | one cycle on the key event decision | n/a (input latency) | **Landed**; `tb_pc9821_kbd_pipeline` pins the depth and the ordered make/break stream. Superseded in placement by T18. |
| T7 | FDD block adapter at `BURST_SECTORS = 1` | -53 ALMs, 3 M10K back | +92 us per block | the machine's 143.2 us per sector (`IDELAT-clean.TXT`); ours stays under it | **Landed, then superseded by T9.** |
| T8 | FDD instance's read-ahead window removed entirely | -102 ALMs | as T7 | as T7 | **Superseded by T9.** |
| T9 | ONE block adapter shared by the hard disk and the floppy (`pc9821_block_share.sv`) | net -46 ALMs, -1 M10K (sharing glue costs +134 ALMs of the deleted instance's size) | the loser's completion waits for the winner's in-flight handshake | n/a: `hps_io` exposes one selected slot and one payload bus, so the core already serialized the two | **Landed**; `tb_pc9821_block_share` makes a stale-window answer a named failure. |
| T10 | `pc9821_ata`'s read-ahead prefetch removed (one sector buffer) | -15 ALMs + a sector buffer | per-sector PIO time stays far under the machine's | 143.2 us per sector | **Raised**; small, ride along with another change. |
| T11 | Drop `pc9821_ata`'s `identify_cylinders` clamp compare (the reciprocal product already saturates) | <= 4 ALMs | none | n/a | Not a trade; take it when the file is next touched. |
| T12 | `pc9821_cg`: drop the beat bypass (block RAM read at the flop form's latency) | -53 ALMs, -64 ALUTs, -35 registers (module-alone) | +1 clk_sys device wait on the first port-0xA9 read after a glyph burst; no value changes | 0xA9's class measures a median ~823 ns on the machine; one 20 ns cycle is ~2 % of it | **Landed**; `tb_pc9821_font_fetch`. |
| T13 | `pc9821_gfx_palette`'s `live` table -> three 16x4 nibble lanes in M10K | 296 -> 177 ALMs, 402 -> 261 registers (module-alone) | none (the read was already registered; `disp` untouched) | - | **Landed**; `tb_pc9821_gfx_palette` checks the copy cycle by cycle, and the post-fit netlist was simulated byte-identical for every write/copy collision offset. |
| T14 | `pc9821_opna`'s 16-byte SSG read shadow -> one M10K | -56 ALMs, -123 registers, +1 M10K | none for the guest (`io_rd_wait` unchanged) | the board's 0x18A read is the default class, ~824 ns | **Landed.** |
| T15 | `pc9821_opna`'s SSG DC-block arithmetic and the `psg * 33/16` join | ~45 ALMs | changes the SSG's zero-mean level and the FM/SSG balance the captures pin | SSG(max)/FM(max) = -8.79 dB on the Xe10 (`SNDTEST-balance-2026-09-25.txt`) | **Refused (behaviour).** |
| T16 | `pc9821_pcm86_buf`'s 4-deep 0xA46C write FIFO -> 2 deep | -46 flops (~2.5 LABs) | more `io_wr_wait` stalls under SDRAM contention (lossless) | none | **Raised, not taken.** |
| T17 | Second floppy drive: a whole second media instance (a) vs per-drive state behind one engine (b) | (b) costs +145 ALMs in `pc9821_fdd_media` and +83 in `pc9821_block_share`; (a) ~2.6x that | (b): a mount landing while the other drive is read waits for the engine to go idle (one command at most) | none (NP2kai swaps the file handle in place) | **Landed as (b)**; `tb_pc9821_fdd_two_units`. |
| T18 | `pc9821_kbd`'s key-state table MLAB -> M10K | 294 -> 266 ALMs, MLAB bits 1,024 -> 0, +1 M10K | none (attribute only) | n/a | **Landed.** |
| T19 | `pc9821_dmac`'s six per-channel arrays -> one memory word per channel | the arrays are 416 bits (~20 LABs of flops); M10K is not binding | unmeasured: the engine and the CPU register path read different channels combinationally in the same cycle, so a pre-read stage, a second port and RMW merging are needed | none (internal) | **Raised, not taken.** The live `ch_addr`/`ch_count` cannot move without changing the iobus's same-cycle register read; the `_org` pair could, for <= -50 ALMs net. |
| T20 | `pc9821_block_io`'s `BURST_SECTORS` 8 -> 16/32 | costs area (+4/+12 M10K, ~+20-50 ALMs, estimated) for throughput | at best -8 % per sector on a long stream, ~0 % at the MiSTer's own file-window law; a pattern-break tail grows ~4.4x (645 us -> ~2.9 ms) | 143.2 us per sector on the machine; ours is 97.5 us at width 8 | **Raised, not taken.** 16/32 are unbuildable today (the window's slot decode is three bits; `gen_burst_width_check` refuses > 8). |
| T21 | PEGC 256-colour store path: a posted, byte-combining store buffer on the PEGC route | ~150-800 ALMs (estimated) | must drain eagerly with bounded residency (a stale buffer is a horizontal-stripe bug) | no PEGC store-time capture exists | **Landed** as `pc9821_pegc_storebuf`; `tb_pc9821_pegc_store_rate`. |
| T22 | z486 L1 fill: answer on-chip window line reads in 4 word beats (`FILL_MODE = Z486_FILL_BEAT`) | z486 -862 ALMs (module-alone) | +3-4 clk_sys on an instruction fetch from an on-chip window (code executing from VRAM/absent space) | none | **Landed** (a line-to-beat converter at `pc9821_memory_subsystem`'s response boundary); the rebased z486 since has a single word-beat fill datapath and no `FILL_MODE` selector. |
| T23 | PEGC packed-store throughput for the shape games draw: (a) masked byte writes on the SDRAM's DQM-on-address pins, (b) a gather session that merges same-row stores | (a) near zero; (b) +135 ALMs (estimated) | (a) changes which write commands are issued; (b) none for other requesters | none in any reference (NP2kai charges no cycles) | **Landed** as same-row GATHER sessions with the byte mask on `A[12:11]` (`docs/sdram-dqm-wiring.md`); the column stream went from ~6 MB/s to above the 14.44 MB/s a 640x400 frame needs. |
| T24 | DMA/FDC cache coherency: a whole-L1 walk per DMA completion (landed) vs wiring the DMA write to z486's existing snoop port | no area change | the walk stalls the CPU up to 136 clk_sys per floppy completion; the snoop form costs none | the machine snoops per write (EADS#) | **Raised**: the snoop form is more faithful and cheaper in cycles. |
| T25 | `pc9821_fdc`'s RECALIBRATE result for an empty drive: qemu's 0x68 (now) vs NP2kai's 0x28 | none | 0x28 made the boot model pay ~150 one-second settles, when the settle loop was short-calibrated | the Xe10 marks FDD unit 0 present in `DISK_EQUIP` (0x55C = `0101`, core `0100`; `docs/probes/itf-paired-7287bed6/*/D2*.TXT`), which needs a 0x28-class answer | **Raised**: re-measure now that the min profile charges the machine's 0x5F wait (T1); 0x28 may be free. |
| T26 | SDRAM pin command word: one fabric register stage before the IO cells | +19 flops | +1 cycle per SDRAM READ transaction (~14 % fewer reads/s) | none (internal) | **Raised, second choice.** A cycle-free sibling (`rc_next`) landed first; a LOCATION-constraint placement probe was refuted. |
| T27 | z486: let the microcode's loop-top RNI fire (~25 dead `op == 1` retirement sites, the string-REP iteration boundary among them) | no area change | changes when the CPU retires at those sites (new interrupt-entry boundaries) | none captured (the REP retirement granularity is not measured) | **Raised.** No guest result moves today. Belongs in the z486 fork. |
| T28 | GRCG presentation register (`pc9821_grcg` presents the latched form) | ~0 area; a clk_sys timing win (+0.5 ns mean on an older tree) | +1 clk_sys per GRCG store (100 -> 120 ns at 50 MHz) | the Xe10's GRCG RMW store is 103.9 ns (`GFX2.TXT`, `tb_pc9821_gvram_latency`) | **Left out**: it would make a 50 MHz build slower than the machine. Revisit as an overclock-only compile-time option. |
| T29 | z486: stop forwarding ALU-load results into the EX view, with a one-cycle interlock | not priced | +1 clk_sys on a back-to-back dependent load-op pair; Dhrystone not measured | none (CPU-internal) | **Raised**: one of the near-worst timing cones at overclock. |
| T30 | z486: re-open a pipeline stage on the D2 issue/stall/TLB-hit decisions | not priced | latency on the CPU's issue path | none (CPU-internal) | **Raised**: the only route to large clk_sys gains; the named cones alone buy ~0.2 ns. |
| T31 | Framework features off: `MISTER_DISABLE_ALSA` (HPS Linux audio) and `MISTER_DISABLE_YC` (composite/S-Video) | -548 ALMs (~58 LABs, derived) | MidiLink software synths inaudible; no composite/S-Video | n/a | **Accepted**: off in every preset, re-enable with `build_profile.py --alsa` / `--yc`. |
| T32 | z486 `ENABLE_TLB_TEST=0` (TR6/TR7) and `ENABLE_HW_BREAKPOINTS=0` (DR0-DR7) | ~4+ LABs (estimated) | removes real i486 architecture | the real i486 has both | **Rejected**: real features stay. |
| T33 | `pc9821_pegc_storebuf` depth 8 -> 4 | -446 ALMs module-alone | PEGC byte stream -21 %, stride-640 column -22 % (fails the bench's rate-model floor; still 1.49x the frame need) | not captured | **Raised**: needs a PEGC store-rate capture first. |
| T34 | `GATHER_K` 4 -> 3 | -220 ALMs module-alone | column stream -12 % (passes the K=3 floor; 1.69x the frame need). With T33: 1.09x, not recommended | not captured | **Raised**: the milder of the two; same capture prerequisite. |
| T35 | Same-clock SDRAM at 50 MHz (controller on clk_sys) | -466 ALMs, -18 LABs | every SDRAM cycle doubles at 50 MHz | none for main RAM or PEGC | **Moot**: the split-clock configuration is gone; a 50 MHz build is 50/50 by construction. |
| T36 | Same-clock SDRAM at 80 MHz (80/80, no clock-domain bridge) | as T35 | store stream -19 %, read ceiling 160 -> 128 MB/s, CPU under a saturating 4-stream mix 38 -> 26 MB/s; the controller joins the over-clocked clk_sys domain | none | **Taken - the shipping build**: every latency improves (dword read -33 %, line fill -19 %), the SDRAM part's ~120 MHz limit rules out a 2:1 crossing at 80 MHz, and the bandwidth benches report rather than assert the old budgets. |

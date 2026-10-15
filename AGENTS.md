# AGENTS.md - working in this repository

The guide for contributors and coding agents. [`README.md`](README.md) is the user's view
(what runs, how to set up DOS, known issues); this file is how the tree is built, tested and
changed.

## What the project is

A PC-9821 (NEC Xe10/Xe) core for MiSTer, built on the vendored z486 CPU (`src/z486/`). It boots
the user's own NEC Xe10/Xe ROM dumps to DOS and runs Touhou 1-5, DOOM, Policenauts and other
PC-98 software. No firmware is redistributed: the ROMs, the YM2608 rhythm ROM and disk images
are runtime inputs the user supplies.

## Repository layout

| path | what |
|---|---|
| `z486_mister.sv` | the top level (CONF_STR/OSD, hps_io, video/audio out, debug UART) |
| `z486_mister.qsf`, `.qpf` | Quartus project; the qsf ends in a block `build_profile.py` manages |
| `build_profile.py` | applies a build configuration (preset + overrides); generates the PLL and SDC |
| `src/z486/` | the 486 CPU: a plain copy of its fork (see "The CPU: fork first") |
| `src/pc9821/` | the PC-98 core: system, I/O bus, memory map, CRTC/GDC/GRCG/EGC/PEGC, keyboard, mouse, ATA/ATAPI, FDC, DMA, PIC/PIT, calendar, audio, debug instruments |
| `src/opna/` | YM2608 sound: jt12/jt49/jt08, vendored from PC88_MiSTer (frozen, see below) |
| `src/pcm86/` | the PC-9801-86 PCM block |
| `src/memory/` | the SDRAM controller and its requester bridges |
| `src/soc/`, `src/common/` | shared glue |
| `sys/` | the Template_MiSTer framework, byte-identical to upstream (frozen) |
| `rtl/` | the active configuration's generated PLL (git-ignored; only `rtl/pll/pll_0002.qip` is tracked) |
| `tools/` | build, bench, lint, contract checks, firmware pack, MiSTer deploy/test, decoders |
| `tools/profile/` | the PLL and SDC templates the configuration is generated from |
| `tools/hwprobe/` | DOS probe programs that measure a real PC-9821 |
| `tools/mister/` | helpers that run ON the MiSTer (uinput keyboard/mouse) and the regression scenario example |
| `tests/pc9821/` | Verilator benches, the integrated boot/userdisk/portharness tiers, the z486 suite runner |
| `firmware/` | the in-tree diagnostic test pack (no NEC code) |
| `docs/` | port status, the single-cycle event rule, timing paths, trade candidates, Dhrystone numbers, the z486 vendoring map |
| `docs/probes/` | raw captures from a real Xe10: the source of the hardware facts benches assert |
| `todo/`, `TODO.md` | the open-work list, one file per theme; `TODO.md` is the index |

The repo root holds only `README.md`, `AGENTS.md`, `TODO.md` and the build files. Build
output goes under `.build/` (Quartus, scratch) or `tests/pc9821/build/` (Verilator); both are
ignored. Put temporary files in `.build/<task>/` or an ignored `scratch/`, never in the tree.

## Evidence: where expected values come from

Every behavioural claim, and every bench's expected value, comes from the strongest available
source, in this order:

1. real-hardware captures (`docs/probes/`) and logic-analyzer traces;
2. observations of the real machine;
3. NP2kai (the primary software reference);
4. qemu-pc98;
5. MAME / ymfm;
6. ReC98.

For a chip's internals a die-level model outranks the behavioural ones: for the YM2608B,
nukeykt's YM2608-LLE (decoded from decapped silicon) is the primary chip-internal reference,
below real captures; it stops at the chip's pins, so the board's analog stage is
capture-only. **Our own RTL and benches are never evidence of what the hardware does** -
deriving an expected value from our RTL is circular. When references disagree, follow the
higher-ranked one and record the divergence in a comment. Cite references by project and file
(`NP2kai io/gdc.c`, `MAME src/mame/nec/pc9801.cpp`); third-party source is not vendored here.

A response measured on two machines is only comparable when the capture chains are equivalent
(an analog interface and an HDMI capture are not). What survives a chain mismatch is a
within-recording ratio. Validate the analysis (windows, alignment) before blaming the chain.

## The rules that bind every change

- **Fail-first benches.** Every behavioural fix ships with a bench that FAILS before the fix
  and PASSES after, with expected values from the reference, never from our RTL.
- **The Single-Cycle Event Discipline** is mandatory for every pulse, strobe and one-shot event:
  read [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) and
  [`docs/single-cycle-event-discipline.md`](docs/single-cycle-event-discipline.md) before adding
  one.
- **Rates come from the device, not from `clk_sys` counts.** Any guest-visible time derives from
  a real frequency (the device's own clock or a guest-programmed register), so changing `clk_sys`
  cannot change it. `tb_pc9821_sysclk_invariance` checks this at two clocks. The raster comes
  from the GDC's own SYNC parameters, not constants.
- **The read-back side is the weak spot.** When touching a device register, verify what its READ
  ports return, not only what writes do.
- **One clamp at the authentic junction.** The FM+ADPCM sum clamps once where the die does
  (`jt08_acc`, the YM2608B output shifter rails at +-32768); the six-drum bus is the die's 16-bit
  wrap, not a wide sum or a saturation. The SSG leaves the chip on a separate analog pin and joins
  zero-mean through the board's coupling cap, so it is not clamped with FM+ADPCM; its level is a
  capture-derived board factor (`docs/probes/SNDTEST-balance-2026-09-25.txt`) pinned by a bench.
- **A knob that changes constants is a compile-time parameter, not a runtime mux.** One place
  decides it (`build_profile.py` writes the value into `z486_mister.sv`), it travels down as a
  `parameter`, and the unselected branch const-folds away, so having the option costs nothing in
  a build that does not use it. A bench asserts the non-default value so a dropped connection
  cannot silently fall back to the default.
- **Comments carry hardware facts and external assumptions** with their citation next to the
  claim, not narration of the next line. A `file:NNN` citation should quote a short fragment of
  the target line (`` `...` ``, `"..."` or `(...)`, at most 80 characters) so it can be checked by
  eye; nothing gates this, so re-point citations when you move their target.
- **Latency and performance trades are raised, not decided by a contributor.** A change that saves
  area but costs cycles on a guest-visible path goes into
  [`docs/trade-candidates.md`](docs/trade-candidates.md) with both sides priced. A value read
  differently, a feature removed, or a capture-pinned timing exceeded is not a trade.
- **The boot golden is a canary, not a constant.** `CYCLES used=930544` moves only with a reported,
  attributed reason; it is never re-pinned silently. Its blind spots: it is VSYNC-locked at its
  endpoint (so it cannot see I/O exposure) and runs with paging off.
- **Generated files: fix the generator, then regenerate.** `tests/pc9821/bench_sources.sh`
  (`tools/gen_bench_sources.py`), the generated PLL/SDC (`build_profile.py`), and the EGC/GDC
  compare vectors (`tools/gen_*_compare_vectors.py`) are outputs. Resolve a merge conflict in the
  generator (take the union) and re-run it.
- **Never `git add -A`.** Name the paths you mean; build trees have slipped into the index that
  way before.

### Frozen and vendored trees

- `sys/` is byte-identical to Template_MiSTer. Never edit it; report bugs upstream.
- `src/opna/` (jt12/jt49/jt08) is vendored from PC88_MiSTer at the commit
  `src/opna/LICENSE-SCOPE.md` pins. Do not refactor it. A change is a marked, reference-backed
  `LOCAL CHANGE`/`LOCAL FIX`/`LOCAL PATCH` block added to that file's list of local changes, so a
  diff against the pinned upstream reports exactly that list.

### The CPU: fork first

`src/z486/` is a plain copy of the z486 fork (a curated series on upstream nand2mario/z486), and
its diff map in [`docs/z486-local-patch.md`](docs/z486-local-patch.md) is empty. CPU changes are
made in the fork FIRST, pass the fork's own release gate (`make -C tests test-release JOBS=4` in
the fork), and are then re-vendored here as a plain copy:

```
git rm -r -q src/z486 && mkdir -p src/z486
git -C <fork> archive <sha> | tar -x -C src/z486
git add -f src/z486          # every path the fork tracks
```

then the gates below. Do not edit `src/z486/` directly, not even comments. An emergency fix that
must land here first is a marked `LOCAL PATCH (PC-9821 core)` block plus a numbered entry in the
map, and it is owed to the fork. `tools/check_z486_patch_diff.py --upstream <fork checkout at the
vendored commit>` (or `$Z486_UPSTREAM`) proves the tree matches the map; without a baseline it
prints a loud SKIP (exit 2), never a pass.

The CPU contract: `bash tests/pc9821/run_z486_suite.sh` passes every program (317/317 today; the runner fails below 309), and
`make -C src/z486/tests dhrystone JOBS=4` reads exactly `254235 cy / 121837 instr / CPI 2.087`
([`docs/dhrystone-numbers.md`](docs/dhrystone-numbers.md)). A change may move these, but must
report the new values with per-change attribution.

## Firmware pack (runtime inputs)

The core loads one 1 MiB pack built from the user's dumps by `tools/build_pack.py` (layout in
`tools/pack_layout.py`; `make pack PC98_DUMPS=<dir>`). The pack, disk images and any guest
binaries are never committed (`.gitignore` covers `pc98pack*.bin`, `*.img`, `*.EXE`).

- **The YM2608 ADPCM-A rhythm image must be in the pack** (`--rhythm FILE`, or `OPNA_ADPCM.ROM`
  beside the dumps, which `--dumps` finds). A zero-filled region is NOT silence: an all-zero
  ADPCM-A nibble steps +2 per sample, so every drum becomes a loud DC-carrying sawtooth.
  `build_pack.py` warns on an all-zero region and `tools/check_pack.py` fails a pack that lacks an
  image its dump directory holds.
- The shipped rhythm image is the genuine die ROM (YM2608-LLE's `rss_rom[]` with each byte's
  nibbles swapped); the reader takes the high nibble first.

## Build profiles

`build_profile.py` (repo root) applies a configuration: clk_sys, the SDRAM pin-clock phase,
`TRACE_EN`, `PERF_LOG_EN`, `IO_LATENCY_PROFILE`, `MPU_EN`, the CD-ROM fields, the framework
features `alsa_en`/`yc_en` (off by default) and the fit technique (`AREA` in every preset: the
design is LAB-bound and `AREA` frees LABs, `docs/trade-candidates.md` T40; `--fit-technique SPEED`
for an A/B). The SDRAM controller runs on
clk_sys in every build: one core clock, no SDRAM clock-domain crossing.

| profile | clk_sys = SDRAM | note |
|---|---|---|
| `base` | 80 MHz | the default and shipping build, hardware-verified |
| `lightoc` | 80 MHz | an alias of `base`, kept so old commands keep working |
| `trace` | 80 MHz | the debug build: base + instruction-trace ring + perf telemetry |
| `iofaithful` | 80 MHz | base + the machine-timed I/O class table |
| `midilink` | 80 MHz | base + the MPU-PC98II MIDI card on the framework UART |
| `mediumoc` | 100 MHz | overclock; builds the SDRAM at CL3 (CL2 runs only below 100 MHz, `docs/trade-candidates.md` T58); CL3 stability pending hardware confirmation |
| `heavyoc` | 120 MHz | overclock at the board SDRAM's ~120 MHz limit |

Any field can be overridden or a custom configuration defined:
`python3 build_profile.py base --trace`, `python3 build_profile.py --custom --clk-sys-mhz 75`,
`--profile-file F` (JSON or TOML). `--print-config` prints the resolved configuration without
applying it; `--check` verifies the top level, the qsf record, and the generated PLL and SDC
agree; `--selftest` plants disagreements and must catch each. `tools/build.py` and
`tools/seed_sweep.py` accept the same `--profile <preset>` plus overrides.

**Every preset builds the ATAPI CD-ROM drive with CD-DA** (OSD `Mount CD-ROM`, hps_io slot 4).
`--no-cdrom` and `--no-cdrom-audio` opt out; turning the CD off is a deliberate decision, never a
fallback for a design that stops fitting. `pc9821_system`'s `CDROM_EN` parameter defaults to 0
for the unit benches; the boot golden instantiates the CD build.

**The PLL and the SDC are GENERATED** per configuration from `tools/profile/` (the PLL by
`qmegawiz` inside the Quartus container, cached under `.build/pll-cache/`; the SDRAM pin-clock
phase derived by `tools/profile_gen.py` from the SDC's own I/O model). Never edit `rtl/pll*`,
`z486_mister.sdc` or the qsf's managed block by hand: change a template or a field, and re-fit.

### The debug-UART instruments (`--dbg-*`)

Compile-time, off in every preset (the preset contract requires `dbg` empty). All of them write
records to the debug UART through `pc9821_dbg_mux` (round-robin, a grant held for a whole record),
and `tools/decode_dbglog.py` reads them all. They need `trace_en`/`perf_log_en` off (those use the
same UART).

| option | what it builds |
|---|---|
| `--dbg-cpu` (`--dbg-sample-ms N`) | a sampler: CS:EIP, mode bits, INTA counts per vector, PIC IMR/IRR/ISR, VSYNC and port events, every N ms (10) |
| `--dbg-snoop LO:HI` | a physical-address memory snoop: every CPU write and read-response beat in `[LO,HI)` (hex) |
| `--dbg-trig SPEC` (`--dbg-trig2 LO:HI`, `--dbg-arm-s N`, `--dbg-post N`) | a frozen instruction trace `{CS, EIP, SP, EFLAGS}` and its trigger: `pc:CS:EIP`, `wr:ADDR`, or `reload:ADDR`; the optional second stage freezes on the first CPU write into `[LO,HI)` after it |
| `--dbg-gdc` (alias `--gdc-log`) | the display programming log (both GDCs, the mode registers, text-attribute runs) |
| `--dbg-cd` (alias `--cdrom-log`) | the ATAPI drive's command log (`tools/decode_cdlog.py` also reads it) |

The record-length table (`pc9821_dbg_mux.sv dbg_rec_len` = `tools/decode_dbglog.py LEN` = the
emitters) is held by `tools/check_dbglog_contract.py`. The instruments are not reset by a guest
reset, so the core's reset banner can land inside a record; the decoder removes it.
`bash tests/pc9821/run_dbglog_e2e.sh` runs RTL bytes through the decoder.

## The Quartus build (podman or docker)

Quartus runs in a container: `CONTAINER_RUNTIME` selects it (default `podman`; `docker` works).
Any RTL change needs a Quartus compile - Verilator-clean is not Quartus-clean (for example,
non-ASCII in a comment fails Analysis & Synthesis).

```
rm -rf .build/quartus && python3 build_profile.py base && \
  timeout 300 python3 tools/build.py --log .build/compile.log; grep -cE "^Error" .build/compile.log
```

Zero `^Error` lines before the timeout means analysis, synthesis and map passed; the 300 s cap
does not reach the fitter. **It does not mean the design fits.** LABs are the binding resource
(4,191 on the device) and the fitter states its own requirement:

```
Error (170012): Fitter requires 4408 LABs to implement the design, but the device contains only 4191 LABs
```

so a change is judged only from a real fit: read `output_files/z486_mister.fit.summary`
(`Total LABs`, `Logic utilization (in ALMs)`) and the fitter's `170012`/`171003` lines.

- **Full fits:** `python3 tools/build.py --detach --log <log>` and read the verdict with
  `python3 tools/wait_build.py` (exit 0/1) or `.build/quartus.status.json`'s `state`/`exit`. A
  detached build survives a killed launcher. Never poll a job with `pgrep -f <its command>`: the
  pattern matches the polling shell itself.
- Each fit writes `output_files/fit-source.sha256`; two fits whose files differ only in the files
  you changed are a one-variable A/B, and you can say so.
- After an interrupted build, remove leftover containers (`podman rm -f ...`) and
  `rm -rf .build/quartus` before a diagnostic build; stale scratch masks errors. Never redirect
  build output to `/dev/null`: the verdict line and the explaining error are in it.
- **Timing queries must load the SDC:** `create_timing_netlist; read_sdc; update_timing_netlist`
  (see `z486_mister.clk_sys_top_setup.tcl`). A raw `quartus_sta -t` session auto-derives clocks and
  reports phantom cross-domain paths. STA names the PLL outputs `general[0]` (clk_sys) and
  `general[1]` (the SDRAM pin clock, which has no register endpoints); `z486_mister.sdc` names
  them.
- `tools/quartus_gui.sh` opens the GUI in the same container.

### Seed sweeps

`python3 tools/seed_sweep.py --profile <p> --count N --jobs N` (`--seeds 1,5-8` for specific
seeds, `--report` to rank, `--dir` for a fresh directory). Each seed's `summary.txt` (written last, atomically, after
`output_files/` and `metrics.json`) records an `identity=` hash of {resolved configuration, RTL source
hash, fit knobs such as `QUARTUS_FIT_SETTINGS`}; a re-run skips only seeds whose identity matches and
REFUSES (exit 1) when it finds a seed of another source/profile, instead of mixing designs in one
ranking: `--restart-stale` renames those to `seedNNN.stale-<time>` (kept) and refits, `--retry-failed`
does the same for `verdict=failed` seeds, `--trust-existing` accepts summaries that predate
identities. `--selftest` covers the logic. `--slot-dir DIR --slot-max N` (env `FIT_SLOT_DIR` /
`FIT_SLOT_MAX`) makes each seed hold a `tools/host_slots.py` slot while it fits (`--slot-all` also
counts containers other launchers started, `--max-load L` waits on host load). `tools/build.py`
refuses to start when a live build of the same tree owns `.build/quartus`. `tools/host_slots.py` caps concurrent fits on a
shared host. **Never delete a sweep's `seedNNN/output_files/`** - it is that placement's only
record (the RBF and the fit/STA reports); clean only the `seedNNN/tree/` copies.

### Fitting on another machine (`tools/remote_fit.py`)

`FIT_HOST=<ssh host> tools/remote_fit.py run --label X --slot-max N -- --profile base --seeds 2,3
--jobs 2` snapshots the working tree (tracked files as on disk, uncommitted edits included, plus
untracked non-ignored files under 1 MiB) to `<host>:~/fits/<run-id>/tree`, starts `seed_sweep.py`
there in its own session under a shared `host_slots` ceiling (`--slot-max`, default 12, with a load gate at the host's core count, `--max-load`; slots in
`~/.fit-slots`, counting every running container), waits, then rsyncs the whole `sweep/` back to
`.build/remote-fit/<run-id>/` (every `seedNNN/output_files`, `summary.txt`, `metrics.json`, logs) and
prints the ranking. Nothing is deleted on either side. `--no-wait` returns at once; `status`,
`fetch`, `report` and `list` take `--run-id` (default: the last launch); `--selftest` covers the
snapshot and argument logic. Needs keys-only ssh, python3, rsync and the container runtime on the
host (`--remote-env CONTAINER_RUNTIME=docker`). Local fits obey the machine ceiling the same way:
`FIT_SLOT_DIR=<dir> FIT_SLOT_MAX=3 python3 tools/seed_sweep.py ...`.

### Timing and area facts

[`docs/timing.md`](docs/timing.md) records where the clk_sys critical paths are (the shared
memory-map decode behind `ext_addr_r`, then the CPU cones), the ranked zero-cycle cut candidates,
and the path-census tools (`tools/timing/`, run as `QUARTUS_POST_STA_TCL` in a fit).

- **Every build runs past timing closure.** The worst cones carry ~17.2-17.8 ns of data, about
  54-55 MHz of real closure, and `base` runs at 80 MHz. The 80 MHz build's clk_sys slack lands
  around -7.4 to -8.2 ns over seeds and is stable on the boards tested. Custom clocks up to
  87.5 MHz have passed; 90 MHz depends on the seed and 95 MHz and up fail. Past about -8 ns a
  sweep's STA ranking is a shortlist for hardware testing, not a verdict.
- **Never quote a single fit.** The placer's noise floor is about 1 ns of WNS and ~30-50 LABs
  over seeds of unchanged source, so a small area or timing question needs a seed sweep per side.
  A one-fit delta must be labelled as such.
- **LABs bind, not ALMs**: ~9.2-9.5 ALMs per LAB in practice, so an ALM percentage overstates
  headroom. The design is close to the device's 4,191 LABs with the CD built in.
- **A whole-design A&S A/B is not a price**: parallel synthesis and design-wide resynthesis move
  hundreds of ALMs on a change with provably zero logic. Price a change module-alone with
  `tools/res_exp_map.py` (both variants wired to real ports; an unwired instance is pruned), or
  run the whole design with `NUM_PARALLEL_PROCESSORS 1` and say so.
- **Count flops, not declarations**: size a candidate from the fit's per-entity register count.
- Moving flops into memory frees LABs; moving an M10K array into MLAB spends LABs (a loss).
- **Silent inference traps no bench can see:** a power-up value or reset on the register that
  captures a memory read makes Quartus build the memory from LUTs; a tautological guard can let
  synthesis delete the logic it protects; a read and a write of the same RAM in one `always`
  block reads as an asynchronous port and never infers. An asynchronous read cannot move to any
  memory. Keep the `map.rpt` RAM Summary row as the evidence that a memory inferred.
- **A rewritten decode ships its proof:** `tools/check_decode_equiv.py --old <rev> --new <rev>`
  proves every changed address predicate equivalent by SAT over every free input bit (with
  `--selftest` planting known errors). Run it whenever a predicate's form changes.

## Gates (run before declaring a change done)

Run the heavyweight gates sequentially and bound their memory: `VERILATOR_JOBS=2 BENCH_JOBS=1`
for the battery, `JOBS=4` for the z486 Makefile (never a bare `-j`), and never overlap
`run_boot.sh` with `run_integrated_build.sh` (they share an object directory) or either with a
Quartus fit.

```
python3 tools/bench.py --all                 # the Verilator battery
python3 tools/check_lint.py
python3 tools/gen_bench_sources.py --check
bash tests/pc9821/run_z486_suite.sh          # 317/317
timeout 2400 bash tests/pc9821/run_boot.sh   # boot golden: CYCLES used=930544
bash tests/pc9821/run_integrated_build.sh    # compile-only: the boot, portharness, userdisk and
                                             # throttle tops the battery cannot build
make -C src/z486/tests dhrystone JOBS=4      # 254235 cy / 121837 instr / CPI 2.087, exact
```

A gate PASS comes from `tools/bench.py`'s verdict - the strict `TB_<NAME>: PASS` marker alone on
a line - never from reading simulation output. A bench must `$fatal(1, ...)` on failure (a
Verilator `$finish` after a FAIL message exits zero), and must carry its manifest claim verbatim
on ONE line; `tools/check_tests.py` enforces both. The integrated tiers are outside the battery,
so after renaming or re-parenting a module, run `run_integrated_build.sh`: a green battery says
nothing about them. `tools/bench.py` takes one bench name or `--all`.

The static contract checks take seconds and hold two files (or the tree and a claim) together -
the class of defect no bench sees:

```
python3 build_profile.py --check             # top level, qsf record, generated PLL and SDC agree
python3 build_profile.py --selftest          # and the guard can still fail
python3 tools/check_wiring.py                # bench manifest/sources/ports, reset and speaker paths
python3 tools/check_tests.py                 # every bench's structure and verdict (+ --selftest)
python3 tools/bench.py --selftest            # the runner's verdict rules on planted outputs
python3 tools/gen_egc_compare_vectors.py --check   # the EGC capture vectors are the generator's output
python3 tools/gen_gdc_compare_vectors.py --check   # and the GDC conformance clusters
python3 tools/mutate_bench.py --plan tests/pc9821/mutations.json --check-plan   # the mutation record still applies
python3 tools/check_dbglog_contract.py       # the debug-UART record table (+ --selftest)
python3 tools/check_telemetry_contract.py    # the WDG/PRF/GFX telemetry records vs their decoder
python3 tools/check_osd_contract.py          # CONF_STR vs pc9821_osd.sv vs pc9821_system.sv (+ --selftest)
python3 tools/check_port_lists.py            # every instantiation against its module's ports
python3 tools/check_route_pairs.py           # every memory-route pair named in the checks
python3 tools/check_shared_strobes.py        # every use of a shared strobe is qualified by its select (+ --selftest)
python3 tools/check_mister_layout.py         # setname / config path / pack name agree
python3 tools/check_dead_files.py            # every src/ file is named by a build list
python3 tools/check_tool_citations.py        # every cited tools/ path exists (+ --selftest)
python3 tools/check_z486_patch_diff.py       # src/z486 vs the fork at the vendored commit (+ --selftest;
                                             # exit 2 = SKIP without --upstream/$Z486_UPSTREAM)
python3 tools/check_todo_split.py            # todo/ items, the index, and every `item NN` reference
```

By hand, outside the gates: `python3 tools/check_4state_xlock.py` runs the X-lock benches under
iverilog (4-state; Verilator is 2-state and cannot show an X-lock), and
`python3 tools/check_decode_equiv.py` proves a decode rewrite.

**A bench must be able to FAIL.** `python3 tools/mutate_bench.py BENCH --file SRC --from OLD --to
NEW` plants a defect in a COPY of one source and requires the bench to fail through the gate's own
verdict rule (the unmutated control must pass first). Run it when you write or strengthen a bench,
with a defect in the code path its claim covers. `tests/pc9821/mutations.json` is the record of
mutants each named bench kills; `--plan tests/pc9821/mutations.json` re-runs it (slow: one build per
bench plus one per mutant), and an entry whose `from` text no longer matches is re-pointed, not
deleted. A bench `tools/bench.py` passes also prints no line opening with `FAIL` or `MISMATCH`.

`tools/check_tests.py` and `tools/check_tool_citations.py` carry visible, shrink-only ledgers: an
entry that stops being true fails the check, so a ledger can only get shorter.

### The userdisk instrument

`tests/pc9821/run_userdisk.sh` runs the real pack and a real disk image through the whole core in
simulation - the instrument for a guest that hangs on a real disk. Run it as
`PC98_PACK=<pack.bin> USERDISK_IMG_FILE=1 TB_ARGS="+IMG_RW +PAST_IPL ..." CYCLES=<n> bash
tests/pc9821/run_userdisk.sh <image>` (the `.mem` beside the pack comes from `build_pack.py`'s
`--mem`). `+IMG_RW` makes the image writable through an in-memory overlay, `+PAST_IPL` keeps
running after the boot sector, `+KEYSEQ`/`+KEYSEQ_N`/`+KEYSEQ_AT` type scancodes, and the traps
stop at an event: `+TRAP_CSEIP=<cs:eip>`, `+TRAP_LIN=<linear>`, `+TRAP_AFTER=<cycle>`,
`+TRAP_HITS=<n>`, `+TRAP_WIDE`, `+TRAP_RAMFILE=<path>`, `+PC_SEQ_N=<n>`. It runs ~210 k cycles/s,
so edit the image's CONFIG.SYS to reach the case directly rather than simulating a menu timeout.
Trust its PC trail and RAM dump over the trap registers, which can lag by a few cycles.

## Testing on a real MiSTer

Everything below is done over ssh; no physical access is needed. The MiSTer is a DE10-Nano
running Main_MiSTer; its SD card is `/media/fat`.

### Connecting

Every MiSTer tool takes the device from the environment:

- `MISTER_HOST` - the ssh destination, default `root@MiSTer` (a bare host name gets `root@`);
  `tools/mister_regress.py` also takes `--host`.
- Authentication defaults to the stock MiSTer root password, `1`, passed through `sshpass -e`
  (install `sshpass`). Set `MISTER_PASS` for a different password, or `MISTER_PASS=` (empty) to
  use ssh keys; `tools/mister_regress.py` also takes `--password`.
- Copy files by hand with `scp -O`: the card's sshd has no sftp subsystem, and a modern `scp`
  defaults to sftp.

### Deploying and loading a core

- `tools/mister_load.sh` provisions the card and loads the core: it copies
  `output_files/z486_mister.rbf` to `/media/fat/_Computer/PC9821Z486.rbf`, verifies the local pack
  against your dumps (`PC98_DUMPS`) and uploads it to `/media/fat/games/PC9821/`, writes the MGL
  (`/media/fat/PC9821Z486.mgl`), optionally uploads a disk image (`MISTER_IMG`, mounted as
  `hdd.img`) and floppies (`--fdd0`/`--fdd1`), then loads it. Flags: `--both`/`--machine xe`
  (firmware set), `--packs-only`, `--no-copy` (reload the installed core), `--no-image`, `--pack`,
  `--dumps DIR`, `--skip-pack-check`, `--allow-stale-pack`; `MISTER_CORE` renames the deployed
  core (use it for test builds).
- `tools/deploy_mister.sh` (`make deploy`) stages the same set into `mister_deploy/` for a manual
  copy, without a connection. `tools/mister_packs.sh` lists, stashes and switches the pack files
  already on the card.
- The MGL's setname is `PC9821`: relative paths in it resolve under `/media/fat/games/PC9821/`,
  and the core's config file is `/media/fat/config/PC9821.CFG` (`tools/check_mister_layout.py`
  holds these names together).
- **Load the MGL, not the RBF:** the MGL carries the disk and the pack. The remote-control path is
  the FIFO Main_MiSTer creates:

  ```
  ssh "$MISTER_HOST" 'echo "load_core /media/fat/PC9821Z486.mgl" > /dev/MiSTer_cmd'
  ```

  `tools/run_on_mister.sh load` does the same; `tools/run_on_mister.sh state` shows what the card
  runs and holds.
- `output_files/` is a copy destination, not a source of truth: confirm the RBF you deploy is the
  one you built (`tools/run_on_mister.sh state` prints the local RBF's sha256, the tree and RTL
  hash recorded in `fit-source.sha256` beside it, and the card's copy's sha256).

### Screenshots

```
ssh "$MISTER_HOST" 'echo screenshot > /dev/MiSTer_cmd'
```

writes the core's 640x400 frame (no OSD) as a PNG under `/media/fat/screenshots/PC9821/`; fetch
it with `scp -O`. `tools/mister_capture.sh shots TAG COUNT SECS` takes COUNT screenshots SECS
apart into `.build/dbglog/TAG-shots/`, and `tools/contact_sheet.py` tiles them into one image.

### Typing keys and clicking the mouse

The helpers in `tools/mister/` run ON the MiSTer and create a virtual input device through
`/dev/uinput` (Main_MiSTer forwards it to the core like a USB keyboard or mouse). Copy them to the
card (`scp -O tools/mister/ztype.py "$MISTER_HOST":/tmp/`) and run them there:

- `python3 /tmp/ztype.py 'dir\n'` types a string with US key positions. `\n` is Enter, `~C` is
  Ctrl+C, `~k<code>;` sends one raw Linux key code (`~k28;` = Enter). Shifted symbols use the US
  layout; `\` reaches the PC-98 YEN key; an unmapped character aborts with `unmapped: ...` rather
  than guessing.
- `python3 /tmp/zclick.py [dx dy]` optionally moves the mouse by a relative `dx dy` (in ten steps),
  then left-clicks.

Two facts make them work at all: the MiSTer is 32-bit ARM, so `struct input_event` is
`@llHHi` (16 bytes) - a 64-bit timeval layout makes Main_MiSTer silently ignore every event - and
the first events after `UI_DEV_CREATE` are lost unless you wait about 1.5 s, which both helpers
do. There is no evdev module on the card; the ioctls are issued by hand.

### The debug UART

The core's debug UART is `/dev/ttyS1` on the HPS at 115200 8N1. It carries the `trace` profile's
telemetry or, in a `--dbg-*` build, the instrument records. Use `tools/mister_capture.sh`, which
handles the traps (a second reader splits the stream; a cooked tty mangles binary bytes; a reader
must outlive the ssh session):

```
tools/mister_capture.sh start TAG      # kill stale readers by PID, set the tty raw, start capturing
tools/mister_capture.sh stop TAG       # stop it (PID verified) and report the size
tools/mister_capture.sh fetch TAG      # copy it to .build/dbglog/TAG.bin
tools/mister_capture.sh decode TAG --summary   # tools/decode_dbglog.py on the capture
tools/mister_capture.sh run TAG SECONDS        # start, wait, stop, fetch, decode
tools/mister_capture.sh status                 # who holds the tty; captures on the card
```

`tools/decode_dbglog.py CAPTURE` prints the records; `--summary`, `--bins`, `--hist`, `--trace`,
`--snoop-check` and `--gdcw OUT` select views. The CD log alone can also be read with
`tools/decode_cdlog.py`.

**The `trace` profile's telemetry** is line-based: a watchdog record per trigger plus `PRF` and
`GFX` counter lines, decoded by `tools/decode_telemetry.py` (record shapes held by
`tools/check_telemetry_contract.py`). `tools/run_on_mister.sh capture [s]`, `decode FILE` and
`boot [s]` (load, wait, capture, decode) wrap it. The byte before each watchdog record's LF says
which trigger fired, and it is the only reliable signal: `W` = a memory request is outstanding and
nothing has completed for 200 ms (the machine has stopped); `S` = no request at all for 200 ms
(halted or polling - check `T=`, `A=` and `EIP` before calling it wedged); `P` = the 2 s
heartbeat, which says nothing about progress on its own. Several fields are not what their
letters suggest; read them through the decoder.

Never `pkill -f <pattern>` on the card or here: the pattern matches the shell running it. Kill by
PID.

### The scripted regression runner

`tools/mister_regress.py` deploys a test RBF under test names, boots a patched COPY of a disk
image, drives the guest by keyboard and mouse, takes screenshots, and deletes everything it
created.

- Without `--go` it prints the plan and touches nothing. With `--go` it takes a lock on the card
  (`mkdir /tmp/zreg.lock`, owner recorded in `/tmp/zreg.lock/owner`; an existing lock aborts the
  run and names its holder), uses only names containing `zreg` (`_Computer/PC9821Z486-zreg.rbf`,
  `/media/fat/ZREG.mgl`, `/tmp/zreg/`), and removes every file it created in a `finally`, verifying
  the removal. `--keep` skips the cleanup for debugging.
- Items (`--items`, comma-separated, default all): `keymap`, `probe` (runs `INTEG.COM` from
  `tools/hwprobe/integ` in the guest and checks HDD/floppy/CD files against manifests built on the
  host from the same images), `probe-cda` (the same while CD-DA plays; needs `--cd` and MSCDEX),
  and the game items `doom`, `th05`, `rusty`, `policenauts`, `flamezap` (EGC-heavy).
- Game items run the command list in `--scenarios FILE` (JSON; the shape is
  `tools/mister/regress_scenarios.example.json`: per item `boot_wait`, `steps` of
  `type`/`wait`/`click`/`key`, `run`, `shot_every`, `max_static_s`, `min_changes`, `known_frame`,
  `config_default`). A step argument beginning with `?` marks a command not yet supplied: the
  item is skipped, never passed. Pass checks: the screen is not frozen (frame difference between
  consecutive screenshots) and a known frame is reached (difference to a reference PNG in
  `--refs DIR`); `--record-refs` writes those references from a build known to work. Reference
  frames are game output and are never committed.
- Inputs: `--rbf`, `--hdd-image` (with `--partition`, `--hdd-drive`, `--hdd-under`),
  `--fdd0`/`--fdd1`, `--cd` (`--cd-layout iso|pcd|raw`, `--cd-drive`), `--pack` (the pack already
  on the card), `--boot-wait`, `--probe-timeout`, `--uart` (capture `/dev/ttyS1` as well),
  `--out` (default `.build/mister-regress/<time>`). `--selftest` exercises the hardware-free logic.

### Several MiSTers

Every tool takes its card from `MISTER_HOST` (or `--host`), password `MISTER_PASS` (default `1`,
empty = keys), uses no known_hosts state, and keeps its local scratch per card (`.build/mister/<host>/`
for `run_on_mister.sh`, `--out` per run for the regression runner), so two runs against two cards can
overlap. Fresh cards work: missing `games/PC9821`, `_Computer`, `config` and screenshots directories are
created or listed tolerantly. `tools/mister_regress.py --lock-wait S` waits for another run's card
lock; only the lock's holder ever cleans up. `tools/mister_multi.py --hosts a,b --mode split|repeat --
<regress args>` runs one regression on several cards at once (`split` deals the items out, `repeat`
runs every item on every card), one `--out` subdirectory per card and a combined `summary.txt`.

### Rules for testing on a MiSTer

- **Test on COPIES** of disk images, never the originals: deploy a test RBF under a new name
  (`MISTER_CORE=PC9821Z486-test`), boot a copy of the image, and let the guest write to the copy.
- **Clean up afterwards**: delete every test RBF, MGL, image copy and screenshot you created.
- **Restore any configuration you change** (the core's `PC9821.CFG`, the MGLs, the pack in use).
- A MiSTer is a shared device: use the regression runner's lock (or check for one) before driving
  it, and never leave a UART reader running.
- Attribute a hardware failure to timing margin only after a timing-met lower-clock build of the
  same source fails to reproduce it over several runs.

## Real-hardware probes

`tools/hwprobe/` holds DOS `.COM` programs that measure a real PC-9821 (see its README). Build with
`make -C tools/hwprobe`; run a new probe on the core first (it must finish and restore what it
touches) before running it on a real machine; run it from a freshly booted DOS prompt with stdout
redirected, and run the SAME binary on both sides so the captures compare. Commit raw captures
under `docs/probes/` unmodified. DOS filenames are 8.3 and `.BAT` files are CRLF (`unix2dos`);
write DOS files as bytes. A probe that wraps another program must run from that program's
directory. Audio comparisons need a recording discipline: set levels before the run, keep
AGC/limiters off, and compare within-recording ratios (`tools/sndtest_plateaus.py`,
`tools/sndtest_balance.py`).

## Working with several agents (worktrees)

Parallel work runs in git worktrees inside the repo: `tools/worktree.py new|status|diff|merge
--apply|rm`, at `.worktrees/<name>` on a `lane/<name>` branch, one writer per worktree.

- **Commit incrementally**, before slow validation, with specific paths. Pass each worker an
  explicit working directory, a deadline, and an absolute path for its report.
- Workers run focused benches (`python3 tools/bench.py <name>`, one name per call), `check_lint`
  and `gen_bench_sources --check`; the integrator runs the full battery and the Quartus fits.
  Don't merge into the main tree while a gate run is in progress: it voids the run.
- Merge lanes sequentially. Conflicts cluster in `pc9821_system.sv`, `pc9821_iobus.sv`,
  `pc9821_crtc.sv`, `z486_mister.sv`, the audio chain, the `todo/` theme files and
  `tools/gen_bench_sources.py` (take the union, regenerate).
- Exclude build trees from searches: `rg -g'!build' -g'!.build' <pattern>`.
- Verilator object directories are large: prune `tests/pc9821/build/` in finished worktrees.
- A queued message does not interrupt a running tool call; kill a runaway process by PID. A lane
  waiting on its own fit or bench is not hung. Never search `/` for documentation.
- Edit hygiene: DOS files are CRLF, docs are UTF-8, and an edit and its `git commit` are separate
  steps.

## The open-work list

[`TODO.md`](TODO.md) is the index; items live one file per theme under `todo/`, with the
status-tag legend in `todo/README.md`. Item numbers are stable IDs cited as `item NN` across the
tree: never renumber or reuse one. A closed item is deleted and its number retired;
`python3 tools/check_todo_split.py` holds the files, the index and every reference together.
`todo/` holds only work still to follow up or verify (a capture whose answer would change guest-
visible behaviour, a divergence, a re-check, an open owner decision): a known limitation with no
plan goes in README's "Known issues and limitations", a latency/area trade in
`docs/trade-candidates.md`, a standing rule here - otherwise the list fills with finished history
and stops being a work list (owner, 2026-10-11).

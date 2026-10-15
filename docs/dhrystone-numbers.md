# Dhrystone 2.1 numbers - the z486 CPU

The Dhrystone 2.1 port lives in `src/z486/tests/dhrystone/`. Its whole-run result is a gate
(`AGENTS.md`): a CPU change may move it, but must report the new value with per-change
attribution.

## The contract

```sh
make -C src/z486/tests dhrystone
```

At `--iters 200` (the gate's setting) the whole run - reset, init, the Dhrystone loop and
validation - is **254235 cycles / 121837 instructions / CPI 2.087**, exactly. The run is
deterministic. The direct form, in `src/z486/tests/dhrystone/`:

```sh
python3 run_dhrystone.py --iters 200  --cycles 2000000
python3 run_dhrystone.py --iters 500  --cycles 2000000    # a second point, for the loop slope
```

The reference anchor is **~680 Dhrystone/s/MHz on a real 486** (~0.387 DMIPS/MHz, with
1757 Dhrystone/s = 1 DMIPS). The loop is 568 instructions per iteration; the per-iteration
cycle slope of the current core has not been re-fitted (the last two-point fit, on the
2026-09-27 core, was 1464 cycles/iteration = 683 Dhrystone/s/MHz, about the real-486 anchor;
the current core is faster).

## What the harness measures

The Verilator harness runs the **bare `z486` DUT on a fixed 10 ns testbench clock** with a
behavioural SDRAM-like memory model (`sdram_first_latency=5`, `sdram_gap_cycles=1`,
`sdram_write_busy=3`; `--mem-model simple` is faster). It does not read `z486_mister.sv`, the
PLL, the qsf or any build-profile setting, so **the result is profile-independent** (checked:
every profile produces a byte-identical harness binary and result). It is cycles and
instructions per Dhrystone on the simulated core - not a fitted or board-throughput number.
A Dhrystone/s figure for a profile is a linear projection (`clk_MHz x Dhrystone/s/MHz`) and
ignores the board's memory latency in core cycles, timing margin and I/O.

## History

| Date | Vendored fork commit | Cycles / instructions / CPI (200 iters) | Cause of the move |
|---|---|---|---|
| 2026-09-27 | (re-vendor) | 311296 / 121837 / 2.555 | frontend work (was 317400 / 2.605) |
| 2026-10-03 | rebased fork | 253183 / 121837 / 2.078 | upstream's i486 functional-units rewrite |
| 2026-10-06 | `041d0e1` | 253251 / 121837 / 2.079 | +74 locked A/D update in the page walker, -6 RMW_FAST refusal |
| 2026-10-07 | `4d170ec` | 254235 / 121837 / 2.087 | +984 from the merge of upstream `4bfdde0` (harness descriptors and #GP checks changed in the same merge) |

Every later re-vendor (through `ebd1879`) left it at 254235 exactly. The instruction count has
not changed since the port was added.

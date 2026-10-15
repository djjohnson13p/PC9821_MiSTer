# tests/pc9821/research — measurement benches, deliberately NOT in the gate

These are **throwaway measurement benches**. They run the real RTL and print `NOTE` lines; they do
not assert a design contract, they are not in `tools/gen_bench_sources.py`'s table, and
`tests/pc9821/run.sh` does not build them. They live here rather than under `tests/pc9821/` so the
gate's bench-count and source-table checks cannot see them and no lane has to bump a manifest to
add or drop one.

If a bench here ever grows a real regression assertion that should run on every change, move it up
to `tests/pc9821/tb_pc9821_<name>.sv` and add it to the generator's table — that is the only route
into the gate.

## `tb_pc9821_sdram_lat100.sv`

Two probes of the SAME `src/memory/sdram.v`, one at `FREQ=50_000_000` and one at `FREQ=100_000_000`,
both `FAST_GRADE=0`/`HAS_DQM=0` (the built configuration), each against `sdram_chip_model.sv`. It
measures absolute read latency (ns and cycles), per-burst amortisation, saturated bandwidth, the
four-way round-robin's worst inter-grant gap under batching, and the scanout's 80-dword line time
paced vs batched.

Run it:

```
verilator --binary --timing -O2 -Wall -Wno-fatal -Wno-PINMISSING -Wno-UNUSEDSIGNAL \
  -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET --top-module tb_pc9821_sdram_lat100 \
  --Mdir build/research-lat100/obj \
  src/memory/sdram.v tests/pc9821/sdram_chip_model.sv \
  tests/pc9821/research/tb_pc9821_sdram_lat100.sv
build/research-lat100/obj/Vtb_pc9821_sdram_lat100
```

A captured run is in `tb_pc9821_sdram_lat100.log` beside this file.

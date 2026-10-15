#!/usr/bin/env bash
# Fast subsystem measurement: run a port script against the real I/O bus.
#   bash tests/pc9821/run_portharness.sh tests/pc9821/f3-port-ranges.txt
# No firmware and no boot: seconds per question. The script grammar is in
# tb_pc9821_portharness.sv's header.
#
#   bash tests/pc9821/run_portharness.sh --compile-only
# elaborates the tier and stops - no script is read and nothing is simulated. It is the
# cheap half of the tier, and it is what catches a hierarchy rename, because this top is
# outside `tools/bench.py --all` (AGENTS.md, "the integrated benches are outside the
# battery") and a broken reference in it is invisible to every bench in the battery.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
SCRIPT=""
EXTRA=()
COMPILE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --compile-only) COMPILE_ONLY=1 ;;
    *) if [[ -z "$SCRIPT" ]]; then SCRIPT="$arg"; else EXTRA+=("$arg"); fi ;;
  esac
done
if [[ $COMPILE_ONLY == 0 ]]; then
  : "${SCRIPT:?usage: $0 <script>   (grammar: tb_pc9821_portharness.sv header)}"
fi
if [[ -n "$SCRIPT" ]]; then
  case "$SCRIPT" in /*) ;; *) SCRIPT="$ROOT/$SCRIPT" ;; esac
  [[ -f "$SCRIPT" ]] || { echo "no such script: $SCRIPT" >&2; exit 2; }
fi
RUN_DIR=tests/pc9821/build/portharness
mkdir -p "$RUN_DIR/obj"
source tests/pc9821/z486_rtl.sh
# Bounded on purpose, not -j 0: many lanes build benches concurrently on one
# machine, and N lanes each taking every core is thrashing rather than parallelism.
# Same variable and default as the other runners;
# VERILATOR_JOBS=0 takes everything for a lane that has the machine to itself.
timeout "${BUILD_TIMEOUT_INT:-900}" verilator --binary --timing -j "${VERILATOR_JOBS:-8}" -O2 -Wall -Wno-fatal \
  -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-SYNCASYNCNET \
  -I"$Z" -I"$X" --top-module tb_pc9821_portharness --Mdir "$RUN_DIR/obj" \
  "${PC9821_Z486_RTL[@]}" tests/pc9821/tb_pc9821_portharness.sv
cd "$RUN_DIR"
if [[ $COMPILE_ONLY == 1 ]]; then
  echo "PORTHARNESS: COMPILE OK  (elaborated, not run)"
  exit 0
fi
# Extra plusargs are forwarded, so callers can set the stub, add probes, etc.
timeout "${BENCH_TIMEOUT_INT:-300}" ./obj/Vtb_pc9821_portharness +SCRIPT="$SCRIPT" "${EXTRA[@]:-}"

#!/usr/bin/env bash
# The CPU-throttle tier: the throttle guest (tests/pc9821/throttle_guest.s) through the real
# CPU, the gated-clock bridge, memory and I/O at Full, 8 MHz and 1 MHz.
#
#   bash tests/pc9821/run_throttle.sh                 build and run (TB_PC9821_THROTTLE: PASS)
#   bash tests/pc9821/run_throttle.sh --compile-only  elaborate the tier only, no run
#
# Like the boot tier it is outside `tools/bench.py --all` (it builds the real z486), so
# run_integrated_build.sh compiles it to catch a hierarchy rename.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
BUILD=tests/pc9821/build
OBJ=$BUILD/obj_throttle
mkdir -p "$BUILD"
COMPILE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --compile-only) COMPILE_ONLY=1 ;;
    *) echo "$0: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

./firmware/diagnostic/build.py --itf-src tests/pc9821/throttle_guest.s \
  --out "$BUILD/throttle_pack.bin" --mem "$BUILD/throttle_pack.mem"
for hex in ucode.hex pla_entry_rom.hex pla_group_entry.hex; do
  ln -sfn "$ROOT/src/z486/$hex" "$BUILD/$hex"
done

source tests/pc9821/z486_rtl.sh
RTL=("${PC9821_Z486_RTL[@]}" tests/pc9821/tb_pc9821_throttle.sv \
     tests/pc9821/sdram_backend_model.sv)

# Bounded on purpose, not -j 0: the same variable and default as run_boot.sh.
verilator --binary --timing -j "${VERILATOR_JOBS:-8}" -O2 -Wall -Wno-fatal \
  -Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-SYNCASYNCNET \
  -I"$Z" -I"$X" --top-module tb_pc9821_throttle --Mdir "$OBJ" "${RTL[@]}"

if [[ $COMPILE_ONLY == 1 ]]; then
  echo "THROTTLE: COMPILE OK  (elaborated, not run)"
  exit 0
fi
LOG="$BUILD/throttle.log"
(cd "$BUILD" && timeout "${BENCH_TIMEOUT_INT:-1800}" ./obj_throttle/Vtb_pc9821_throttle) | tee "$LOG"
grep -qx 'TB_PC9821_THROTTLE: PASS' "$LOG"

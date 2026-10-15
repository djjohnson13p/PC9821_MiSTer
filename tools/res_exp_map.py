#!/usr/bin/env python3
"""Price one memory SHAPE under the real Quartus synthesiser, in about a minute.

A full-design A&S pass is 10-15 minutes, so it can only be spent on the shapes that already
look right. This tool answers the shape question first: it wraps the given module(s) in a
throwaway Cyclone V project with the production synthesis settings and runs `quartus_map`
IN THIS PROJECT'S CONTAINER, then prints the module's RAM Summary row (or its absence -- an
array missing from that table is implemented in LOGIC) and the area summary.

It is a Quartus module-alone probe; unlike a yosys estimate it is the real
inference engine: "Quartus accepts this shape as a block RAM" is a claim only this tool can
make. Its numbers are for ONE module, on a device-sized project, so use it for
INFERENCE (a fact: the row is there or it is not) and for relative area between variants --
never for the whole design's ALUT total.

Usage:
  python3 tools/res_exp_map.py --top kbd_lut_a .build/res-exp/kbd_lut_*.sv
  python3 tools/res_exp_map.py --top pal_edge --ram pal -- keep .build/res-exp/pal_*.sv
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import res_exp_ram  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
IMAGE = "docker.io/raetro/quartus:mister"
RUNTIME = "podman"
DEVICE = "5CSEBA6U23I7"

# The production synthesis settings that can change RAM inference or area, so a standalone
# result is comparable with the full design's map.rpt (which reads these same values).
QSF_HEAD = f"""set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE {DEVICE}
set_global_assignment -name TOP_LEVEL_ENTITY {{top}}
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED
set_global_assignment -name MUX_RESTRUCTURE ON
set_global_assignment -name REMOVE_REDUNDANT_LOGIC_CELLS ON
set_global_assignment -name ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP ON
set_global_assignment -name PRE_MAPPING_RESYNTHESIS ON
set_global_assignment -name SYNTH_RESOURCE_AWARE_INFERENCE_FOR_BLOCK_RAM OFF
set_global_assignment -name IGNORE_VERILOG_INITIAL_CONSTRUCTS OFF
"""


def area_summary(map_rpt: Path) -> dict[str, str]:
    return res_exp_ram.parse(map_rpt)["totals"]


def run_one(top: str, sources: list[Path], ram_pat: str, keep: bool) -> int:
    work = REPO_ROOT / ".build" / "res-exp-map" / top
    if work.exists() and not keep:
        shutil.rmtree(work)
    work.mkdir(parents=True, exist_ok=True)
    names = []
    for src in sources:
        if not src.exists():
            print(f"res_exp_map: {src} does not exist", file=sys.stderr)
            return 1
        shutil.copy(src, work / src.name)
        names.append(src.name)
    # The top's ports have to be real pins or Quartus prunes the whole design: an empty
    # entity with no ports can be optimised away and the RAM Summary would be empty for
    # the wrong reason.
    files = "".join(
        f'set_global_assignment -name SYSTEMVERILOG_FILE "{n}"\n' for n in names
    )
    (work / f"{top}.qsf").write_text(QSF_HEAD.format(top=top) + files)
    (work / f"{top}.qpf").write_text(f'PROJECT_REVISION = "{top}"\n')

    cmd = [
        RUNTIME, "run", "--rm", "--name", f"resexp-{top}",
        "-e", "HOME=/tmp", "-v", f"{work}:/work", "-w", "/work", IMAGE,
        "/opt/intelFPGA/quartus/bin/quartus_map", top,
    ]
    print(f"==> quartus_map {top}  ({', '.join(names)})")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    log = work / "quartus_map.log"
    log.write_text(proc.stdout + proc.stderr)
    rpt = work / "output_files" / f"{top}.map.rpt"
    if not rpt.exists():
        print(f"res_exp_map: quartus_map produced no map.rpt (exit {proc.returncode})")
        print("\n".join((proc.stdout + proc.stderr).splitlines()[-20:]))
        return 1

    parsed = res_exp_ram.parse(rpt)
    pat = re.compile(ram_pat)
    hits = [r for r in parsed["ram"] if pat.search(r[0])]
    print(f"  RAM Summary rows matching {ram_pat!r}: {len(hits)}")
    for r in hits:
        print(f"    {r[0]}")
        print(f"      {r[1]} | {r[2]} | A {r[3]}x{r[4]} | size {r[7]} | MIF {r[8]}")
    if not hits:
        print("    (none: the array is implemented in LOGIC)")
    print(f"  all RAM rows in the module: {len(parsed['ram'])}")
    for key, val in parsed["totals"].items():
        print(f"  {key:<45} {val}")
    # Quartus's own words for every array it declined to infer.
    for line in (proc.stdout + proc.stderr).splitlines():
        if "uninferred" in line:
            print("  " + html.unescape(line.strip()))
    print(f"  reports: {rpt}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sources", nargs="+", type=Path)
    ap.add_argument("--top", required=True, help="the module with real input/output ports")
    ap.add_argument("--ram", default=".", help="regex over RAM Summary names (default: everything)")
    ap.add_argument("--keep", action="store_true", help="do not wipe an existing work dir")
    args = ap.parse_args(argv)
    return run_one(args.top, args.sources, args.ram, args.keep)


if __name__ == "__main__":
    raise SystemExit(main())

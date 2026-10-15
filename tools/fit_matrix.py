#!/usr/bin/env python3
"""A fit-settings matrix: many (configuration, seed) cells, one fit each, ranked by distribution.

    tools/fit_matrix.py run MATRIX.toml --root DIR [--jobs 12]   # fit every missing cell/seed
    tools/fit_matrix.py status --root DIR                         # progress, from the files
    tools/fit_matrix.py report --root DIR [--root DIR2 ...] [--csv PREFIX] [--baseline CELL]

A matrix file names the seeds and the CELLS; a cell is a build configuration (a preset and any
build_profile.py overrides, `--qsf-set NAME=VALUE` included) and optionally another tree:

    seeds = [1, 2, 3, 4, 5]
    retries = 0                 # a failed fit is a data point here (a crash), not a flake to hide
    [[cell]]
    name = "speed"              # [A-Za-z0-9_.-]+ ; the results land in DIR/<name>/seedNNN/
    args = ["base"]
    [[cell]]
    name = "speed.psr-off"
    args = ["base", "--qsf-set", "PHYSICAL_SYNTHESIS_REGISTER_RETIMING=OFF"]
    [[cell]]
    name = "cd.speed"
    tree = "../cd-tree"         # relative to the matrix file (default: this checkout)
    args = ["base", "--cdrom"]
    seeds = [2, 3]              # a cell may carry its own seeds
    env = { QUARTUS_NUM_PARALLEL_PROCESSORS = "4" }   # and environment for tools/build.py

Each (cell, seed) runs `<tree>/tools/seed_sweep.py <args> --seeds N --jobs 1 --dir DIR/<cell>`,
so a fit is exactly a seed-sweep fit (its own tree copy, the configuration applied and checked
there, output_files/ and build.log kept, metrics.json written), and at most --jobs run at once.
The jobs go out seed-major (every cell's first seed before any cell's second), so a matrix cut
short still has a balanced design. A finished (cell, seed) is never re-run: rerun `run` to
resume. The driver writes DIR/matrix-status.json as it goes; read that (or `status`), never a
process listing.

`report` reads every DIR/<cell>/seedNNN/metrics.json and prints, per cell, the distribution
(median, best, worst) of LABs, ALMs needed, the setup WNS and TNS of BOTH clocks - general[0]
(clk_sys) and general[1] (clk_sdram, in fits of a pre-2026-10-09 split-clock tree only; a current
fit has one core clock) - the worst hold, the fit time and the crash count; one fit
is a draw, so a cell is judged by its distribution. --csv writes PREFIX-fits.csv (one row per
fit) and PREFIX-cells.csv (one row per cell).
"""
from __future__ import annotations

import argparse
import csv
import os
import datetime as dt
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import fit_metrics  # noqa: E402
import host_slots  # noqa: E402

CELL_NAME = re.compile(r"[A-Za-z0-9_.-]+")


def log(msg: str) -> None:
    print(f"[{dt.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


def load_matrix(path: Path) -> dict:
    import tomllib
    data = tomllib.loads(path.read_text())
    seeds = data.get("seeds", [])
    cells = []
    for c in data.get("cell", []):
        name = c.get("name", "")
        if not CELL_NAME.fullmatch(name):
            raise SystemExit(f"{path}: cell name {name!r} must match {CELL_NAME.pattern}")
        tree = Path(c.get("tree", REPO))
        if not tree.is_absolute():
            tree = (path.parent / tree).resolve()
        if not (tree / "tools" / "seed_sweep.py").exists():
            raise SystemExit(f"{path}: cell {name}: {tree} has no tools/seed_sweep.py")
        argv = [str(a) for a in c.get("args", [])]
        if argv and not argv[0].startswith("-"):      # a bare preset, as build_profile.py takes it
            argv = ["--profile", *argv]
        env = {str(k): str(v) for k, v in c.get("env", {}).items()}
        cells.append({"name": name, "tree": tree, "args": argv, "env": env,
                      "seeds": [int(s) for s in c.get("seeds", seeds)]})
    names = [c["name"] for c in cells]
    if len(set(names)) != len(names):
        raise SystemExit(f"{path}: duplicate cell names")
    return {"cells": cells, "retries": int(data.get("retries", 0))}


def seed_done(root: Path, cell: str, seed: int) -> bool:
    return (root / cell / f"seed{seed:03d}" / "summary.txt").exists()


def seed_started(root: Path, cell: str, seed: int) -> bool:
    """A seed directory exists: the seed is done, or a seed_sweep (perhaps another driver's,
    before a restart) is fitting it. A restarted driver must not start a second copy; a seed
    whose fit was killed is re-run by deleting its directory."""
    return (root / cell / f"seed{seed:03d}").exists()


def tree_source(tree: Path) -> str:
    """Which source a tree is: its git HEAD, or the TREE_SOURCE file a shipped copy carries."""
    marker = tree / "TREE_SOURCE"
    if marker.exists():
        return marker.read_text().strip()
    try:
        return subprocess.run(["git", "-C", str(tree), "rev-parse", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def host_has_room(limit: int, mine: str = "") -> bool:
    """Whether fewer than `limit` Quartus containers run on this host. With `mine`, only the
    containers whose mount SOURCE contains it count (a shared host: this lane's ceiling, not the
    host's - other lanes' fits are theirs to budget); without it, every running container."""
    if limit <= 0:
        return True
    runtime = __import__("os").environ.get("CONTAINER_RUNTIME", "podman")
    try:
        ids = subprocess.run([runtime, "ps", "-q", "--filter", "status=running"],
                             capture_output=True, text=True, timeout=60).stdout.split()
        if mine and ids:
            out = subprocess.run([runtime, "inspect", "--format",
                                  "{{range .Mounts}}{{.Source}} {{end}}", *ids],
                                 capture_output=True, text=True, timeout=60).stdout
            ids = [line for line in out.splitlines() if mine in line]
    except (OSError, subprocess.TimeoutExpired):
        return False
    return len(ids) < limit


def cmd_run(args) -> int:
    matrix = load_matrix(args.matrix)
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    # Prepare each cell once, sequentially: resolve, generate its PLL into the tree's shared
    # cache and have Quartus check its qsf_set - a bad cell fails here, before any fit starts.
    for c in matrix["cells"]:
        cdir = root / c["name"]
        cdir.mkdir(exist_ok=True)
        r = subprocess.run([sys.executable, str(c["tree"] / "tools" / "seed_sweep.py"),
                            *c["args"], "--prepare"], cwd=c["tree"], capture_output=True,
                           text=True)
        if r.returncode != 0:
            raise SystemExit(f"cell {c['name']}: {' '.join(c['args'])} does not prepare:\n"
                             f"{r.stdout}{r.stderr}")
        config = r.stdout.strip().splitlines()[-1].split("prepared: ", 1)[-1]
        (cdir / "cell.json").write_text(json.dumps({
            "name": c["name"], "args": c["args"], "env": c["env"], "tree": str(c["tree"]),
            "source": tree_source(c["tree"]), "config": json.loads(config)}, indent=1) + "\n")
        log(f"cell {c['name']}: prepared ({' '.join(c['args'])})")
    jobs = []
    depth = max(len(c["seeds"]) for c in matrix["cells"])
    for i in range(depth):
        for c in matrix["cells"]:
            if i < len(c["seeds"]) and not seed_started(root, c["name"], c["seeds"][i]):
                jobs.append((c, c["seeds"][i]))
    total = sum(len(c["seeds"]) for c in matrix["cells"])
    log(f"{len(jobs)} fit(s) to run of {total} in the matrix, {args.jobs} at a time -> {root}")
    if args.dry_run:
        for c, seed in jobs:
            print(f"  {c['name']} seed {seed}: {' '.join(c['args'])}")
        return 0
    running: list[tuple[subprocess.Popen, dict, int, float, tuple | None]] = []
    finished = 0
    started = time.time()

    def write_status(state: str) -> None:
        status = {"state": state, "updated": int(time.time()), "matrix": str(args.matrix),
                  "jobs": args.jobs, "finished": finished,
                  "running": [f"{c['name']}/seed{s}" for _, c, s, _, _ in running],
                  "waiting": len(jobs), "elapsed_min": round((time.time() - started) / 60, 1)}
        tmp = root / "matrix-status.json.tmp"
        tmp.write_text(json.dumps(status, indent=1) + "\n")
        tmp.replace(root / "matrix-status.json")

    while jobs or running:
        while jobs and len(running) < args.jobs and host_has_room(args.max_containers, args.mine):
            slot = None
            if args.slots:
                # THE ceiling: a slot is taken before anything starts and held until the job
                # exits (tools/host_slots.py), shared with every other launcher on the host.
                c, seed = jobs[0]
                slot = host_slots.try_acquire(args.slots, args.slots_n, f"{c['name']}/{seed}",
                                              os.getpid(), args.mine,
                                              root / c["name"] / f"seed{seed:03d}")
                if slot is None:
                    break
            c, seed = jobs.pop(0)
            out = (root / c["name"] / f"seed{seed:03d}.sweep.log").open("w")
            argv = [sys.executable, str(c["tree"] / "tools" / "seed_sweep.py"), *c["args"],
                    "--seeds", str(seed), "--jobs", "1", "--retries", str(matrix["retries"]),
                    "--dir", str(root / c["name"])]
            proc = subprocess.Popen(argv, cwd=c["tree"], stdout=out, stderr=subprocess.STDOUT,
                                    env={**__import__("os").environ, **c["env"]},
                                    stdin=subprocess.DEVNULL, start_new_session=True)
            if slot:
                host_slots.set_pid(slot, proc.pid)
                slot = (slot, host_slots.token_of(slot))
            running.append((proc, c, seed, time.time(), slot))
            log(f"start {c['name']} seed {seed} (pid {proc.pid})")
            write_status("running")
            time.sleep(args.stagger)
        still = []
        for proc, c, seed, t0, slot in running:
            if proc.poll() is None:
                still.append((proc, c, seed, t0, slot))
                continue
            finished += 1
            if slot:
                host_slots.release(*slot)
            m = {}
            mpath = root / c["name"] / f"seed{seed:03d}" / "metrics.json"
            if mpath.exists():
                m = json.loads(mpath.read_text())
            log(f"done  {c['name']} seed {seed} in {(time.time() - t0) / 60:.0f} min: "
                f"{m.get('verdict', 'NO RESULT')} LABs {m.get('labs', '-')} "
                f"clk_sys {m.get('clk_sys_setup', '-')} clk_sdram {m.get('clk_sdram_setup', '-')}"
                + (f" INTERNAL ERROR {m['internal_errors']}" if m.get("internal_errors") else ""))
        running = still
        write_status("running")
        time.sleep(args.poll)
    write_status("done")
    log("matrix finished")
    return 0


def cmd_status(args) -> int:
    root = args.root.resolve()
    st = root / "matrix-status.json"
    if st.exists():
        s = json.loads(st.read_text())
        age = (time.time() - s["updated"]) / 60
        print(f"driver: {s['state']} (updated {age:.0f} min ago), finished {s['finished']}, "
              f"running {len(s['running'])}, waiting {s['waiting']}, {s['elapsed_min']} min")
    for cdir in sorted(p for p in root.iterdir() if (p / "cell.json").exists()):
        done = sorted(cdir.glob("seed*/summary.txt"))
        print(f"  {cdir.name:<40} {len(done)} done")
    return 0


# ---------------------------------------------------------------- report ----

FIT_FIELDS = ["cell", "seed", "verdict", "attempts", "labs", "alms_needed", "registers",
              "clk_sys_setup", "clk_sys_tns", "clk_sys_hold", "clk_sdram_setup", "clk_sdram_tns",
              "clk_sdram_hold", "sdram_io_setup", "sdram_io_tns", "other_setup", "worst_setup", "interconnect", "map_min", "fit_min",
              "internal_errors", "crash_stage", "dtm_fallback", "source", "root"]


def load_fits(roots: list[Path]) -> list[dict]:
    rows = []
    for root in roots:
        for cdir in sorted(p for p in root.iterdir() if p.is_dir()):
            cell = json.loads((cdir / "cell.json").read_text()) if (cdir / "cell.json").exists() \
                else {}
            for sd in sorted(cdir.glob("seed[0-9]*")):
                if not sd.is_dir() or not (sd / "summary.txt").exists():
                    continue
                mpath = sd / "metrics.json"
                # The verdict and attempts from the run; the numbers re-read from the kept reports
                # and log, so a fit_metrics improvement reaches fits measured before it.
                m = json.loads(mpath.read_text()) if mpath.exists() else {}
                m.update(fit_metrics.fit_metrics(sd))
                if "verdict" not in m:
                    text = (sd / "summary.txt").read_text()
                    v = re.search(r"verdict=(\w+)", text)
                    m["verdict"] = v.group(1) if v else "?"
                row = {"cell": cdir.name, "seed": int(sd.name[4:]), **m,
                       "source": cell.get("source", "")[:10], "root": str(root)}
                if "clk_sys_setup" in row:
                    # Every clock that must close: both core clocks and the SDRAM pin interface
                    # (only an old split-clock fit has a general[1] clk_sdram row).
                    row["worst_setup"] = min(row[k] for k in ("clk_sys_setup", "clk_sdram_setup",
                                                              "sdram_io_setup") if k in row)
                rows.append(row)
    return rows


def dist(values: list[float]) -> tuple:
    if not values:
        return (None, None, None)
    return (statistics.median(values), min(values), max(values))


def cell_rows(fits: list[dict]) -> list[dict]:
    cells: dict[str, list[dict]] = {}
    for f in fits:
        cells.setdefault(f["cell"], []).append(f)
    out = []
    for name, rows in cells.items():
        ok = [r for r in rows if r.get("verdict") == "passed" and "labs" in r]
        crashed = [r for r in rows if r.get("internal_errors") or r.get("verdict") != "passed"]
        rec = {"cell": name, "fits": len(rows), "passed": len(ok), "crashed": len(crashed),
               "crash_sigs": ";".join(sorted({e for r in crashed
                                              for e in r.get("internal_errors", [])}))}
        for key in ("labs", "alms_needed", "clk_sys_setup", "clk_sdram_setup", "worst_setup",
                    "clk_sys_tns", "clk_sdram_tns", "sdram_io_setup", "other_setup", "fit_min"):
            med, lo, hi = dist([r[key] for r in ok if r.get(key) is not None])
            rec[f"{key}_med"], rec[f"{key}_min"], rec[f"{key}_max"] = med, lo, hi
        holds = [r[k] for r in ok for k in ("clk_sys_hold", "clk_sdram_hold")
                 if r.get(k) is not None]
        rec["hold_min"] = min(holds) if holds else None
        out.append(rec)
    return out


def fmt(v, spec: str) -> str:
    return "-" if v is None else format(v, spec)


def cmd_report(args) -> int:
    fits = load_fits([r.resolve() for r in args.root])
    cells = cell_rows(fits)
    order = {"labs": lambda c: (c["labs_med"] is None, c["labs_med"] or 0),
             "clk_sys": lambda c: -(c["clk_sys_setup_med"] or -99),
             "worst": lambda c: -(c["worst_setup_med"] or -99),
             "name": lambda c: c["cell"]}[args.sort]
    cells.sort(key=order)
    base = next((c for c in cells if c["cell"] == args.baseline), None)
    print(f"{len(fits)} fits in {len(cells)} cells. Medians [min..max]; clk_sys = general[0], "
          "clk_sdram = general[1], sdram_io = PC9821_SDRAM_CLK (the SDRAM pins), other = the worst "
          "framework clock; setup WNS in ns (slow corner); LABs of 4,191.")
    hdr = (f"{'cell':<34}{'n':>3}{'ok':>4}{'crash':>6}  {'LABs med [min..max]':<22}"
           f"{'ALMs med':>9}  {'clk_sys med [best..worst]':<26}{'clk_sdram med [best..worst]':<28}"
           f"{'sysTNS':>8}{'io min':>8}{'oth min':>8}{'hold':>7}{'fit min':>8}")
    print(hdr)
    for c in cells:
        delta = ""
        if base and c is not base and c["labs_med"] is not None and base["labs_med"] is not None:
            delta = (f"  dLAB {c['labs_med'] - base['labs_med']:+.0f} "
                     f"dsys {c['clk_sys_setup_med'] - base['clk_sys_setup_med']:+.3f} "
                     + (f"dsdram {c['clk_sdram_setup_med'] - base['clk_sdram_setup_med']:+.3f}"
                        if c['clk_sdram_setup_med'] is not None
                        and base['clk_sdram_setup_med'] is not None else ""))
        labs = f"{fmt(c['labs_med'], ',.0f')} [{fmt(c['labs_min'], ',')}..{fmt(c['labs_max'], ',')}]"
        csys = (f"{fmt(c['clk_sys_setup_med'], '+.3f')} [{fmt(c['clk_sys_setup_max'], '+.3f')}.."
                f"{fmt(c['clk_sys_setup_min'], '+.3f')}]")
        csdr = (f"{fmt(c['clk_sdram_setup_med'], '+.3f')} [{fmt(c['clk_sdram_setup_max'], '+.3f')}.."
                f"{fmt(c['clk_sdram_setup_min'], '+.3f')}]")
        print(f"{c['cell']:<34}{c['fits']:>3}{c['passed']:>4}{c['crashed']:>6}  {labs:<22}"
              f"{fmt(c['alms_needed_med'], ',.0f'):>9}  {csys:<26}{csdr:<28}"
              f"{fmt(c['clk_sys_tns_med'], '.1f'):>8}{fmt(c['sdram_io_setup_min'], '+.3f'):>8}"
              f"{fmt(c['other_setup_min'], '+.3f'):>8}{fmt(c['hold_min'], '.3f'):>7}"
              f"{fmt(c['fit_min_med'], '.0f'):>8}{delta}"
              + (f"  CRASH {c['crash_sigs']}" if c["crash_sigs"] else ""))
    if args.csv:
        prefix = Path(args.csv)
        prefix.parent.mkdir(parents=True, exist_ok=True)
        with open(f"{prefix}-fits.csv", "w", newline="") as h:
            w = csv.DictWriter(h, fieldnames=FIT_FIELDS, extrasaction="ignore")
            w.writeheader()
            for f in sorted(fits, key=lambda r: (r["cell"], r["seed"])):
                w.writerow({**f, "internal_errors": ";".join(f.get("internal_errors", []))})
        with open(f"{prefix}-cells.csv", "w", newline="") as h:
            w = csv.DictWriter(h, fieldnames=list(cells[0].keys()) if cells else ["cell"])
            w.writeheader()
            for c in cells:
                w.writerow(c)
        print(f"wrote {prefix}-fits.csv and {prefix}-cells.csv")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run")
    p.add_argument("matrix", type=Path)
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--jobs", type=int, default=12, help="concurrent fits (default 12)")
    p.add_argument("--max-containers", type=int, default=0,
                   help="also wait while this host runs this many containers (0 = no check)")
    p.add_argument("--slots", type=Path,
                   help="a tools/host_slots.py directory: take a slot per fit (the host-wide "
                        "lane ceiling every launcher shares)")
    p.add_argument("--slots-n", type=int, default=10, help="the ceiling (default 10)")
    p.add_argument("--mine", default="",
                   help="with --max-containers: count only containers whose mount source "
                        "contains this (e.g. /sweeps/fx/), so the ceiling is this lane's")
    p.add_argument("--stagger", type=int, default=20,
                   help="seconds between two launches (default 20)")
    p.add_argument("--poll", type=int, default=30)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_run)
    p = sub.add_parser("status")
    p.add_argument("--root", type=Path, required=True)
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("report")
    p.add_argument("--root", type=Path, action="append", required=True)
    p.add_argument("--csv", help="write PREFIX-fits.csv and PREFIX-cells.csv")
    p.add_argument("--baseline", help="a cell to print deltas against")
    p.add_argument("--sort", choices=("labs", "clk_sys", "worst", "name"), default="name")
    p.set_defaults(func=cmd_report)
    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

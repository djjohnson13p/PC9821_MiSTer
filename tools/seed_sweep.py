#!/usr/bin/env python3
"""Seed sweep: fit many Quartus seeds of a build profile and rank them by timing.

Each seed is fitted in its own copy of the working tree (so concurrent fits cannot
collide), at most --jobs at a time, and completion is judged by the fit's own
status file rather than by process state (a killed podman CLI can leave its
container running, so a PID is not evidence). The fitter crashes on some runs (a
known Quartus flake), so a failed fit is retried up to --retries times before the
seed is recorded as failed. A seed that already has a recorded verdict is skipped
on re-run, so the sweep survives interruption and resumes where it left off.

    tools/seed_sweep.py --profile heavyoc --count 100 --jobs 10
    nohup tools/seed_sweep.py --profile heavyoc --count 100 --jobs 10 &
    tools/seed_sweep.py --report          # rank the finished seeds, print the best
    tools/seed_sweep.py --profile base --sdram-mhz 110 --count 6 --jobs 3 --dir .build/sw110
    tools/seed_sweep.py --profile-file sweep.toml --count 6 --jobs 3 --dir .build/swX

Any build_profile.py override (--clk-sys-mhz, --sdram-mhz, --sdram-phase-ps, --trace,
--profile-file, ...) is applied to every seed's copy on top of --profile, and each seed
refuses to fit unless its copy resolves to exactly the configuration the parent resolved.
The PLL is generated once, into the parent's .build/pll-cache/, and every seed reuses it.

Per seed the verdict lands in <dir>/seedNNN/status.txt and the measured timing in
<dir>/seedNNN/summary.txt; a one-line-per-seed roll-up is <dir>/summary.txt. The
working copies are deleted as soon as a seed's numbers are recorded, so the disk
cost is bounded by --jobs trees, not by --count.

The ranking is by clk_sys setup slack (the profile's limiting clock): the best
seed is the one with the largest positive slack.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR))
import build_profile  # noqa: E402  (the configuration overrides, shared with tools/build.py)
sys.path.insert(0, str(PROJECT_DIR / "tools"))
import fit_metrics  # noqa: E402  (the per-fit numbers, shared with tools/fit_matrix.py)
COPY_EXCLUDE = (".git", ".build", "output_files", "db", "incremental_db",
                "build", "simulation", "__pycache__")
STATUS = "status.txt"      # the fit's own verdict (STATE=..., FIT_EXIT=...)
SUMMARY = "summary.txt"    # our recorded numbers for the seed
PRINT_LOCK = threading.Lock()


def log(msg: str) -> None:
    with PRINT_LOCK:
        print(msg, flush=True)


def sweep_dir(args) -> Path:
    return Path(args.dir).resolve() if args.dir else PROJECT_DIR / ".build" / "seedsweep"


def seed_dir(root: Path, seed: int) -> Path:
    return root / f"seed{seed:03d}"


def copy_work_tree(dst: Path) -> None:
    """Copy the current tree into dst, excluding the heavyweight/generated dirs."""
    def ignore(_dir, names):
        return [n for n in names if n in COPY_EXCLUDE]
    shutil.copytree(PROJECT_DIR, dst, ignore=ignore, symlinks=True)


def fit_once(tree: Path, seed: int, profile_argv: list[str], expected: str) -> bool:
    """Apply the configuration in `tree`, then run one fit; True iff the fit passed."""
    log_path = tree / "build.log"
    status = tree / STATUS
    for stale in (log_path, status, tree / SUMMARY):
        if stale.exists():
            stale.unlink()
    # The configuration is TREE STATE (the top level's localparams + the qsf record; the PLL
    # and SDC are generated from it), so it is applied inside the seed's copy - the caller's
    # tree is never touched - and the copy must resolve to exactly the parent's configuration.
    sw = subprocess.run([sys.executable, str(tree / "build_profile.py"), *profile_argv],
                        cwd=tree, capture_output=True, text=True, check=False)
    got = subprocess.run([sys.executable, str(tree / "build_profile.py"), "--print-config"],
                         cwd=tree, capture_output=True, text=True, check=False)
    if sw.returncode != 0 or got.stdout.strip() != expected:
        log(f"  !! configuration did not apply: {sw.stdout}{sw.stderr}{got.stdout}{got.stderr}")
        return False
    cmd = [sys.executable, str(tree / "tools" / "build.py"), "--seed", str(seed),
           "--log", str(log_path), "--status-file", str(status)]
    subprocess.run(cmd, cwd=tree, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
    return "STATE=passed" in status.read_text() if status.exists() else False


def _slack_after(text: str, key: str) -> float | None:
    """The slack on the line after the sta.summary row whose Setup line names `key`."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if "Setup" in ln and key in ln and i + 1 < len(lines):
            m = re.search(r"\s(-?\d+\.\d+)\s*$|\s(-?\d+\.\d+)\s", lines[i + 1])
            if m:
                return float(next(g for g in m.groups() if g is not None))
    return None


def record(tree: Path) -> dict:
    """Extract the numbers we rank by out of the fit's reports."""
    out = {}
    sta = tree / "output_files" / "z486_mister.sta.summary"
    fit = tree / "output_files" / "z486_mister.fit.summary"
    if sta.exists():
        txt = sta.read_text(errors="replace")
        # clk_sdram (general[1]) exists only in fits of a pre-2026-10-09 split-clock tree; a
        # current fit's general[1] is the SDRAM pin clock and has no summary row.
        for name, key in (("clk_sys_slack", "general[0]"),
                          ("clk_sdram_slack", "general[1]")):
            v = _slack_after(txt, key)
            if v is not None:
                out[name] = v
        m = re.search(r"Worst-case\s+Setup\s+Slack\s*:\s*(-?\d+\.\d+)", txt)
        if m:
            out["worst_setup_slack"] = float(m.group(1))
    if fit.exists():
        m = re.search(r"Logic utilization \(in ALMs\)\s*:\s*([\d,]+)\s*/\s*([\d,]+)",
                      fit.read_text(errors="replace"))
        if m:
            out["alm"] = int(m.group(1).replace(",", ""))
            out["alm_pct"] = round(100.0 * out["alm"] / int(m.group(2).replace(",", "")), 1)
    return out


def do_seed(root: Path, seed: int, profile_argv: list[str], expected: str, retries: int) -> None:
    sd = seed_dir(root, seed)
    if (sd / SUMMARY).exists():
        return  # already done (resume)
    sd.mkdir(parents=True, exist_ok=True)
    tree = sd / "tree"
    verdict = "failed"
    for attempt in range(1, retries + 2):
        if tree.exists():
            shutil.rmtree(tree)
        copy_work_tree(tree)
        log(f"[seed {seed:03d}] fit attempt {attempt}")
        if fit_once(tree, seed, profile_argv, expected):
            verdict = "passed"
            break
        log(f"[seed {seed:03d}] fit attempt {attempt} FAILED (the Quartus flake is expected ~30% of the time)")
    nums = record(tree)
    with open(sd / SUMMARY, "w") as f:
        f.write(f"seed={seed}\nverdict={verdict}\nattempts={attempt}\n")
        f.write(f"config={expected}\n")
        for k, v in nums.items():
            f.write(f"{k}={v}\n")
    # Preserve the ENTIRE build output before the tree goes away: the RBF and the
    # basic timings are the minimum (the summary above), but a seed's full
    # output_files folder (the RBF, the sta/fit/map reports, the pin/model dumps)
    # plus the fit log are what make a result auditable later. Kept at
    # <dir>/seedNNN/output_files and <dir>/seedNNN/build.log.
    out_src = tree / "output_files"
    if out_src.exists():
        shutil.copytree(out_src, sd / "output_files", dirs_exist_ok=True)
    scratch_out = tree / ".build" / "quartus" / "output_files"
    if scratch_out.exists():
        shutil.copytree(scratch_out, sd / "output_files", dirs_exist_ok=True)
    if (tree / "build.log").exists():
        shutil.copy2(tree / "build.log", sd / "build.log")
    shutil.rmtree(tree, ignore_errors=True)   # keep the disk bounded
    # The full per-fit numbers (both clocks' setup/TNS/hold, LABs, fit time, any Quartus
    # internal error and where it struck) beside the summary, from the kept reports and log.
    with open(sd / "metrics.json", "w") as f:
        json.dump({"seed": seed, "verdict": verdict, "attempts": attempt,
                   "config": json.loads(expected), **fit_metrics.fit_metrics(sd)},
                  f, indent=1, sort_keys=True)
    log(f"[seed {seed:03d}] {verdict} " +
        " ".join(f"{k}={v}" for k, v in nums.items()))


def load_summaries(root: Path) -> list[dict]:
    rows = []
    for sd in sorted(root.glob("seed*")):
        s = sd / SUMMARY
        if not s.exists():
            continue
        row = {"seed": sd.name}
        for line in s.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                try:
                    row[k] = float(v) if "." in v else int(v)
                except ValueError:
                    row[k] = v
        rows.append(row)
    return rows


def report(root: Path, top: int = 10) -> None:
    rows = [r for r in load_summaries(root) if r.get("verdict") == "passed"]
    rows.sort(key=lambda r: -float(r.get("clk_sys_slack", -99)))
    log(f"\n== {len(rows)} passed seeds, ranked by clk_sys setup slack ==")
    log(f"  {'seed':<10}{'clk_sys':>9}{'clk_sdram':>11}{'ALM':>8}{'ALM%':>7}{'att':>5}")
    for r in rows[:top]:
        log(f"  {r['seed']:<10}{r.get('clk_sys_slack', 0):>9.3f}{r.get('clk_sdram_slack', 0):>11.3f}"
            f"{r.get('alm', 0):>8}{r.get('alm_pct', 0):>7.1f}{r.get('attempts', 1):>5}")
    if rows:
        best = rows[0]
        log(f"\n  BEST: {best['seed']}  clk_sys +{best.get('clk_sys_slack', 0):.3f} ns"
            )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", choices=sorted(build_profile.PROFILES),
                    help="the build_profile preset (default heavyoc, or the --profile-file's "
                         "'preset'); overrides apply on top")
    ap.add_argument("--count", type=int, default=100, help="how many seeds to sweep (default 100)")
    ap.add_argument("--jobs", type=int, default=10, help="max concurrent fits (default 10)")
    ap.add_argument("--retries", type=int, default=3, help="retries per seed for the fit flake (default 3)")
    ap.add_argument("--dir", help="the sweep directory (default <repo>/.build/seedsweep)")
    ap.add_argument("--seeds", help="an explicit list, e.g. 1,2,5-8")
    ap.add_argument("--report", action="store_true", help="just rank the finished seeds")
    ap.add_argument("--top", type=int, default=10, help="how many rows the report prints")
    ap.add_argument("--prepare", action="store_true",
                    help="resolve the configuration and generate its PLL into the shared cache "
                         "(and have Quartus check its qsf_set), then exit without fitting - so "
                         "concurrent sweeps of one configuration never generate it at once")
    build_profile.add_override_args(ap)
    args = ap.parse_args()

    root = sweep_dir(args)
    root.mkdir(parents=True, exist_ok=True)

    if args.report:
        report(root, args.top)
        return 0

    if args.seeds:
        seeds = []
        for part in args.seeds.split(","):
            if "-" in part:
                a, b = part.split("-")
                seeds.extend(range(int(a), int(b) + 1))
            else:
                seeds.append(int(part))
    else:
        seeds = list(range(1, args.count + 1))

    if args.profile:
        preset = [args.profile]
    elif args.profile_file or args.custom:
        preset = []
    else:
        preset = ["heavyoc"]
    profile_argv = preset + build_profile.override_argv(args)
    resolved = subprocess.run([sys.executable, str(PROJECT_DIR / "build_profile.py"),
                               "--print-config", *profile_argv],
                              capture_output=True, text=True, check=False)
    if resolved.returncode != 0:
        log(f"configuration {' '.join(profile_argv)} is invalid:\n{resolved.stdout}{resolved.stderr}")
        return 1
    expected = resolved.stdout.strip()
    # One PLL generation for the whole sweep: every seed's copy shares the parent's cache.
    os.environ["PC9821_PLL_CACHE"] = str(PROJECT_DIR / ".build" / "pll-cache")
    import profile_gen
    config = build_profile.config_from_record(json.loads(expected))
    with tempfile.TemporaryDirectory(prefix="seed-sweep-pll-") as tmp:
        try:
            profile_gen.generate_pll(config.pll_request(), Path(tmp), project_dir=PROJECT_DIR,
                                     log=log)
        except profile_gen.GenerationError as exc:
            log(f"PLL generation failed, nothing swept: {exc}")
            return 1
    problems = build_profile.quartus_check_qsf_set(config.qsf_set)
    if problems:
        log("qsf_set refused, nothing swept:\n  " + "\n  ".join(problems))
        return 1
    if args.prepare:
        log(f"prepared: {expected}")
        return 0

    log(f"sweeping {len(seeds)} seeds of {' '.join(profile_argv)} with {args.jobs} jobs, "
        f"{args.retries} retries -> {root}")
    log(f"configuration: {expected}")
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = {pool.submit(do_seed, root, s, profile_argv, expected, args.retries): s
                for s in seeds}
        for f in cf.as_completed(futs):
            f.result()   # surface any unexpected exception
    report(root, args.top)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

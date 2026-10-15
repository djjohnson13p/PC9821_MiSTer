#!/usr/bin/env python3
"""Fail when a file under src/ is named by no build system and not accounted for.

WHY THIS EXISTS.  This tree has grown dead sources twice because nothing checks
for them, and the two surveys that looked both got it wrong in opposite
directions:

  * A survey reported "56 of 159 non-submodule files under src/ are dead".  It
    had enumerated the QUARTUS build lists only.  Most of those files are named
    by verilator/Makefile and by src/system.sv, so deleting them would have
    broken a build system rather than cleaned up after one.
  * The prior orphan round (r11) used "named by verilator/Makefile" as proof of
    life and kept files on that basis.  That Makefile builds z486_mister_sim.sv,
    whose hierarchy needs sst1_device, sst1_ddr_model and z486_wb_sim_memory -
    none of which exist anywhere in the tree - so it cannot elaborate, and its
    naming something proves nothing.

So this checker does not ask "is it built".  It asks "is it accounted for",
and it makes the difference between the two explicit per entry:

  SHIPPED    named by the Quartus lists that produce the RBF.  Removing one
             changes the bitstream.
  SIMULATED  named by a build system that is not the shipped design.  Listed so
             the set is visible rather than forgotten; not an error.
  ALLOWED    deliberate, with a reason in ALLOWLIST below.
  UNKNOWN    named by nothing and not allowed - this is the failure.

The UNKNOWN verdict is the only one that exits non-zero, because a check that
fires on the known backlog is a check nobody can leave switched on.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Directories whose files are never compiled Verilog and never need a build list.
# `src/z486` is also listed by `git ls-files` as the submodule GITLINK itself - a
# bare path with no trailing slash - so it needs its own exact match.  Without it
# the checker fails on a clean tree, which is how this was found: the planted-file
# test in the same run showed the gitlink verdict was not the planted file's.
SKIP_DIRS = ("src/z486/",)          # pinned submodule: not ours to manage
SKIP_EXACT = {"src/z486"}            # the submodule entry itself

# Every deliberate exception, with the reason.  Keep this short and honest: an
# entry here is a claim that the file is fine where it is, so a stale entry is
# worse than no entry.
ALLOWLIST = {
    "src/opna/LICENSE-SCOPE.md": "licence record for the vendored OPNA; required by the per-directory licence policy",
    "src/opna/jt12/LICENSE": "vendored JT12 licence; must ship with the code it covers",
    "src/opna/jt12/README.md": "vendored JT12 readme; provenance of the vendored core",
    "src/opna/jt49/LICENSE": "vendored JT49 licence; must ship with the code it covers",
    "src/opna/jt49/README.md": "vendored JT49 readme; provenance of the vendored core",
}

SRC_EXT = {".sv", ".v", ".vhd", ".vh", ".svh", ".mif", ".hex", ".qip", ".qsys",
           # extensionless files are considered too: a bare `LICENSE` beside vendored
           # code is exactly the kind of file that must be ACCOUNTED FOR rather than
           # silently skipped.  An earlier version of this checker skipped them, which
           # made two of its own ALLOWLIST entries inert - a stale entry being exactly
           # the kind of false claim this file exists to prevent.
           "", ".md"}


def quartus_live(root: pathlib.Path) -> set:
    """Files the shipped Quartus project names, walked from its .qsf roots."""
    live, seen, queue = set(), set(), [root / "z486_mister.qsf", root / "sys" / "pll_q17.qip"]
    while queue:
        f = queue.pop(0)
        try:
            f = f.resolve()
        except OSError:
            continue
        if f in seen or not f.is_file():
            continue
        seen.add(f)
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            for tok in line.split():
                t = tok.strip().strip('"').strip("'")
                if not t or t.startswith("-"):
                    continue
                if pathlib.PurePosixPath(t).suffix.lower() not in SRC_EXT:
                    continue
                for base in (root, f.parent):
                    cand = base / t
                    if cand.is_file():
                        live.add(cand.resolve().relative_to(root).as_posix())
                        if cand.suffix.lower() == ".qip":
                            queue.append(cand)
                        break
    return live


def verilator_named(root: pathlib.Path) -> set:
    """Files verilator/Makefile's SOURCES names.  Reported, never trusted."""
    mk = root / "verilator" / "Makefile"
    if not mk.is_file():
        return set()
    joined = mk.read_text(errors="replace").replace("\\\n", " ")
    m = re.search(r"^SOURCES\s*=\s*(.*)$", joined, re.M)
    if not m:
        return set()
    out = set()
    for tok in m.group(1).split():
        for pre, base in (("$(DZ)/", "src/z486/"), ("$(D)/", "src/"), ("../", "")):
            if tok.startswith(pre):
                rel = base + tok[len(pre):] if base else tok[3:]
                if (root / rel).is_file():
                    out.add(rel)
                break
    return out


def bench_named(root: pathlib.Path) -> set:
    bp = root / "tools" / "gen_bench_sources.py"
    if not bp.is_file():
        return set()
    return {r for r in set(re.findall(r"'(src/[^']+)'", bp.read_text(errors="replace")))
            if (root / r).is_file()}


def main() -> int:
    try:
        tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                                 text=True, check=True).stdout.split()
    except (subprocess.CalledProcessError, OSError) as exc:
        print(f"check_dead_files: cannot list tracked files: {exc}", file=sys.stderr)
        return 2

    quartus = quartus_live(ROOT)
    sim = verilator_named(ROOT)
    bench = bench_named(ROOT)

    unknown, allowed, simulated = [], [], []
    for rel in sorted(tracked):
        if not rel.startswith("src/"):
            continue
        if rel in SKIP_EXACT or any(rel.startswith(d) for d in SKIP_DIRS):
            continue
        if pathlib.PurePosixPath(rel).suffix.lower() not in SRC_EXT:
            continue
        if rel in quartus or rel in bench:
            continue
        if rel in ALLOWLIST:
            allowed.append(rel)
        elif rel in sim:
            simulated.append(rel)
        else:
            unknown.append(rel)

    if unknown:
        print("check_dead_files: FAIL - named by no build system and not allowed:")
        for rel in unknown:
            print(f"  {rel}")
        print()
        print("  Either wire it into a build, delete it, or add it to ALLOWLIST in")
        print("  this file with a reason. The allowlist is a claim, not a dumping ground.")
        return 1

    print(f"check_dead_files: OK - {len(quartus)} named by the Quartus project, "
          f"{len(bench)} by the bench manifest, {len(allowed)} allowed, "
          f"{len(sim)} named only by the simulator scaffold")
    return 0


if __name__ == "__main__":
    sys.exit(main())

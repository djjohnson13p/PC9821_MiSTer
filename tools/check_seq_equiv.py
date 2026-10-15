#!/usr/bin/env python3
"""check_seq_equiv.py -- prove a module's rewrite cycle-identical to an earlier revision of it.

For a ZERO-CYCLE restructuring (a mux moved after a register-free function, a select
duplicated, a decode precomputed from the same registered inputs) the rewritten module keeps
the same registers, so yosys's equivalence flow can match them and prove every register input
and every output equal for every input and every reachable state:

  equiv_make old new; equiv_simple -seq N; equiv_induct -seq N; equiv_status -assert

The old text is `git show REV:FILE`, renamed; the new text is the working tree's. A run that
reports "unproven" cells fails. `--plant OLD=>NEW` mutates the NEW text first, and the run must
then FAIL (a proof that cannot fail proves nothing); each PLANTS entry below is one such check,
run by --selftest.

  python3 tools/check_seq_equiv.py --old bf1b6650 src/pc9821/core/pc9821_gvram_arb.sv
  python3 tools/check_seq_equiv.py --selftest
"""
import argparse
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (file, old revision, plant anchor, replacement): the clean proof of FILE against REV must pass
# and the planted one must fail.
PLANTS = [
    ("src/pc9821/core/pc9821_gvram_arb.sv", "bf1b6650",
     "cpu_din_datmid[w_first_cap[1:0]]", "cpu_din_datmid[w_first_hold[1:0]]"),
    ("src/pc9821/core/pc9821_gvram_arb.sv", "bf1b6650",
     "(cap_arm ? (|lane_live_cap) : (|lane_live_hold))", "(|lane_live_hold)"),
]


def module_name(text):
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("module "):
            return s.split()[1].split("(")[0].split("#")[0].strip()
    sys.exit("no module declaration found")


def prove(rel, rev, plant=None, seq=2):
    old = subprocess.run(["git", "show", "%s:%s" % (rev, rel)], cwd=REPO,
                         capture_output=True, text=True)
    if old.returncode:
        sys.exit("git show failed: " + old.stderr)
    new = open(os.path.join(REPO, rel)).read()
    if plant:
        a, b = plant
        if new.count(a) != 1:
            sys.exit("plant anchor must occur exactly once: %s" % a)
        new = new.replace(a, b)
    name = module_name(new)
    old_t = old.stdout.replace("module %s" % name, "module eqv_old", 1)
    new_t = new.replace("module %s" % name, "module eqv_new", 1)
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "old.sv"), "w").write(old_t)
        open(os.path.join(tmp, "new.sv"), "w").write(new_t)
        script = ("read_verilog -sv old.sv new.sv; proc; opt_clean; memory -nomap; flatten; "
                  "equiv_make eqv_old eqv_new eq; hierarchy -top eq; "
                  "equiv_simple -seq %d; equiv_induct -seq %d; equiv_status -assert" % (seq, seq))
        r = subprocess.run(["yosys", "-p", script], cwd=tmp, capture_output=True, text=True)
    ok = r.returncode == 0 and "Equivalence successfully proven!" in r.stdout
    summary = [ln.strip() for ln in r.stdout.splitlines() if "are proven" in ln]
    return ok, (summary[-1] if summary else r.stdout[-1500:] + r.stderr[-800:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?")
    ap.add_argument("--old", default="bf1b6650")
    ap.add_argument("--plant", help="OLD=>NEW text mutation of the new file (must FAIL)")
    ap.add_argument("--seq", type=int, default=2)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        bad = 0
        for rel in sorted({p[0] for p in PLANTS}):
            rev = [p[1] for p in PLANTS if p[0] == rel][0]
            ok, msg = prove(rel, rev, seq=a.seq)
            print("%-45s %s  %s" % (rel, "PROVEN" if ok else "FAILED", msg))
            bad += not ok
        for rel, rev, x, y in PLANTS:
            ok, _ = prove(rel, rev, (x, y), a.seq)
            print("  plant %-60s %s" % (x[:60], "NOT caught" if ok else "caught"))
            bad += ok
        print("check_seq_equiv: selftest %s" % ("FAIL" if bad else "PASS"))
        sys.exit(1 if bad else 0)
    if not a.file:
        ap.error("a FILE (repo-relative) or --selftest is required")
    plant = tuple(a.plant.split("=>", 1)) if a.plant else None
    ok, msg = prove(a.file, a.old, plant, a.seq)
    print("check_seq_equiv: %s vs %s: %s (%s)" % (a.file, a.old, "PROVEN" if ok else "NOT proven", msg))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

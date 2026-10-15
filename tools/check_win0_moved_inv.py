#!/usr/bin/env python3
"""check_win0_moved_inv.py -- prove, by induction over the REAL pc9821_iobus, that its registered
`win0_sel_moved` equals `win0_sel != 8'h08` in every reachable cycle, the reset included
(docs/timing.md C7-head: the memory map and the subsystem read the flag in place of the compare,
and pc9821_system feeds it to z486 as win0_unmapped).

The tool pastes the assertion into a COPY of pc9821_iobus (the tree is never edited); the three
devices it instantiates (pc9821_dmac, pc9821_fdc, pc9821_mouse) are replaced by stubs built from
their own port lists, so their outputs are FREE (any value, any cycle) - a superset of the real
behaviour. Every top-level input, the reset included, is free. yosys `sat -tempinduct` proves the
assertion from a reset in the first step and by induction for every later step.

--selftest plants defects that must each make the proof FAIL.

  python3 tools/check_win0_moved_inv.py [--selftest]
"""
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IOBUS = "src/pc9821/core/pc9821_iobus.sv"
PKG = "src/pc9821/core/pc9821_ports_pkg.sv"
STUBS = [("src/pc9821/core/pc9821_dmac.sv", "pc9821_dmac"),
         ("src/pc9821/storage/pc9821_fdc.sv", "pc9821_fdc"),
         ("src/pc9821/input/pc9821_mouse.sv", "pc9821_mouse")]

PROP = r"""
  // ---- check_win0_moved_inv.py (pasted into a copy; never in the tree) ----
  always @* if (!reset) assert (win0_sel_moved == (win0_sel != 8'h08));
"""

PLANTS = [
    # the flag computed from the old value instead of the one being written
    ("win0_sel_moved <= (next_win0 != 8'h08);", "win0_sel_moved <= (win0_sel != 8'h08);"),
    # the wrong reset value
    ("win0_sel_moved <= 1'b0;    // (8'h08 != 8'h08)", "win0_sel_moved <= 1'b1;"),
    # win0_sel written somewhere the flag is not
    ("                win0_sel       <= next_win0;\n",
     "                win0_sel       <= next_win0 | 8'h01;\n"),
]


def balanced(src, i):
    """Index just past the parenthesised group that opens at src[i] == '('."""
    assert src[i] == "("
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
    raise ValueError("unbalanced")


def strip_initial(src):
    out, pos = [], 0
    for m in re.finditer(r"^\s*initial\s+begin\b", src, re.M):
        if m.start() < pos:
            continue
        depth, j = 0, m.end() - len("begin")
        for tok in re.finditer(r"\bbegin\b|\bend\b", src[j:]):
            depth += 1 if tok.group(0) == "begin" else -1
            if depth == 0:
                out.append(src[pos:m.start()])
                pos = j + tok.end()
                break
    out.append(src[pos:])
    return "".join(out)


def port_stub(rel, name):
    src = open(os.path.join(REPO, rel)).read()
    a = src.index("module " + name)
    i = a + len("module " + name)
    while src[i].isspace():
        i += 1
    if src[i] == "#":
        i = src.index("(", i)
        i = balanced(src, i)
        while src[i].isspace():
            i += 1
    b = balanced(src, i)
    return src[a:b] + ";\nendmodule\n"


def prove(plant=None):
    io = open(os.path.join(REPO, IOBUS)).read()
    if plant:
        a, b = plant
        if io.count(a) != 1:
            sys.exit("plant anchor must occur exactly once: %r" % a)
        io = io.replace(a, b)
    # yosys's parser takes a package import at file scope but not as a module item.
    imp = "  import pc9821_ports_pkg::*;\n"
    assert io.count(imp) == 1
    io = io.replace(imp, "")
    # the simulation-only blocks synthesis drops (`// translate_off` .. `// translate_on`)
    while "// translate_off" in io:
        a = io.index("// translate_off")
        io = io[:a] + io[io.index("// translate_on", a) + len("// translate_on"):]
    # the power-up `initial` blocks: the proof starts from a reset, not from a power-up image
    # (-set-init-undef), and yosys cannot evaluate their function-computed values
    io = strip_initial(io)
    k = io.rindex("endmodule")
    io = io[:k] + PROP + io[k:]
    text = (open(os.path.join(REPO, PKG)).read() + "\nimport pc9821_ports_pkg::*;\n" + io + "\n" +
            "".join(port_stub(r, n) for r, n in STUBS))
    os.makedirs(os.path.join(REPO, ".build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, ".build")) as tmp:
        open(os.path.join(tmp, "iobus.sv"), "w").write(text)
        script = ("read_verilog -sv -formal iobus.sv; hierarchy -top pc9821_iobus; proc; "
                  "chformal -lower; flatten; memory; opt_clean; setundef -undriven -anyseq; "
                  "opt -fast; sat -tempinduct -prove-asserts -set-init-undef -set-def-inputs "
                  "-set-def-formal -seq 1 -set-at 1 reset 1 -maxsteps 4 -verify")
        r = subprocess.run(["yosys", "-q", "-p", script], cwd=tmp, capture_output=True, text=True)
    return r.returncode == 0, r.stdout + r.stderr


def main():
    ok, log = prove()
    print("iobus win0_sel_moved == (win0_sel != 8'h08): %s" % ("PROVEN" if ok else "FAILED"))
    bad = 0 if ok else 1
    if not ok:
        print(log[-3000:])
    if "--selftest" in sys.argv:
        for p in PLANTS:
            pok, _ = prove(p)
            print("  plant %s: %s" % ("NOT caught" if pok else "caught", p[1].strip()[:60]))
            bad += pok
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

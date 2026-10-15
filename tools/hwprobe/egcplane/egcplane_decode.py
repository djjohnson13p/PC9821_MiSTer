#!/usr/bin/env python3
"""egcplane_decode.py - decode an EGCPLANE capture (EGCP.TXT).

Usage:
    python3 tools/hwprobe/egcplane/egcplane_decode.py EGCP.TXT [...]
    python3 tools/hwprobe/egcplane/egcplane_decode.py --selftest

EGCPLANE (egcplane.s) times each EGC shape with 0x04A0 enabling 1, 2, 3 and 4 planes:

    EGCP <SHAPE>P<n> UNITS=<sprites> ARTIC=<ticks> CLK50=<total> PER=<milli-clk/unit>

Each unit is one sprite = 16 EGC accesses (rows). ns = ARTIC * 1e9/307200 (the documented
307200 Hz ARTIC tick). CTRLEW / CTRLER are the loop-shell controls (write-only and
read+write); a shape's net = row - control. The verdict compares the net time at 1 plane
with 4 planes: a ratio near 1.00 means the EGC works on the planes in parallel; a ratio
near 4 (time growing with planes) means plane-serial.
"""
import re
import sys

NS_PER_TICK = 1e9 / 307_200
ACCS_PER_UNIT = 16
LINE_RE = re.compile(r"^EGCP\s+(\S+)\s+UNITS=(\d+)\s+ARTIC=(\d+)\s+CLK50=(\d+)\s+PER=(\d+)\s*$")
# shape -> control tag (read+write shapes use CTRLER)
SHAPES = {"EGC1400": "CTRLEW", "EGC0CF0": "CTRLEW",
          "EGC3100SP": "CTRLER", "EGC28F0SP": "CTRLER"}


def parse(text):
    rows, begin, end = {}, False, False
    for raw in text.splitlines():
        line = raw.rstrip("\r\n")
        begin |= "BEGIN:EGCPLANE" in line
        end |= "END:EGCPLANE" in line
        m = LINE_RE.match(line)
        if m:
            rows[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return rows, begin and end


def ns_unit(row):
    units, artic = row
    return artic * NS_PER_TICK / units


def report(name, text):
    rows, complete = parse(text)
    print(f"=== {name} ===")
    if not rows:
        print("  no EGCP rows found")
        return 1
    if not complete:
        print("  WARNING: no BEGIN/END:EGCPLANE pair - the run may have hung")
    for c in ("CTRLEW", "CTRLER"):
        if c in rows:
            print(f"  control {c}: {ns_unit(rows[c]):.0f} ns/sprite "
                  f"({ns_unit(rows[c]) / ACCS_PER_UNIT:.1f} ns/access)")
    print(f"\n  {'shape':<10} {'planes':>6} {'gross ns/acc':>13} {'net ns/acc':>11} {'net/1-plane':>12}")
    verdicts = []
    for shape, ctrl in SHAPES.items():
        net1 = None
        net = {}
        for n in (1, 2, 3, 4):
            tag = f"{shape}P{n}"
            if tag not in rows:
                continue
            gross = ns_unit(rows[tag]) / ACCS_PER_UNIT
            shell = ns_unit(rows[ctrl]) / ACCS_PER_UNIT if ctrl in rows else 0.0
            net[n] = gross - shell
            if n == 1:
                net1 = net[n]
            ratio = f"{net[n] / net1:.3f}" if net1 and net1 > 0 else "-"
            print(f"  {shape:<10} {n:>6} {gross:>13.1f} {net[n]:>11.1f} {ratio:>12}")
        if 1 in net and 4 in net and net[1] > 0:
            r = net[4] / net[1]
            kind = ("PARALLEL (flat)" if r < 1.15 else
                    "PLANE-SERIAL (grows with planes)" if r > 1.6 else "in between")
            verdicts.append(f"  {shape}: 4-plane/1-plane net = {r:.2f}  -> {kind}")
        print()
    print("  VERDICT (net of control; <1.15 flat, >1.6 serial):")
    print("\n".join(verdicts) if verdicts else "  (no complete shapes)")
    return 0


def selftest():
    def row(tag, units, ns_acc):
        artic = round(ns_acc * ACCS_PER_UNIT * units / NS_PER_TICK)
        return f"EGCP {tag} UNITS={units} ARTIC={artic} CLK50={artic*50000000//307200} PER=0"
    lines = ["BEGIN:EGCPLANE", row("CTRLEW", 2000, 300), row("CTRLER", 2000, 500)]
    for n in (1, 2, 3, 4):
        lines.append(row(f"EGC1400P{n}", 2000, 300 + 1000))        # flat
        lines.append(row(f"EGC3100SPP{n}", 2000, 500 + 400 * n))   # serial
    lines.append("END:EGCPLANE")
    rows, ok = parse("\r\n".join(lines))
    assert ok and len(rows) == 10, rows
    net = lambda t, c: ns_unit(rows[t]) / 16 - ns_unit(rows[c]) / 16
    assert abs(net("EGC1400P4", "CTRLEW") - 1000) < 2
    assert abs(net("EGC3100SPP4", "CTRLER") / net("EGC3100SPP1", "CTRLER") - 4) < 0.01
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        report("selftest", "\n".join(lines))
    out = buf.getvalue()
    assert "EGC1400: 4-plane/1-plane net = 1.00" in out and "PARALLEL" in out, out
    assert "EGC3100SP: 4-plane/1-plane net = 4.00" in out and "PLANE-SERIAL" in out, out
    print("egcplane_decode selftest: PASS")
    return 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    rc = 0
    for p in argv[1:]:
        with open(p, errors="replace") as fh:
            rc |= report(p, fh.read())
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

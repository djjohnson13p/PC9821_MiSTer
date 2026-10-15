#!/usr/bin/env python3
"""The numbers one fit is judged by, read from its output_files/ (and its build log).

    tools/fit_metrics.py <dir> [<dir> ...]     # a seed directory: <dir>/output_files + build.log

Every value comes from Quartus's own reports, with the clock NAMED as STA names it:
general[0] is clk_sys (z486_mister.sdc's pc9821_clk_sys), which since the split-clock removal
(2026-10-09) is the SDRAM controller's clock too. In a fit of an
OLDER split-clock tree general[1] was clk_sdram; in a current fit general[1] is the SDRAM pin clock,
which has no register endpoints and so never appears in the summary - clk_sdram_* are then absent. The STA summary is the slow corner only (the qsf sets
TIMEQUEST_MULTICORNER_ANALYSIS OFF), which is what every fit in this tree has been ranked by.

  labs            fit.rpt's `Total LABs: partially or completely used` (THE binding resource)
  alms_needed     fit.summary's `Logic utilization (in ALMs)` (= ALMs needed [=A-B+C])
  registers       fit.summary's `Total registers`
  interconnect    fit.rpt's peak interconnect usage, total %
  clk_sys_setup / clk_sys_tns / clk_sys_hold         general[0]
  clk_sdram_setup / clk_sdram_tns / clk_sdram_hold   general[1], split-clock fits only (absent otherwise)
  sdram_io_setup / sdram_io_tns / sdram_io_hold      PC9821_SDRAM_CLK: the SDRAM PIN interface (the
                   SDC's set_output_delay/set_input_delay on SDRAM_*), which no core clock's
                   summary row includes - a pin that loses its fast I/O register shows up only here
  other_setup      the worst setup slack of every other clock in the summary (framework PLLs)
  map_min / fit_min / sta_min                        flow.rpt's elapsed time per module
  internal_errors  every distinct `Internal Error: Sub-system: X, File: F, Line: L` in the log
  dtm_fallback     the build re-fitted after the DTM crash (tools/build.py's fallback)
  crash_stage      where the first internal error struck (the last `Info (NNN): Starting ...`
                   or module banner before it)
  rbf              the bitstream exists
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROJECT = "z486_mister"
# The core PLL's outputs (pll_audio also has a general[0], so the instance is part of the key).
CLOCKS = (("clk_sys", "emu|pll|pll_inst|altera_pll_i|general[0]"),
          ("clk_sdram", "emu|pll|pll_inst|altera_pll_i|general[1]"),
          ("sdram_io", "PC9821_SDRAM_CLK"))
INTERNAL_RE = re.compile(r"Internal Error: Sub-system: (\w+), File: (\S+), Line: (\d+)")
# A crash that is not an assertion: "*** Fatal Error: Segment Violation at (nil)".
FATAL_RE = re.compile(r"\*\*\* Fatal Error: (.*)")
STAGE_RE = re.compile(r"Info(?: \(\d+\))?: (Start(?:ing|ed) [^.]*|Running Quartus Prime [A-Za-z &]+|"
                      r"Fitter \w+(?: \w+)? operations (?:beginning|ending)|Delay annotation completed)")


def _read(path: Path) -> str | None:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def sta_numbers(text: str) -> dict:
    """{clk_sys_setup, clk_sys_tns, clk_sys_hold, ...} from a sta.summary."""
    out: dict = {}
    for block in re.split(r"\n\s*\n", text):
        m = re.search(r"Type\s*:\s*(Setup|Hold|Recovery|Removal)\s+'([^']*)'", block)
        if not m:
            continue
        kind, clock = m.group(1).lower(), m.group(2)
        slack = re.search(r"Slack\s*:\s*(-?\d+\.\d+)", block)
        tns = re.search(r"TNS\s*:\s*(-?\d+\.\d+)", block)
        if kind == "setup" and slack and not any(key in clock for _, key in CLOCKS):
            out["other_setup"] = min(out.get("other_setup", 1e9), float(slack.group(1)))
        for name, key in CLOCKS:
            if key in clock:
                if slack:
                    out[f"{name}_{kind}"] = float(slack.group(1))
                if tns and kind == "setup":
                    out[f"{name}_tns"] = float(tns.group(1))
    return out


def elapsed_minutes(flow_rpt: str) -> dict:
    out = {}
    for label, key in (("Analysis & Synthesis", "map_min"), ("Fitter", "fit_min"),
                       ("TimeQuest Timing Analyzer", "sta_min")):
        m = re.search(rf";\s*{re.escape(label)}\s*;\s*(\d+):(\d+):(\d+)\s*;", flow_rpt)
        if m:
            h, mi, s = (int(x) for x in m.groups())
            out[key] = round(h * 60 + mi + s / 60, 1)
    return out


def log_numbers(log: str) -> dict:
    out: dict = {}
    errors = []
    stage = ""
    first_stage = ""
    for line in log.splitlines():
        sm = STAGE_RE.search(line)
        if sm:
            stage = sm.group(1).strip()
        em = INTERNAL_RE.search(line)
        fm = FATAL_RE.search(line)
        if em or fm:
            sig = (f"{em.group(1)} {em.group(2).rsplit('/', 1)[-1]}:{em.group(3)}" if em
                   else f"FATAL {fm.group(1).strip()}")
            if sig not in errors:
                errors.append(sig)
            if not first_stage:
                first_stage = stage
    out["internal_errors"] = errors
    if first_stage:
        out["crash_stage"] = first_stage
    # tools/build.py's DTM fallback: its banner (a detached build's log) or its own command, a
    # quartus_fit that reads the qsf (the flow's runs with --read_settings_files=off).
    out["dtm_fallback"] = ("re-fitting the mapped database" in log
                           or re.search(r"^\$ .*quartus_fit z486_mister -c z486_mister\s*$", log,
                                        re.MULTILINE) is not None)
    return out


def fit_metrics(seed_dir: Path) -> dict:
    """The metrics of one fit; seed_dir holds output_files/ (and usually build.log)."""
    seed_dir = Path(seed_dir)
    of = seed_dir / "output_files" if (seed_dir / "output_files").is_dir() else seed_dir
    out: dict = {"rbf": (of / f"{PROJECT}.rbf").exists()}
    if (sta := _read(of / f"{PROJECT}.sta.summary")):
        out.update(sta_numbers(sta))
    if (fit := _read(of / f"{PROJECT}.fit.summary")):
        m = re.search(r"Logic utilization \(in ALMs\)\s*:\s*([\d,]+)", fit)
        if m:
            out["alms_needed"] = int(m.group(1).replace(",", ""))
        m = re.search(r"Total registers\s*:\s*([\d,]+)", fit)
        if m:
            out["registers"] = int(m.group(1).replace(",", ""))
    rpt = of / f"{PROJECT}.fit.rpt"
    if rpt.exists():
        with rpt.open(errors="replace") as handle:
            for line in handle:
                if "Total LABs:  partially or completely used" in line and "labs" not in out:
                    m = re.search(r";\s*([\d,]+)\s*/\s*([\d,]+)", line)
                    if m:
                        out["labs"] = int(m.group(1).replace(",", ""))
                elif "Peak interconnect usage (total/H/V)" in line and "interconnect" not in out:
                    m = re.search(r";\s*([\d.]+)%", line)
                    if m:
                        out["interconnect"] = float(m.group(1))
    if (flow := _read(of / f"{PROJECT}.flow.rpt")):
        out.update(elapsed_minutes(flow))
    for name in ("build.log", "build.attempt1.log"):
        if (log := _read(seed_dir / name)):
            out.update(log_numbers(log))
            break
    return out


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    for d in argv:
        print(json.dumps({"dir": d, **fit_metrics(Path(d))}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

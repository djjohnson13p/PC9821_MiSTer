#!/usr/bin/env python3
"""Configure the z486 MiSTer Quartus build: clocks, PLL, constraints, compile-time knobs.

A BUILD CONFIGURATION is one value with these fields, and this script is the ONE place that
decides it:

  clk_sys_hz          the core clock (PLL output 0) and z486_mister.sv's CLOCK_RATE_HZ. The SDRAM
                      controller and its PHY run on it too: there is no separate SDRAM clock (the
                      split-clock configuration - sdram_hz, sdram_sync, --sdram-mhz,
                      --no-sdram-sync - was removed on 2026-10-09, owner decision)
  sdram_phase_ps      output 1's phase (the SDRAM_CLK pin clock, clk_sys's frequency). DERIVED by
                      default from the SDC's SDRAM I/O model for clk_sys
                      (tools/profile_gen.py, derive_sdram_phase); an explicit value overrides
  trace_en            TRACE_EN (the instruction trace ring)
  perf_log_en         PERF_LOG_EN (the serial console's performance-log telemetry)
  io_latency_profile  IO_LATENCY_PROFILE (0 = min bus, 1/2 = the faithful class table)
  mpu_en              MPU_EN, and with it CONF_STR_HEADER (the UART/MIDI OSD declaration)
  cdrom_en            CDROM_EN, and with it CONF_STR_DISKS + CONF_STR_EJECTS + HPS_VDNUM (the
                      CD-ROM's OSD slot 4 and its Eject on status[11]); ON in every preset
                      since 2026-10-10, --no-cdrom the opt-out
  cdrom_audio_en      CDROM_AUDIO_EN: the CD drive's CD-DA player (meaningful only with cdrom_en)
  cdrom_log_en        CDROM_LOG_EN: the CD drive's command log on the debug UART (a debug instrument;
                      meaningful only with cdrom_en and without perf_log_en, which owns that UART source)
  dbg                 the DEBUG-UART INSTRUMENT FRAMEWORK, every part off in every preset (see the
                      "debug instruments" block below): cpu (the sampler), snoop LO:HI (the
                      memory window), gdc (the display log), the trace's trigger (trig, trig2,
                      arm_s, post) and sample_ms; the CD log is cdrom_log_en (--dbg-cd). All are
                      compile-time parameters; nothing is built unless asked for
  alsa_en             the framework's HPS (Linux) audio input; off = VERILOG_MACRO MISTER_DISABLE_ALSA
  yc_en               the framework's composite/S-Video encoder; off = VERILOG_MACRO MISTER_DISABLE_YC
  fit_technique       the qsf's OPTIMIZATION_TECHNIQUE
  qsf_set             further fitter/synthesis qsf assignments, NAME -> VALUE: each replaces the
                      SPEED stack's row of that name (the value @default drops the row, so
                      Quartus's own default applies) or is appended to the managed block. Every
                      name/value pair is checked by Quartus itself (quartus_sh's
                      set_global_assignment, in the container) when the configuration is applied

The seven named PROFILES below are presets of that value. Any field of a preset can be
overridden on the command line or from a profile file (JSON, or TOML), and --custom starts
from base's values under the name 'custom'. Applying a configuration:

  * rewrites the top level's localparams (CLOCK_RATE_HZ, TRACE_EN,
    PERF_LOG_EN, IO_LATENCY_PROFILE, MPU_EN, CONF_STR_HEADER, CDROM_EN,
    CONF_STR_DISKS, CONF_STR_EJECTS, HPS_VDNUM);
  * rewrites the qsf's managed block: the production SPEED fit stack with the configured
    technique, the framework feature macros (MISTER_DISABLE_ALSA / MISTER_DISABLE_YC for a
    feature that is off), and the configuration itself as a machine-readable '# Active config:' JSON
    record (the qsf is hashed into every fit's attribution, so the record travels with it);
  * GENERATES the main PLL into rtl/ (qmegawiz in the Quartus container, cached under
    .build/pll-cache/, read back and verified) and the constraints into z486_mister.sdc
    (tools/profile/z486_mister.sdc.in with its computed block for the configured clock). Both
    outputs are git-ignored; the templates are the source.

    ./build_profile.py base                       # 80 MHz clk_sys, SDRAM on clk_sys - the default, shipping build
    ./build_profile.py trace                      # base + trace ring + perf log, AREA fit (debug)
    ./build_profile.py iofaithful                 # base + the FAITHFUL I/O class table
    ./build_profile.py midilink                   # base + the MPU-PC98II MIDI card
    ./build_profile.py lightoc                    # an ALIAS of base (the old shipping preset's name)
    ./build_profile.py mediumoc                   # 100 MHz clk_sys and SDRAM (past timing closure)
    ./build_profile.py heavyoc                    # 120 MHz clk_sys and SDRAM (at the SDRAM's limit)
    ./build_profile.py base --trace
    ./build_profile.py --custom --clk-sys-mhz 90  # the SDRAM follows clk_sys
    ./build_profile.py --profile-file sweep.toml  # every field above, plus 'preset'/'name'
    ./build_profile.py base --sdram-phase-ps 8000 # pin the phase instead of deriving it
    ./build_profile.py base --qsf-set PHYSICAL_SYNTHESIS_EFFORT=NORMAL --qsf-set 'OPTIMIZATION_MODE=AGGRESSIVE AREA'
    ./build_profile.py --check                    # top level, qsf, PLL and SDC all agree
    ./build_profile.py --selftest                 # --check must catch planted disagreements
    ./build_profile.py --pll-into DIR             # generate DIR's active PLL + SDC into DIR
    ./build_profile.py --print-config [args]      # the resolved configuration as JSON
    ./build_profile.py --quartus-check [args]     # Quartus's verdict on each qsf_set override
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT = "z486_mister"
PROJECT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_DIR / "tools"))
import profile_gen as pg  # noqa: E402

QSF_NAME = "z486_mister.qsf"
TOP_NAME = "z486_mister.sv"
SDC_NAME = "z486_mister.sdc"

PROFILE_BLOCK_BEGIN = "# BEGIN build_profile.py settings"
PROFILE_BLOCK_END = "# END build_profile.py settings"
CONFIG_RECORD_PREFIX = "# Active config: "

FIT_TECHNIQUES = ("SPEED", "AREA", "BALANCED")
# clk_sys IS the SDRAM controller's clock, so its range is the controller's: sdram.v derives its
# timing up to 133 MHz, and the board's SDRAM part has a hard limit at about 120 MHz (owner,
# 2026-10-09), which heavyoc sits at.
CLK_SYS_MIN_HZ = 25_000_000
CLK_SYS_MAX_HZ = 133_000_000
SDRAM_PART_LIMIT_HZ = 120_000_000
# The split-clock configuration's fields, removed on 2026-10-09.
RETIRED_FIELDS = ("sdram_hz", "sdram_mhz", "sdram_sync")
RETIRED_LOCALPARAMS = ("SDRAM_RATE_HZ", "SDRAM_SYNC")


@dataclasses.dataclass(frozen=True)
class Config:
    name: str
    description: str
    # The core clock, which the SDRAM controller and its PHY run on as well (one clock domain).
    clk_sys_hz: int
    # None = derived from the I/O model for clk_sys (the default); an int pins it.
    sdram_phase_ps: int | None = None
    # Rewrites TRACE_EN. False for every shipped profile: the shipped bitstream must not carry
    # the trace's ring or its logic; True only for 'trace'.
    trace_en: bool = False
    # Rewrites PERF_LOG_EN: the serial console's watchdog/PRF/GFX telemetry. 'trace' only.
    perf_log_en: bool = False
    # Rewrites IO_LATENCY_PROFILE, which pc9821_system forwards into pc9821_iobus. 0 is the min
    # profile (the shipped fast bus); 1/2 the faithful bus. The unselected table const-folds.
    io_latency_profile: int = 0
    # Rewrites MPU_EN (and CONF_STR_HEADER, which follows it). Off except 'midilink': the
    # MPU-PC98II costs 26-50 LABs against the measured ~40 free.
    mpu_en: bool = False
    # (`ide_disk2_en`, the second IDE hard disk, was RETIRED on 2026-10-08 with the disk itself:
    # a record that still carries the key parses, the key is ignored, and `--check` then reports
    # the block as not the one its record renders until the configuration is re-applied.)
    # Rewrites CDROM_EN, and with it the disk OSD entries (CONF_STR_DISKS) and hps_io's slot
    # count (HPS_VDNUM): the CD-ROM's "S4" slot and its ATAPI drive (pc9821_atapi, bank 1's
    # master; the hard disk is bank 0's master with or without it). ON in every preset (owner, 2026-10-10: "default to
    # enabling the CD across the board"); --no-cdrom is the opt-out.
    cdrom_en: bool = True
    # Rewrites CDROM_AUDIO_EN: the CD drive's CD-DA player and the cdda ring behind it. It only
    # means something with cdrom_en (the line is written as cdrom_en AND this), so the default
    # True gives a full drive whenever the drive is on, and --no-cdrom-audio a data-only one.
    cdrom_audio_en: bool = True
    # Rewrites CDROM_LOG_EN: a DEBUG INSTRUMENT, the drive's conversation as binary records on the
    # debug UART (pc9821_atapi LOG_EN). Off in every preset; the
    # line is written as cdrom_en AND this AND NOT perf_log_en (the telemetry owns that source).
    cdrom_log_en: bool = False
    # The two framework features sys/sys_top.v compiles out under a VERILOG_MACRO. OFF in every
    # preset (owner, 2026-10-08): MidiLink's synths are physical hardware, so the HPS Linux audio
    # path (alsa.sv + its DDR reader + the audio_out mix input) has nothing to carry, and the
    # composite/S-Video encoder (yc_out) is not used. Measured in a fit: alsa -265 ALMs, yc_out
    # -230, their sys_top glue -53 = -548 ALMs. On = the macro
    # line is absent and the framework builds the feature as upstream ships it.
    alsa_en: bool = False
    yc_en: bool = False
    # The managed qsf block's OPTIMIZATION_TECHNIQUE. AREA in every preset since 2026-10-12
    # (docs/trade-candidates.md T40): on the storage-pass tree, seeds 2-7 per side, AREA placed
    # 38,947 ALMs / 4,170 LABs mean vs SPEED's 39,337 / 4,181, clk_sys slack mean -7.23 /
    # worst -7.44 ns, and its seed-2 RBF passed the full hardware regression on two MiSTers. The
    # design is LAB-bound, so the technique that frees LABs is the default. SPEED stays
    # selectable (--fit-technique SPEED) for A/Bs.
    fit_technique: str = "AREA"
    # Further qsf assignments over the SPEED stack, as sorted (NAME, VALUE) pairs (values
    # unquoted; render_qsf_block quotes a multi-word one). Empty for every preset unless its
    # entry says otherwise; recorded in the '# Active config' JSON only when non-empty, so a
    # record written before the field existed means exactly what it meant then.
    qsf_set: tuple[tuple[str, str], ...] = ()
    # The debug-UART instrument framework (pc9821_dbg_cpu / pc9821_gdc_log / pc9821_dbg_mux; AGENTS.md
    # "Testing on a real MiSTer"), as sorted (KEY, VALUE)
    # pairs of normalize_dbg's keys. EMPTY for every preset: each part is a compile-time parameter
    # that builds nothing when absent. Recorded in the '# Active config' JSON only when non-empty.
    dbg: tuple[tuple[str, object], ...] = ()
    # The preset this configuration started from (None for a preset itself).
    preset: str | None = None

    def __post_init__(self) -> None:
        # One canonical form (sorted, unquoted), so equal overrides are equal configurations.
        object.__setattr__(self, "qsf_set", normalize_qsf_set(self.qsf_set))
        object.__setattr__(self, "dbg", normalize_dbg(self.dbg))

    @property
    def dbg_params(self) -> dict:
        """The debug framework's localparam values (see dbg_localparams)."""
        return dbg_param_values(dict(self.dbg))

    @property
    def dbg_active(self) -> bool:
        """Any instrument that takes the UART arm besides the CD log."""
        return bool(self.dbg)

    @property
    def conf_str_header(self) -> str:
        """The OSD header's first element, for z486_mister.sv's CONF_STR_HEADER.

        It follows mpu_en rather than being a second knob, so there is ONE decision point. It
        cannot be built in the RTL from MPU_EN: a string ternary is zero-padded to the longer
        branch's width on the high side, so the false branch would carry leading NULs and move
        the base bitstream (z486_mister.sv's CONF_STR_HEADER comment has the measurement).
        """
        return "PC9821;UART115200(Turbo 115200),MIDI;" if self.mpu_en else "PC9821;;"

    @property
    def conf_str_disks(self) -> str:
        """z486_mister.sv's CONF_STR_DISKS: the OSD's FDD2 mount entry, plus the CD-ROM's.

        A profile-rewritten LINE for the same reason as conf_str_header: a string ternary on
        CDROM_EN would be NUL-padded on the high side. Never empty (an empty Verilog string is a
        NUL byte), so the always-present FDD2 entry leads it.
        """
        return "S2,D88FDDHDM,Mount FDD2;" + ("S4,ISOPCD,Mount CD-ROM;" if self.cdrom_en else "")

    @property
    def conf_str_ejects(self) -> str:
        """z486_mister.sv's CONF_STR_EJECTS: FDD2's Eject, plus the CD-ROM's (status[11]).

        The ejects are a group after the mounts (the owner's OSD layout), so the CD's needs its
        own rewritten line beside CONF_STR_DISKS. FDD2's always-present entry leads it so the
        string is never empty. status[11] was only ever a T trigger (the removed second disk's
        Eject), so reusing it cannot meet a saved option value.
        """
        return "T[10],Eject FDD2;" + ("T[11],Eject CD-ROM;" if self.cdrom_en else "")

    @property
    def hps_vdnum(self) -> int:
        """hps_io's VDNUM: 0 HDD, 1-2 FDD; with the CD, 4 CD and slot 3 an unused, tied-off index."""
        return 5 if self.cdrom_en else 3

    def phase(self) -> tuple[int, str]:
        if self.sdram_phase_ps is not None:
            return self.sdram_phase_ps, "override"
        return pg.derive_sdram_phase(self.clk_sys_hz)["phase_ps"], "derived"

    def pll_request(self) -> pg.PllRequest:
        return pg.PllRequest(self.clk_sys_hz, self.phase()[0])

    def record(self) -> dict:
        """The machine-readable configuration: every field a fit depends on, phase resolved."""
        phase, source = self.phase()
        rec = {
            "name": self.name,
            "preset": self.preset,
            "clk_sys_hz": self.clk_sys_hz,
            "sdram_phase_ps": phase,
            "sdram_phase_source": source,
            "trace_en": self.trace_en,
            "perf_log_en": self.perf_log_en,
            "io_latency_profile": self.io_latency_profile,
            "mpu_en": self.mpu_en,
            "cdrom_en": self.cdrom_en,
            "cdrom_audio_en": self.cdrom_audio_en,
            "cdrom_log_en": self.cdrom_log_en,
            "alsa_en": self.alsa_en,
            "yc_en": self.yc_en,
            "fit_technique": self.fit_technique,
        }
        if self.qsf_set:
            rec["qsf_set"] = dict(self.qsf_set)
        if self.dbg:
            rec["dbg"] = dict(self.dbg)
        return rec

    def record_json(self) -> str:
        return json.dumps(self.record(), sort_keys=True, separators=(",", ":"))

    def knobs(self) -> tuple:
        """Everything that reaches the build, for comparing configurations."""
        return (self.clk_sys_hz, self.phase(), self.trace_en,
                self.perf_log_en, self.io_latency_profile, self.mpu_en, self.cdrom_en,
                self.cdrom_audio_en, self.cdrom_log_en, self.alsa_en, self.yc_en, self.fit_technique,
                self.qsf_set, self.dbg)

    def validate(self) -> list[str]:
        problems = []
        if not re.fullmatch(r"\w+", self.name):
            problems.append(f"profile name {self.name!r} must be a single word (letters, digits, _)")
        if not CLK_SYS_MIN_HZ <= self.clk_sys_hz <= CLK_SYS_MAX_HZ:
            problems.append(f"clk_sys {self.clk_sys_hz:_} Hz is outside "
                            f"{CLK_SYS_MIN_HZ // 10**6}..{CLK_SYS_MAX_HZ // 10**6} MHz: it is also "
                            "the SDRAM controller's clock, and sdram.v's timing derivation tops out "
                            "at 133 MHz")
        if self.io_latency_profile not in (0, 1, 2):
            problems.append(f"io_latency_profile {self.io_latency_profile} is not 0, 1 or 2")
        if self.fit_technique not in FIT_TECHNIQUES:
            problems.append(f"fit_technique {self.fit_technique!r} is not one of {FIT_TECHNIQUES}")
        problems += qsf_set_problems(self.qsf_set)
        problems += dbg_problems(self)
        if self.sdram_phase_ps is not None:
            period_ps = 1e12 / self.clk_sys_hz
            if not 0 < self.sdram_phase_ps < period_ps:
                problems.append(
                    f"sdram_phase_ps {self.sdram_phase_ps} is outside (0, {period_ps:.0f}) ps: the "
                    "SDC's I/O edge pairing (and its DQ setup-2 count) assume a phase inside one "
                    "clock period")
        return problems


# The production fit's aggressive SPEED stack, used by EVERY configuration (no seed is pinned
# here so the seed sweep can vary it); fit_technique replaces its OPTIMIZATION_TECHNIQUE row.
SPEED_FIT_ASSIGNMENTS: tuple[tuple[str, str], ...] = (
    ("OPTIMIZE_POWER_DURING_FITTING", "OFF"),
    ("FINAL_PLACEMENT_OPTIMIZATION", "ALWAYS"),
    ("FITTER_EFFORT", '"AUTO FIT"'),
    ("ENABLE_BENEFICIAL_SKEW_OPTIMIZATION", "ON"),
    ("OPTIMIZATION_MODE", '"HIGH PERFORMANCE EFFORT"'),
    ("ALLOW_POWER_UP_DONT_CARE", "ON"),
    ("QII_AUTO_PACKED_REGISTERS", '"SPARSE AUTO"'),
    ("ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION", "ON"),
    ("PHYSICAL_SYNTHESIS_COMBO_LOGIC", "ON"),
    ("PHYSICAL_SYNTHESIS_EFFORT", "EXTRA"),
    ("PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION", "ON"),
    ("PHYSICAL_SYNTHESIS_REGISTER_RETIMING", "ON"),
    ("OPTIMIZATION_TECHNIQUE", "SPEED"),
    ("MUX_RESTRUCTURE", "ON"),
    ("REMOVE_REDUNDANT_LOGIC_CELLS", "ON"),
    ("AUTO_DELAY_CHAINS_FOR_HIGH_FANOUT_INPUT_PINS", "ON"),
    ("PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA", "ON"),
    ("ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP", "ON"),
    ("SYNTH_GATED_CLOCK_CONVERSION", "ON"),
    # OFF since 2026-10-09: ON crashed Quartus 17.0.2 (DTM
    # dtm_node.cpp:772) on the CD, trace (AREA) and 80/100 lightoc netlists, and OFF reads
    # ~40 fewer LABs on base and 80/80 lightoc with clk_sys no worse, over 5-8 seeds a side.
    ("PRE_MAPPING_RESYNTHESIS", "OFF"),
    ("ROUTER_CLOCKING_TOPOLOGY_ANALYSIS", "ON"),
    ("ECO_OPTIMIZE_TIMING", "ON"),
    ("PERIPHERY_TO_CORE_PLACEMENT_AND_ROUTING_OPTIMIZATION", "ON"),
    ("PHYSICAL_SYNTHESIS_ASYNCHRONOUS_SIGNAL_PIPELINING", "ON"),
    ("ALM_REGISTER_PACKING_EFFORT", "LOW"),
    ("OPTIMIZE_POWER_DURING_SYNTHESIS", "OFF"),
    ("ROUTER_REGISTER_DUPLICATION", "ON"),
    ("FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION", "ALWAYS"),
)
CONTROLLED_ASSIGNMENTS = frozenset(name for name, _ in SPEED_FIT_ASSIGNMENTS)
FIT_TECHNIQUE_ASSIGNMENT = "OPTIMIZATION_TECHNIQUE"

# ---- debug instruments: the debug-UART framework -------------------------------------------
# Every part is a compile-time parameter of pc9821_system (z486_mister.sv's DBG_* localparams),
# OFF in every preset, and the unselected part does not exist in the netlist. They share the
# debug UART with pc9821_atapi's command log (cdrom_log_en, --dbg-cd) through pc9821_dbg_mux, which
# interleaves them on record boundaries, and tools/decode_dbglog.py reads the one stream.
#
#   cpu        --dbg-cpu           pc9821_dbg_cpu's sampler: CS:EIP, INTA counts per vector, PIC
#                                  state, VSYNC and port events, every sample_ms (default 10)
#   snoop      --dbg-snoop LO:HI   its memory snoop: every CPU write into [LO, HI) and every read
#                                  beat from it (physical addresses, hex)
#   gdc        --dbg-gdc           pc9821_gdc_log: the display programming (alias --gdc-log)
#   trig       --dbg-trig SPEC     its frozen instruction trace and the trigger that freezes it:
#                                  pc:CS:EIP (first issue there), wr:ADDR (first CPU write covering
#                                  that byte) or reload:ADDR (a nonzero 16-bit word written after a
#                                  zero one - the pn-stall stub-header reload)
#   trig2      --dbg-trig2 LO:HI   a second stage: the trigger only arms it, and the first CPU write
#                                  into [LO, HI) after it freezes the trace
#   arm_s      --dbg-arm-s N       nothing triggers before N seconds of uptime (boot traffic)
#   post       --dbg-post N        issues recorded after the final trigger (default 32)
#   sample_ms  --dbg-sample-ms N   the sampler's period in ms (1..255, default 10)
DBG_FLAGS = ("cpu", "gdc")
DBG_VALUES = ("snoop", "trig", "trig2", "sample_ms", "arm_s", "post")
DBG_DEFAULTS = {"sample_ms": 10, "arm_s": 0, "post": 32}
DBG_KINDS = {"pc": 1, "wr": 2, "reload": 3}


def _hex(text: str, what: str) -> int:
    try:
        return int(str(text).strip(), 16)
    except ValueError:
        raise SystemExit(f"{what}: {text!r} is not a hexadecimal number")


def parse_dbg_range(text, what: str) -> tuple[int, int]:
    """'LO:HI' (hex, optional 0x) -> (lo, hi) with 0 <= lo < hi <= 2**32."""
    lo, sep, hi = str(text).partition(":")
    if not sep:
        raise SystemExit(f"{what}: expected LO:HI (hex physical addresses), got {text!r}")
    lo, hi = _hex(lo, what), _hex(hi, what)
    if not 0 <= lo < hi <= 1 << 32:
        raise SystemExit(f"{what}: need 0 <= LO < HI <= 0x100000000, got {lo:#x}:{hi:#x}")
    return lo, hi


def parse_dbg_trig(text) -> tuple[str, int, int]:
    """'pc:CS:EIP' | 'wr:ADDR' | 'reload:ADDR' (hex) -> (kind name, cs, address)."""
    parts = str(text).strip().lower().split(":")
    kind = parts[0]
    if kind not in DBG_KINDS:
        raise SystemExit(f"--dbg-trig {text!r}: the kind is one of {', '.join(DBG_KINDS)} "
                         "(pc:CS:EIP, wr:ADDR, reload:ADDR)")
    if kind == "pc":
        if len(parts) != 3:
            raise SystemExit(f"--dbg-trig {text!r}: pc takes CS:EIP (pc:CS:EIP, hex)")
        cs, addr = _hex(parts[1], "--dbg-trig CS"), _hex(parts[2], "--dbg-trig EIP")
        if not 0 <= cs <= 0xFFFF or not 0 <= addr <= 0xFFFFFFFF:
            raise SystemExit(f"--dbg-trig {text!r}: CS is 16 bits and EIP 32")
        return kind, cs, addr
    if len(parts) != 2:
        raise SystemExit(f"--dbg-trig {text!r}: {kind} takes one address ({kind}:ADDR, hex)")
    addr = _hex(parts[1], "--dbg-trig ADDR")
    if not 0 <= addr <= 0xFFFFFFFF:
        raise SystemExit(f"--dbg-trig {text!r}: the address is 32 bits")
    return kind, 0, addr


def normalize_dbg(items) -> tuple[tuple[str, object], ...]:
    """A dict or (KEY, VALUE) pairs -> the canonical sorted pairs: a flag only when on, a value
    only when it differs from its default, ranges and triggers re-rendered in one hex form."""
    pairs = items.items() if isinstance(items, dict) else items
    out: dict[str, object] = {}
    for key, value in pairs:
        key = str(key).strip().lower()
        if key not in DBG_FLAGS + DBG_VALUES:
            raise SystemExit(f"dbg: unknown key {key!r}; allowed: {', '.join(DBG_FLAGS + DBG_VALUES)}")
        if value is None:
            continue
        if key in DBG_FLAGS:
            if bool(value):
                out[key] = True
        elif key in ("snoop", "trig2"):
            lo, hi = parse_dbg_range(value, f"dbg {key}")
            out[key] = f"{lo:#x}:{hi:#x}"
        elif key == "trig":
            kind, cs, addr = parse_dbg_trig(value)
            out[key] = f"pc:{cs:#x}:{addr:#x}" if kind == "pc" else f"{kind}:{addr:#x}"
        else:
            try:
                number = int(value)
            except (TypeError, ValueError):
                raise SystemExit(f"dbg {key}: {value!r} is not an integer")
            if number != DBG_DEFAULTS[key]:
                out[key] = number
    return tuple(sorted(out.items()))


def dbg_param_values(dbg: dict) -> dict:
    """The framework's localparam values for a normalized dbg dict."""
    lo, hi = parse_dbg_range(dbg["snoop"], "dbg snoop") if "snoop" in dbg else (0, 0)
    lo2, hi2 = parse_dbg_range(dbg["trig2"], "dbg trig2") if "trig2" in dbg else (0, 0)
    kind, cs, addr = parse_dbg_trig(dbg["trig"]) if "trig" in dbg else ("", 0, 0)
    return {
        "gdc": int(bool(dbg.get("gdc"))), "cpu": int(bool(dbg.get("cpu"))),
        "sample_ms": dbg.get("sample_ms", DBG_DEFAULTS["sample_ms"]),
        "snoop_en": int("snoop" in dbg), "snoop_lo": lo, "snoop_hi": hi & 0xFFFFFFFF if hi < 1 << 32 else 0xFFFFFFFF,
        "trig_kind": DBG_KINDS.get(kind, 0), "trig_addr": addr, "trig_cs": cs,
        "trig2_lo": lo2, "trig2_hi": hi2 & 0xFFFFFFFF if hi2 < 1 << 32 else 0xFFFFFFFF,
        "arm_s": dbg.get("arm_s", DBG_DEFAULTS["arm_s"]), "post": dbg.get("post", DBG_DEFAULTS["post"]),
    }


def dbg_problems(config) -> list[str]:
    dbg = dict(config.dbg)
    problems = []
    if not dbg:
        return problems
    if config.trace_en or config.perf_log_en:
        problems.append("dbg: the debug instruments share the UART arm with the trace/telemetry "
                        f"(trace_en {config.trace_en}, perf_log_en {config.perf_log_en}), whose bytes "
                        "would cut a record in two: build the instruments without them")
    if "trig2" in dbg and "trig" not in dbg:
        problems.append("dbg: trig2 (a second stage) needs trig (the first)")
    for key, lo, hi in (("sample_ms", 1, 255), ("arm_s", 0, 1023), ("post", 0, 65535)):
        if key in dbg and not lo <= dbg[key] <= hi:
            problems.append(f"dbg: {key} {dbg[key]} is outside {lo}..{hi}")
    if "sample_ms" in dbg and "cpu" not in dbg:
        problems.append("dbg: sample_ms means something only with the sampler (cpu)")
    if ("arm_s" in dbg or "post" in dbg) and "trig" not in dbg:
        problems.append("dbg: arm_s / post mean something only with a trigger (trig)")
    return problems


def dbg_localparams(config) -> list[tuple[str, str, str]]:
    """(name, regex, line) for the top level's DBG_* localparams."""
    p = config.dbg_params
    spec = [
        ("DBG_GDC_EN", "", f"1'b{p['gdc']}"),
        ("DBG_CPU_EN", "", f"1'b{p['cpu']}"),
        ("DBG_SAMPLE_MS", "", f"{p['sample_ms']}"),
        ("DBG_SNOOP_EN", "", f"1'b{p['snoop_en']}"),
        ("DBG_SNOOP_LO", "[31:0] ", f"32'h{p['snoop_lo']:08x}"),
        ("DBG_SNOOP_HI", "[31:0] ", f"32'h{p['snoop_hi']:08x}"),
        ("DBG_TRIG_KIND", "", f"{p['trig_kind']}"),
        ("DBG_TRIG_ADDR", "[31:0] ", f"32'h{p['trig_addr']:08x}"),
        ("DBG_TRIG_CS", "[15:0] ", f"16'h{p['trig_cs']:04x}"),
        ("DBG_TRIG2_LO", "[31:0] ", f"32'h{p['trig2_lo']:08x}"),
        ("DBG_TRIG2_HI", "[31:0] ", f"32'h{p['trig2_hi']:08x}"),
        ("DBG_ARM_S", "", f"{p['arm_s']}"),
        ("DBG_POST", "", f"{p['post']}"),
    ]
    out = []
    for name, width, value in spec:
        decl = re.escape(width).replace(r"\ ", r"[ \t]+") if width else ""
        pattern = rf"^localparam[ \t]+{decl}{name}[ \t]*=[ \t]*[^;]+;[ \t]*$"
        out.append((name, pattern, f"localparam {width}{name} = {value};"))
    return out


# ---- qsf_set: further fitter/synthesis assignments over the SPEED stack -------------------
# The value that DROPS a stack row instead of setting it (Quartus's own default then applies).
QSF_SET_DEFAULT = "@default"
QSF_SET_NAME_RE = re.compile(r"[A-Z][A-Z0-9_]*")
# One or more space-separated words; quoting is render_qsf_block's job, so no quote, no '#'.
QSF_SET_VALUE_RE = re.compile(r"[A-Za-z0-9_.+\-]+(?: [A-Za-z0-9_.+\-]+)*")
# Names a configuration may not carry: each has an owner of its own, or is project structure
# rather than a fit setting (a wrong one would build a different design, not a different fit).
QSF_SET_FORBIDDEN = {
    "OPTIMIZATION_TECHNIQUE": "set it with fit_technique (--fit-technique)",
    "SEED": "the seed belongs to tools/build.py --seed and the sweeps",
    "VERILOG_MACRO": "the framework macros belong to alsa_en / yc_en",
    "NUM_PARALLEL_PROCESSORS": "execution, not configuration (it does not change the result)",
    "FAMILY": "project structure", "DEVICE": "project structure",
    "TOP_LEVEL_ENTITY": "project structure", "ORIGINAL_QUARTUS_VERSION": "project structure",
    "LAST_QUARTUS_VERSION": "project structure", "PROJECT_OUTPUT_DIRECTORY": "project structure",
    "SEARCH_PATH": "project structure", "TIMEQUEST_MULTICORNER_ANALYSIS":
        "it changes what the timing summary reports, so fits would not be comparable",
}
QSF_SET_FORBIDDEN_SUFFIXES = ("_FILE",)    # VERILOG_FILE, SDC_FILE, QIP_FILE, ...


def qsf_set_problems(pairs) -> list[str]:
    """Shape problems of a qsf_set (Quartus itself checks the names and values: quartus_check)."""
    problems = []
    seen = set()
    for name, value in pairs:
        if name in seen:
            problems.append(f"qsf_set: {name} is given twice")
        seen.add(name)
        if not QSF_SET_NAME_RE.fullmatch(name):
            problems.append(f"qsf_set: {name!r} is not an assignment name (A-Z, 0-9, _)")
        elif name in QSF_SET_FORBIDDEN:
            problems.append(f"qsf_set: {name} cannot be overridden here: {QSF_SET_FORBIDDEN[name]}")
        elif name.endswith(QSF_SET_FORBIDDEN_SUFFIXES):
            problems.append(f"qsf_set: {name} names a source file (project structure)")
        if value == QSF_SET_DEFAULT:
            if name not in CONTROLLED_ASSIGNMENTS:
                problems.append(f"qsf_set: {name}={QSF_SET_DEFAULT} drops a row, but {name} is not "
                                "in the SPEED stack")
        elif not QSF_SET_VALUE_RE.fullmatch(value):
            problems.append(f"qsf_set: {name}={value!r}: a value is one or more words of "
                            "[A-Za-z0-9_.+-] separated by single spaces (unquoted)")
    return problems


def normalize_qsf_set(items) -> tuple[tuple[str, str], ...]:
    """A dict or (NAME, VALUE) pairs -> sorted pairs, names upper-cased, quotes stripped."""
    pairs = items.items() if isinstance(items, dict) else items
    out: dict[str, str] = {}
    for name, value in pairs:
        value = str(value).strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1].strip()
        out[str(name).strip().upper()] = value
    return tuple(sorted(out.items()))


def parse_qsf_set_args(items: list[str] | None) -> tuple[tuple[str, str], ...]:
    """--qsf-set NAME=VALUE (repeatable) -> pairs; the later of two equal names wins."""
    pairs = []
    for item in items or []:
        name, sep, value = item.partition("=")
        if not sep:
            raise SystemExit(f"--qsf-set {item!r}: expected NAME=VALUE")
        pairs.append((name, value))
    return normalize_qsf_set(dict(normalize_qsf_set(pairs)))


def qsf_value(value: str) -> str:
    """A qsf_set value as the qsf writes it: a multi-word value is quoted."""
    return f'"{value}"' if " " in value else value


def quartus_check_qsf_set(pairs, *, project_dir: Path = PROJECT_DIR) -> list[str]:
    """Ask Quartus whether it accepts each NAME/VALUE: quartus_sh -t runs set_global_assignment
    on a throwaway Cyclone V project in the container, which refuses an unknown name ("Illegal
    assignment") or an illegal value ("Value ... is illegal") - whereas a fit silently IGNORES
    either, so a typo would read as "this setting does nothing". Verdicts are cached per image
    digest in .build/qsf-check-cache.json (the check takes ~1 s)."""
    pairs = [(n, v) for n, v in pairs if v != QSF_SET_DEFAULT]
    if not pairs:
        return []
    runtime, image = pg.container_runtime(), pg.container_image()
    try:
        digest = pg.image_digest(runtime, image)
    except pg.GenerationError as exc:
        return [f"qsf_set cannot be checked by Quartus: {exc}"]
    cache_path = project_dir / ".build" / "qsf-check-cache.json"
    try:
        cache = json.loads(cache_path.read_text())
    except (OSError, ValueError):
        cache = {}
    verdicts = cache.setdefault(digest, {})
    todo = [(n, v) for n, v in pairs if f"{n}={v}" not in verdicts]
    if todo:
        def tcl_word(text: str) -> str:
            return "{" + text + "}"
        lines = ["project_new -overwrite qsfcheck",
                 'set_global_assignment -name FAMILY "Cyclone V"',
                 "set_global_assignment -name DEVICE 5CSEBA6U23I7"]
        for n, v in todo:
            lines.append(f"if {{[catch {{set_global_assignment -name {n} {tcl_word(v)}}} e]}} "
                         f"{{puts \"QSFCHECK REJECT {n}={v} :: $e\"}} "
                         f"else {{puts \"QSFCHECK ACCEPT {n}={v}\"}}")
        lines.append("project_close")
        with tempfile.TemporaryDirectory(prefix="qsf-check-") as tmp:
            Path(tmp, "check.tcl").write_text("\n".join(lines) + "\n")
            try:
                out = subprocess.run(
                    [runtime, "run", "--rm", "-v", f"{tmp}:/work:Z", "-w", "/work", image,
                     "/opt/intelFPGA/quartus/bin/quartus_sh", "-t", "check.tcl"],
                    capture_output=True, text=True, timeout=300).stdout
            except (OSError, subprocess.TimeoutExpired) as exc:
                return [f"qsf_set cannot be checked by Quartus ({runtime} {image}): {exc}"]
        for line in out.splitlines():
            m = re.match(r"QSFCHECK (ACCEPT|REJECT) ([A-Z0-9_]+)=(.*?)(?: :: (.*))?$", line)
            if m:
                verdicts[f"{m.group(2)}={m.group(3)}"] = (
                    "ok" if m.group(1) == "ACCEPT" else (m.group(4) or "rejected"))
        missing = [f"{n}={v}" for n, v in todo if f"{n}={v}" not in verdicts]
        if missing:
            return [f"qsf_set: Quartus gave no verdict for {missing}:\n{out[-2000:]}"]
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = cache_path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(cache, indent=1, sort_keys=True) + "\n")
        tmp_path.replace(cache_path)
    return [f"qsf_set: Quartus 17.0.2 refuses {n}={v}: {verdicts[f'{n}={v}']}"
            for n, v in pairs if verdicts[f"{n}={v}"] != "ok"]

# The framework feature macros the configuration owns: (Config field, macro sys/sys_top.v tests
# with `ifndef`). A feature that is OFF is one `VERILOG_MACRO "<macro>=1"` line in the managed
# block; ON is no line. No such line may exist outside the block (--check), because sys_top only
# asks whether the macro is DEFINED - a stray copy elsewhere in the qsf would compile the feature
# out whatever the record says.
FRAMEWORK_MACROS: tuple[tuple[str, str], ...] = (
    ("alsa_en", "MISTER_DISABLE_ALSA"),
    ("yc_en", "MISTER_DISABLE_YC"),
)
MACRO_LINE_RE = re.compile(r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"?([A-Za-z0-9_]+)')


def framework_macro_lines(config: "Config") -> list[str]:
    return [f'set_global_assignment -name VERILOG_MACRO "{macro}=1"'
            for field, macro in FRAMEWORK_MACROS if not getattr(config, field)]


# EVERY preset runs the SDRAM on clk_sys (owner, 2026-10-09: "We should always default to the
# 80/80 matched clock build, the default will always match the sdram and sys_clk clocks. In fact,
# we should remove the split clock config."). The 80/80
# build was hardware-verified as the shipping build: DOOM, PCM, Touhou 5,
# Rusty and Flame Zapper with the Xe10 firmware pack.
# 80 MHz is PAST timing closure (the ao486/MiSTer convention: the tools' Fmax is a worst-case-PVT
# number and real boards at room temperature run faster); AGENTS.md's Build profiles section
# holds the measured slack band and the hardware bound.
_BASE_HZ = 80_000_000
_BASE_DESCRIPTION = ("80 MHz clk_sys, SDRAM on clk_sys (80/80), production AREA fit (no seed) - "
                     "the default and shipping build (past timing closure)")
PROFILES: dict[str, Config] = {
    "base": Config(
        name="base",
        description=_BASE_DESCRIPTION,
        clk_sys_hz=_BASE_HZ,
    ),
    # lightoc was the shipping preset's name until base became the same build (2026-10-09). It is
    # kept as an ALIAS - knob for knob base's, only the recorded name differs - so existing
    # commands, sweeps and deploy notes that say `lightoc` keep building the shipping design.
    "lightoc": Config(
        name="lightoc",
        description="ALIAS of base: " + _BASE_DESCRIPTION,
        clk_sys_hz=_BASE_HZ,
    ),
    "mediumoc": Config(
        name="mediumoc",
        description="100 MHz clk_sys, SDRAM on clk_sys (100/100) - NORMAL overclock (past timing closure)",
        clk_sys_hz=100_000_000,
    ),
    # 120 MHz is AT the board SDRAM part's hard limit (about 120 MHz, owner 2026-10-09).
    "heavyoc": Config(
        name="heavyoc",
        description="120 MHz clk_sys, SDRAM on clk_sys (120/120, AT the SDRAM part's ~120 MHz limit) - HEAVY overclock (past timing closure)",
        clk_sys_hz=120_000_000,
    ),
    # The instruction trace: IDENTICAL to base in clock and PLL, so the trace runs at exactly the
    # clock the shipped core does. THE DEBUG PROFILE. It asked for OPTIMIZATION_TECHNIQUE AREA
    # first (2026-09-27); every preset has used AREA since 2026-10-12 (see Config.fit_technique).
    "trace": Config(
        name="trace",
        description="80 MHz clk_sys, SDRAM on clk_sys (clock/PLL identical to base) + the instruction trace ring and perf log, fit with OPTIMIZATION_TECHNIQUE AREA (the debug build)",
        clk_sys_hz=_BASE_HZ,
        trace_en=True,
        perf_log_en=True,
        fit_technique="AREA",
    ),
    # The I/O-latency profile: IDENTICAL to base in clock, PLL and fit settings, so the only
    # difference is the I/O class table (IO_LATENCY_PROFILE 2 prices every class at the
    # machine's measured time, docs/probes/IO.TXT; 1 holds back the EGC even-read class).
    "iofaithful": Config(
        name="iofaithful",
        description="80 MHz clk_sys, SDRAM on clk_sys (identical to base) + the FAITHFUL I/O class table",
        clk_sys_hz=_BASE_HZ,
        io_latency_profile=2,
    ),
    # The MIDI profile: IDENTICAL to base in clock, PLL and fit settings, so the only difference
    # is the MPU-PC98II card and the OSD header that offers UART Mode -> MIDI.
    "midilink": Config(
        name="midilink",
        description="80 MHz clk_sys, SDRAM on clk_sys (identical to base) + the MPU-PC98II MIDI card over the framework UART",
        clk_sys_hz=_BASE_HZ,
        mpu_en=True,
    ),
}


# ---------------------------------------------------------------------------------------
# Resolving a configuration from a preset, a profile file and CLI overrides
# ---------------------------------------------------------------------------------------

PROFILE_FILE_KEYS = {
    "name", "description", "preset", "clk_sys_hz", "clk_sys_mhz",
    "sdram_phase_ps", "trace_en", "perf_log_en", "io_latency_profile", "mpu_en",
    "cdrom_en", "cdrom_audio_en", "cdrom_log_en", "alsa_en", "yc_en", "fit_technique", "qsf_set",
    "dbg",
}


def add_override_args(parser: argparse.ArgumentParser) -> None:
    """The configuration overrides, shared by build_profile.py, tools/build.py and seed_sweep."""
    g = parser.add_argument_group("build configuration (override any field of the preset)")
    g.add_argument("--custom", action="store_true",
                   help="start from base's values under the name 'custom'")
    g.add_argument("--profile-file", type=Path,
                   help="a JSON or TOML file of configuration fields (and optionally 'preset', "
                        "'name', 'description'); CLI overrides apply on top of it")
    g.add_argument("--name", help="the recorded profile name (default: the preset's, or "
                                  "'custom' when anything differs from it)")
    g.add_argument("--clk-sys-mhz", help="clk_sys in MHz (exact, e.g. 56.25); the SDRAM "
                                         "controller runs on it too")
    g.add_argument("--clk-sys-hz", type=int, help="clk_sys in Hz")
    g.add_argument("--sdram-phase-ps",
                   help="SDRAM_CLK (PLL output 1) phase in ps, or 'auto' to derive it")
    g.add_argument("--trace", dest="trace_en", action=argparse.BooleanOptionalAction,
                   default=None, help="TRACE_EN (the instruction trace ring)")
    g.add_argument("--perf-log", dest="perf_log_en", action=argparse.BooleanOptionalAction,
                   default=None, help="PERF_LOG_EN (the serial performance log)")
    g.add_argument("--io-latency", dest="io_latency_profile", type=int, choices=(0, 1, 2),
                   help="IO_LATENCY_PROFILE")
    g.add_argument("--mpu", dest="mpu_en", action=argparse.BooleanOptionalAction, default=None,
                   help="MPU_EN (and the MIDI CONF_STR header)")
    g.add_argument("--cdrom", dest="cdrom_en", action=argparse.BooleanOptionalAction,
                   default=None, help="CDROM_EN (and the CD-ROM OSD slot / VDNUM)")
    g.add_argument("--cdrom-audio", dest="cdrom_audio_en", action=argparse.BooleanOptionalAction,
                   default=None, help="CDROM_AUDIO_EN (the CD drive's CD-DA player)")
    g.add_argument("--cdrom-log", "--dbg-cd", dest="cdrom_log_en", action=argparse.BooleanOptionalAction,
                   default=None, help="CDROM_LOG_EN (debug: the CD's command log on the debug UART)")
    g.add_argument("--dbg-cpu", dest="dbg_cpu", action=argparse.BooleanOptionalAction, default=None,
                   help="debug: the CPU sampler (CS:EIP, INTA counts, PIC state, VSYNC) on the debug UART")
    g.add_argument("--dbg-gdc", "--gdc-log", dest="dbg_gdc", action=argparse.BooleanOptionalAction,
                   default=None, help="debug: the display programming (both GDCs) on the debug UART")
    g.add_argument("--dbg-snoop", dest="dbg_snoop", metavar="LO:HI",
                   help="debug: every CPU write and read beat in the physical window [LO, HI) (hex)")
    g.add_argument("--dbg-trig", dest="dbg_trig", metavar="SPEC",
                   help="debug: freeze the instruction trace on pc:CS:EIP, wr:ADDR or reload:ADDR (hex)")
    g.add_argument("--dbg-trig2", dest="dbg_trig2", metavar="LO:HI",
                   help="debug: a second stage - the first CPU write into [LO, HI) after --dbg-trig")
    g.add_argument("--dbg-sample-ms", dest="dbg_sample_ms", type=int, metavar="N",
                   help="debug: the sampler's period in ms (default 10)")
    g.add_argument("--dbg-arm-s", dest="dbg_arm_s", type=int, metavar="N",
                   help="debug: no trigger fires before N seconds of uptime")
    g.add_argument("--dbg-post", dest="dbg_post", type=int, metavar="N",
                   help="debug: issues recorded after the final trigger (default 32)")
    g.add_argument("--alsa", dest="alsa_en", action=argparse.BooleanOptionalAction, default=None,
                   help="the framework's HPS audio input (off = MISTER_DISABLE_ALSA)")
    g.add_argument("--yc", dest="yc_en", action=argparse.BooleanOptionalAction, default=None,
                   help="the framework's composite/S-Video output (off = MISTER_DISABLE_YC)")
    g.add_argument("--fit-technique", choices=FIT_TECHNIQUES, help="OPTIMIZATION_TECHNIQUE")
    g.add_argument("--qsf-set", action="append", metavar="NAME=VALUE",
                   help="a fitter/synthesis qsf assignment over the SPEED stack (repeatable; "
                        f"VALUE {QSF_SET_DEFAULT} drops the stack's row); recorded in the "
                        "configuration and checked by Quartus when applied")


def override_argv(ns: argparse.Namespace) -> list[str]:
    """The overrides in `ns`, as build_profile.py arguments (for passing through)."""
    out: list[str] = []
    if getattr(ns, "custom", False):
        out.append("--custom")
    for flag, attr in (("--profile-file", "profile_file"), ("--name", "name"),
                       ("--clk-sys-mhz", "clk_sys_mhz"), ("--clk-sys-hz", "clk_sys_hz"),
                       ("--sdram-phase-ps", "sdram_phase_ps"),
                       ("--io-latency", "io_latency_profile"),
                       ("--fit-technique", "fit_technique")):
        value = getattr(ns, attr, None)
        if value is not None:
            out += [flag, str(Path(value).resolve()) if attr == "profile_file" else str(value)]
    for flag, attr in (("trace", "trace_en"),
                       ("perf-log", "perf_log_en"), ("mpu", "mpu_en"), ("cdrom", "cdrom_en"),
                       ("cdrom-audio", "cdrom_audio_en"), ("cdrom-log", "cdrom_log_en"), ("alsa", "alsa_en"), ("yc", "yc_en")):
        value = getattr(ns, attr, None)
        if value is not None:
            out.append(f"--{flag}" if value else f"--no-{flag}")
    for name, value in parse_qsf_set_args(getattr(ns, "qsf_set", None)):
        out += ["--qsf-set", f"{name}={value}"]
    for key in DBG_FLAGS:
        value = getattr(ns, f"dbg_{key}", None)
        if value is not None:
            out.append(f"--dbg-{key}" if value else f"--no-dbg-{key}")
    for key in DBG_VALUES:
        value = getattr(ns, f"dbg_{key}", None)
        if value is not None:
            out += [f"--dbg-{key.replace('_', '-')}", str(value)]
    return out


def load_profile_file(path: Path) -> dict:
    text = path.read_bytes()
    if path.suffix.lower() == ".toml":
        import tomllib
        data = tomllib.loads(text.decode())
    else:
        data = json.loads(text)
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: a profile file is a table/object of configuration fields")
    retired = sorted(set(data) & set(RETIRED_FIELDS))
    if retired:
        raise SystemExit(f"{path}: {retired} belonged to the split-clock configuration, which was "
                         "removed (2026-10-09): the SDRAM runs on clk_sys, so set clk_sys_hz / "
                         "clk_sys_mhz alone")
    unknown = set(data) - PROFILE_FILE_KEYS
    if unknown:
        raise SystemExit(f"{path}: unknown field(s) {sorted(unknown)}; allowed: "
                         f"{sorted(PROFILE_FILE_KEYS)}")
    return data


def _phase_value(value) -> int | None:
    if value is None or str(value).lower() == "auto":
        return None
    return int(value)


def resolve_config(preset_name: str | None, ns: argparse.Namespace) -> Config:
    """preset (or --custom / the file's 'preset') < profile file < CLI flags."""
    data = load_profile_file(ns.profile_file) if getattr(ns, "profile_file", None) else {}
    if preset_name is None:
        preset_name = data.get("preset")
    custom = bool(getattr(ns, "custom", False))
    if preset_name is None:
        if not custom and not data and not any(override_argv(ns)):
            raise SystemExit("choose a preset, --custom, or --profile-file")
        preset_name = "base"
        custom = True
    if preset_name not in PROFILES:
        raise SystemExit(f"unknown preset {preset_name!r}; presets: {', '.join(PROFILES)}")
    preset = PROFILES[preset_name]
    fields: dict = dataclasses.asdict(preset)

    def take(key, value):
        if value is not None:
            fields[key] = value

    take("clk_sys_hz", data.get("clk_sys_hz"))
    if "clk_sys_mhz" in data:
        take("clk_sys_hz", pg.hz_from_mhz_arg(data["clk_sys_mhz"]))
    if "sdram_phase_ps" in data:
        fields["sdram_phase_ps"] = _phase_value(data["sdram_phase_ps"])
    for key in ("trace_en", "perf_log_en", "io_latency_profile", "mpu_en",
                "cdrom_en", "cdrom_audio_en", "cdrom_log_en", "alsa_en", "yc_en", "fit_technique"):
        take(key, data.get(key))
    # qsf_set merges name by name: the preset's, then the file's table, then each --qsf-set.
    qsf_set = dict(preset.qsf_set)
    if "qsf_set" in data:
        if not isinstance(data["qsf_set"], dict):
            raise SystemExit("profile file: qsf_set is a table of NAME = VALUE")
        qsf_set.update(normalize_qsf_set(data["qsf_set"]))

    take("clk_sys_hz", getattr(ns, "clk_sys_hz", None))
    if getattr(ns, "clk_sys_mhz", None) is not None:
        fields["clk_sys_hz"] = pg.hz_from_mhz_arg(ns.clk_sys_mhz)
    if getattr(ns, "sdram_phase_ps", None) is not None:
        fields["sdram_phase_ps"] = _phase_value(ns.sdram_phase_ps)
    for key in ("trace_en", "perf_log_en", "io_latency_profile", "mpu_en",
                "cdrom_en", "cdrom_audio_en", "cdrom_log_en", "alsa_en", "yc_en", "fit_technique"):
        take(key, getattr(ns, key, None))
    qsf_set.update(parse_qsf_set_args(getattr(ns, "qsf_set", None)))
    fields["qsf_set"] = normalize_qsf_set(qsf_set)
    # dbg merges key by key like qsf_set: the preset's (none), the file's table, then each flag.
    dbg = dict(preset.dbg)
    if "dbg" in data:
        if not isinstance(data["dbg"], dict):
            raise SystemExit("profile file: dbg is a table of KEY = VALUE")
        dbg.update(data["dbg"])
    for key in DBG_FLAGS + DBG_VALUES:
        value = getattr(ns, f"dbg_{key}", None)
        if value is not None:
            dbg[key] = value
    fields["dbg"] = normalize_dbg(dbg)

    candidate = Config(**fields)
    changed = custom or candidate.knobs() != preset.knobs()
    name = getattr(ns, "name", None) or data.get("name") or ("custom" if changed else preset.name)
    description = data.get("description") or (
        preset.description if not changed else
        f"custom (from {preset.name}): {fields['clk_sys_hz'] / 1e6:g} MHz clk_sys, SDRAM on clk_sys")
    config = dataclasses.replace(candidate, name=name, description=description,
                                 preset=None if not changed and name == preset.name else preset.name)
    problems = config.validate()
    if problems:
        raise SystemExit("invalid configuration:\n  " + "\n  ".join(problems))
    return config


def config_from_record(record: dict, description: str = "") -> Config:
    phase = record["sdram_phase_ps"] if record.get("sdram_phase_source") == "override" else None
    return Config(
        # A record from before the split-clock removal may still carry sdram_hz / sdram_sync;
        # they are not fields any more, and agreement() reports such a record as retired.
        name=record["name"], description=description, clk_sys_hz=record["clk_sys_hz"],
        sdram_phase_ps=phase, trace_en=record["trace_en"],
        perf_log_en=record["perf_log_en"], io_latency_profile=record["io_latency_profile"],
        mpu_en=record["mpu_en"], fit_technique=record["fit_technique"],
        # Records written before these fields existed mean the defaults they had then.
        cdrom_en=record.get("cdrom_en", False),
        cdrom_audio_en=record.get("cdrom_audio_en", True),
        cdrom_log_en=record.get("cdrom_log_en", False),
        # A record written before these fields existed was a build with both features ON (the
        # macros were not set), so that is what it means; --check then flags its block, which
        # lacks nothing, as agreeing - and a re-apply moves it to the new default.
        alsa_en=record.get("alsa_en", True), yc_en=record.get("yc_en", True),
        # A record written before qsf_set existed carries none, which is what it meant.
        qsf_set=normalize_qsf_set(record.get("qsf_set", {})),
        dbg=normalize_dbg(record.get("dbg", {})),
        preset=record.get("preset"))


# ---------------------------------------------------------------------------------------
# The qsf block
# ---------------------------------------------------------------------------------------

def fit_assignments(config: Config) -> tuple[tuple[str, str], ...]:
    """The SPEED stack with the technique, each qsf_set override in its row's place (or the
    row dropped for @default), then the overrides the stack has no row for, by name."""
    if FIT_TECHNIQUE_ASSIGNMENT not in CONTROLLED_ASSIGNMENTS:
        raise SystemExit(f"build_profile.py: {FIT_TECHNIQUE_ASSIGNMENT} is not a row of "
                         "SPEED_FIT_ASSIGNMENTS, so no fit_technique can reach the qsf")
    over = dict(config.qsf_set)
    rows = []
    for name, value in SPEED_FIT_ASSIGNMENTS:
        if name == FIT_TECHNIQUE_ASSIGNMENT:
            value = config.fit_technique
        if name in over:
            if over[name] == QSF_SET_DEFAULT:
                continue
            value = qsf_value(over[name])
        rows.append((name, value))
    rows += [(name, qsf_value(value)) for name, value in config.qsf_set
             if name not in CONTROLLED_ASSIGNMENTS]
    return tuple(rows)


def outside_block_lines(text: str, names) -> list[str]:
    """Assignment lines OUTSIDE the managed block that set any of `names`."""
    block = qsf_block_text(text) or ""
    assignment_re = re.compile(r"^\s*set_global_assignment\s+-name\s+([A-Z0-9_]+)\b")
    return [line.strip() for line in text.replace(block, "").splitlines()
            if (m := assignment_re.match(line)) and m.group(1) in names]


def render_qsf_block(config: Config) -> str:
    phase, source = config.phase()
    lines = [
        PROFILE_BLOCK_BEGIN,
        f"# Active profile: {config.name}",
        f"# Active clock rate: {config.clk_sys_hz:_} Hz (clk_sys, the SDRAM's clock too)",
        f"# Active SDRAM phase: {phase} ps ({source})",
        CONFIG_RECORD_PREFIX + config.record_json(),
        f"# {config.description}",
    ]
    if config.qsf_set:
        lines.append("# qsf_set: " + ", ".join(f"{n}={v}" for n, v in config.qsf_set))
    lines += [f"set_global_assignment -name {n} {v}" for n, v in fit_assignments(config)]
    lines += framework_macro_lines(config)
    lines.append(PROFILE_BLOCK_END)
    return "\n".join(lines)


def remove_managed_qsf_content(text: str) -> str:
    block_re = re.compile(
        rf"\n?{re.escape(PROFILE_BLOCK_BEGIN)}.*?{re.escape(PROFILE_BLOCK_END)}\n?", re.DOTALL)
    text = block_re.sub("\n", text)
    assignment_re = re.compile(r"^\s*set_global_assignment\s+-name\s+([A-Z0-9_]+)\b")
    owned_macros = {macro for _, macro in FRAMEWORK_MACROS}
    kept = [line for line in text.splitlines()
            if not ((m := assignment_re.match(line)) and m.group(1) in CONTROLLED_ASSIGNMENTS)
            and not ((m := MACRO_LINE_RE.match(line)) and m.group(1) in owned_macros)]
    return "\n".join(kept).rstrip() + "\n"


def insert_qsf_block(text: str, config: Config) -> str:
    block = render_qsf_block(config)
    marker = "set_global_assignment -name TIMEQUEST_MULTICORNER_ANALYSIS OFF"
    if marker in text:
        return text.replace(marker, marker + "\n" + block, 1)
    return text.rstrip() + "\n\n" + block + "\n"


def qsf_block_text(text: str) -> str | None:
    m = re.search(rf"{re.escape(PROFILE_BLOCK_BEGIN)}.*?{re.escape(PROFILE_BLOCK_END)}", text,
                  re.DOTALL)
    return None if m is None else m.group(0)


def read_record(root: Path) -> tuple[dict | None, str]:
    """The '# Active config' JSON record of root's qsf, and the description line after it."""
    qsf = root / QSF_NAME
    if not qsf.exists():
        return None, ""
    block = qsf_block_text(qsf.read_text()) or ""
    m = re.search(rf"^{re.escape(CONFIG_RECORD_PREFIX)}(\{{.*\}})\n# (.*)$", block, re.MULTILINE)
    if not m:
        return None, ""
    return json.loads(m.group(1)), m.group(2)


def active_config(root: Path) -> Config | None:
    record, description = read_record(root)
    return None if record is None else config_from_record(record, description)


# ---------------------------------------------------------------------------------------
# The top level
# ---------------------------------------------------------------------------------------

def top_localparams(config: Config) -> list[tuple[str, str, str]]:
    """(name, regex matching the line, the line to write)."""
    return [
        ("CLOCK_RATE_HZ", r"^localparam[ \t]+CLOCK_RATE_HZ[ \t]*=[ \t]*[0-9_]+;[ \t]*$",
         f"localparam CLOCK_RATE_HZ = {config.clk_sys_hz:_};"),
        ("TRACE_EN", r"^localparam[ \t]+TRACE_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam TRACE_EN = 1'b{int(config.trace_en)};"),
        ("PERF_LOG_EN", r"^localparam[ \t]+PERF_LOG_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam PERF_LOG_EN = 1'b{int(config.perf_log_en)};"),
        ("IO_LATENCY_PROFILE",
         r"^localparam[ \t]+\[1:0\][ \t]+IO_LATENCY_PROFILE[ \t]*=[ \t]*2'd[0-3];[ \t]*$",
         f"localparam [1:0] IO_LATENCY_PROFILE = 2'd{config.io_latency_profile};"),
        ("MPU_EN", r"^localparam[ \t]+MPU_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam MPU_EN = 1'b{int(config.mpu_en)};"),
        ("CONF_STR_HEADER", r'^localparam[ \t]+CONF_STR_HEADER[ \t]*=[ \t]*"[^"]*";[ \t]*$',
         f'localparam CONF_STR_HEADER = "{config.conf_str_header}";'),
        ("CDROM_EN", r"^localparam[ \t]+CDROM_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam CDROM_EN = 1'b{int(config.cdrom_en)};"),
        ("CDROM_AUDIO_EN", r"^localparam[ \t]+CDROM_AUDIO_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam CDROM_AUDIO_EN = 1'b{int(config.cdrom_en and config.cdrom_audio_en)};"),
        ("CDROM_LOG_EN", r"^localparam[ \t]+CDROM_LOG_EN[ \t]*=[ \t]*1'b[01];[ \t]*$",
         f"localparam CDROM_LOG_EN = 1'b{int(config.cdrom_en and config.cdrom_log_en and not config.perf_log_en)};"),
        ("CONF_STR_DISKS", r'^localparam[ \t]+CONF_STR_DISKS[ \t]*=[ \t]*"[^"]*";[ \t]*$',
         f'localparam CONF_STR_DISKS = "{config.conf_str_disks}";'),
        ("CONF_STR_EJECTS", r'^localparam[ \t]+CONF_STR_EJECTS[ \t]*=[ \t]*"[^"]*";[ \t]*$',
         f'localparam CONF_STR_EJECTS = "{config.conf_str_ejects}";'),
        ("HPS_VDNUM", r"^localparam[ \t]+HPS_VDNUM[ \t]*=[ \t]*[0-9]+;[ \t]*$",
         f"localparam HPS_VDNUM = {config.hps_vdnum};"),
        *dbg_localparams(config),
    ]


def rewrite_top(text: str, config: Config) -> str:
    for name, pattern, line in top_localparams(config):
        text, count = re.subn(pattern, line.replace("\\", "\\\\"), text, count=1,
                              flags=re.MULTILINE)
        if count != 1:
            raise SystemExit(f"Expected exactly one {name} localparam in {TOP_NAME}")
    return text


# ---------------------------------------------------------------------------------------
# Applying and generating
# ---------------------------------------------------------------------------------------

def generate_outputs(config: Config, root: Path, log=print) -> dict:
    """The PLL into root/rtl and the SDC into root/z486_mister.sdc."""
    try:
        rb = pg.generate_pll(config.pll_request(), root / "rtl", project_dir=PROJECT_DIR, log=log)
    except pg.GenerationError as exc:
        raise SystemExit(f"PLL generation failed: {exc}")
    (root / SDC_NAME).write_text(render_config_sdc(config))
    return rb


def render_config_sdc(config: Config) -> str:
    return pg.render_sdc(config.name, config.clk_sys_hz)


def describe(config: Config, rb: dict | None = None) -> str:
    phase, source = config.phase()
    actual = rb[f"phase{pg.PIN_CLOCK_OUTPUT}_ps"] if rb else phase
    pred = pg.predict_io(actual / 1000, 1e9 / config.clk_sys_hz)
    worst = pg.io_worst(pred)
    limit = (" (AT/ABOVE the SDRAM part's ~120 MHz limit)"
             if config.clk_sys_hz >= SDRAM_PART_LIMIT_HZ else "")
    return (f"{config.name}: clk_sys {config.clk_sys_hz:_} Hz = the SDRAM clock{limit}, "
            f"SDRAM_CLK phase {phase} ps ({source}; PLL actual {actual} ps), "
            f"I/O model worst {worst[0]:+.3f} ns ({worst[2]} @ {worst[1]}), "
            f"TRACE_EN {int(config.trace_en)} PERF_LOG_EN {int(config.perf_log_en)} "
            f"IO_LATENCY_PROFILE {config.io_latency_profile} MPU_EN {int(config.mpu_en)} "
            f"CDROM_EN {int(config.cdrom_en)} "
            f"CDROM_AUDIO_EN {int(config.cdrom_en and config.cdrom_audio_en)} "
            + ("CDROM_LOG_EN 1 " if (config.cdrom_en and config.cdrom_log_en and not config.perf_log_en) else "") +
            f"ALSA {int(config.alsa_en)} YC {int(config.yc_en)} fit {config.fit_technique}"
            + (" qsf_set " + ",".join(f"{n}={v}" for n, v in config.qsf_set)
               if config.qsf_set else "")
            + (" dbg " + ",".join(f"{n}={v}" for n, v in config.dbg) if config.dbg else ""))


def apply_config(config: Config, root: Path, *, dry_run: bool, generate: bool) -> None:
    top, qsf = root / TOP_NAME, root / QSF_NAME
    new_top = rewrite_top(top.read_text(), config)
    new_qsf = insert_qsf_block(remove_managed_qsf_content(qsf.read_text()), config)
    stray = outside_block_lines(new_qsf, {n for n, _ in config.qsf_set})
    if stray:
        raise SystemExit(f"qsf_set overrides a name {qsf} also sets outside the managed block "
                         f"({stray[0]!r}); remove that line first, so one value can win")
    if config.qsf_set and generate:
        # Quartus ignores an unknown assignment or an illegal value in a qsf without a word,
        # so every override is put to Quartus itself before the tree is touched.
        problems = quartus_check_qsf_set(config.qsf_set)
        if problems:
            raise SystemExit("invalid configuration:\n  " + "\n  ".join(problems))
    if dry_run:
        for path, new in ((top, new_top), (qsf, new_qsf)):
            if path.read_text() != new:
                print(f"Would update {path}")
        print("Would generate rtl/pll* and z486_mister.sdc for: " + describe(config))
        return
    # The PLL first: an unmakeable frequency fails here, before the tree is touched (the
    # generator installs nothing it has not read back and verified).
    rb = generate_outputs(config, root) if generate else None
    top.write_text(new_top)
    qsf.write_text(new_qsf)
    print("Applied " + describe(config, rb))
    if not generate:
        print("  (--no-generate: rtl/pll* and z486_mister.sdc were NOT written)")


# ---------------------------------------------------------------------------------------
# --check: the top level, the qsf, the generated PLL and the generated SDC all agree
# ---------------------------------------------------------------------------------------

def agreement(root: Path, *, require_generated: bool = False) -> list[str]:
    problems: list[str] = []
    qsf, top = root / QSF_NAME, root / TOP_NAME
    record, description = read_record(root)
    if record is None:
        return [f"no '{CONFIG_RECORD_PREFIX.strip()}' record in {qsf}: nothing can say which "
                "configuration this tree builds (run ./build_profile.py <profile>)"]
    try:
        config = config_from_record(record, description)
    except (KeyError, TypeError) as exc:
        return [f"the '# Active config' record in {qsf} is malformed: {exc}"]
    problems += config.validate()
    # A record from before the split-clock removal names an SDRAM clock of its own. One that says
    # anything but "the SDRAM on clk_sys" describes a build this tree can no longer make.
    if (record.get("sdram_hz", config.clk_sys_hz) != config.clk_sys_hz
            or record.get("sdram_sync", True) is False):
        problems.append(f"the '# Active config' record in {qsf} is a SPLIT-CLOCK build (sdram_hz "
                        f"{record.get('sdram_hz')}, sdram_sync {record.get('sdram_sync')}), which was "
                        "removed on 2026-10-09: re-apply a preset (the SDRAM runs on clk_sys)")

    # The whole managed block must be exactly what this record renders: that covers the name,
    # clock and phase comment lines and every fit assignment, the technique included.
    block = qsf_block_text(qsf.read_text())
    expected_block = render_qsf_block(config)
    if block != expected_block:
        got = (block or "").splitlines()
        want = expected_block.splitlines()
        diff = [f"    qsf: {g!r}\n    want: {w!r}" for g, w in zip(got, want) if g != w]
        if len(got) != len(want):
            diff.append(f"    ({len(got)} lines in the qsf block, {len(want)} expected)")
        problems.append(f"{qsf}'s managed block is not the one its own record renders "
                        "(edited by hand?):\n" + "\n".join(diff[:6]))
    # An override must be the only line that sets its name, or the qsf's order would decide.
    for line in outside_block_lines(qsf.read_text(), {n for n, _ in config.qsf_set}):
        problems.append(f"{qsf} sets a qsf_set name outside the managed block ({line!r}), so the "
                        "record's value is not the only one Quartus sees")
    # The framework feature macros: the block's lines are covered by the comparison above; a copy
    # OUTSIDE the block would define the macro whatever the record says.
    outside = qsf.read_text().replace(block or "", "")
    for field, macro in FRAMEWORK_MACROS:
        stray = [line.strip() for line in outside.splitlines()
                 if (m := MACRO_LINE_RE.match(line)) and m.group(1) == macro]
        if stray:
            problems.append(f"{qsf} sets {macro} outside the managed block ({stray[0]!r}), so the "
                            f"record's {field}={getattr(config, field)} cannot hold: the macro "
                            "belongs to build_profile.py (re-apply the profile)")
    if record.get("sdram_phase_source") == "derived":
        derived = pg.derive_sdram_phase(config.clk_sys_hz)["phase_ps"]
        if record["sdram_phase_ps"] != derived:
            problems.append(f"the record's derived phase {record['sdram_phase_ps']} ps is not what "
                            f"the I/O model derives today ({derived} ps): re-apply the profile")

    top_text = top.read_text()
    # The split-clock knobs are gone from the top level; one that reappears (an old branch merged
    # in) would be a second, unchecked SDRAM clock decision.
    for name in RETIRED_LOCALPARAMS:
        if re.search(rf"^localparam\b[^;]*\b{name}\b", top_text, re.MULTILINE):
            problems.append(f"{top} declares the retired split-clock localparam {name}: the SDRAM "
                            "runs on CLOCK_RATE_HZ, and nothing may decide a second clock")
    for name, pattern, line in top_localparams(config):
        m = re.search(pattern, top_text, re.MULTILINE)
        if m is None:
            problems.append(f"no {name} localparam in {top} to agree with")
        elif m.group(0).strip() != line:
            problems.append(f"{top} declares `{m.group(0).strip()}` but the active configuration "
                            f"'{config.name}' means `{line}`")

    sdc = root / SDC_NAME
    if sdc.exists():
        try:
            expected = render_config_sdc(config)
        except pg.GenerationError as exc:
            expected = None
            problems.append(f"the record cannot render an SDC: {exc}")
        actual = sdc.read_text()
        if expected is not None and actual != expected:
            problems.append(f"{sdc} is not the SDC the active configuration generates (a stale "
                            "copy, a hand edit, or a template change): re-apply the profile")
        problems += pg.sdc_block_shape_problems(actual, str(sdc))
    elif require_generated:
        problems.append(f"{sdc} was not generated")

    pll2 = root / "rtl" / "pll" / "pll_0002.v"
    if pll2.exists() and (root / "rtl" / "pll.v").exists():
        try:
            problems += [f"rtl/pll: {p}" for p in
                         pg.verify_readback(config.pll_request(), pg.read_back(root / "rtl"))]
        except pg.GenerationError as exc:
            problems.append(f"rtl/pll cannot be read back: {exc}")
    elif require_generated:
        problems.append(f"{root / 'rtl'} has no generated PLL (pll.v + pll/pll_0002.v)")
    return problems


# ---------------------------------------------------------------------------------------
# --selftest: --check must catch every planted disagreement
# ---------------------------------------------------------------------------------------

def _fake_pll(root: Path, config: Config, *, freq1_hz: int | None = None,
              off_steps: int = 0) -> None:
    """A PLL directory that reads back like a generated one (no container needed)."""
    req = config.pll_request()
    rtl = root / "rtl"
    (rtl / "pll").mkdir(parents=True, exist_ok=True)
    (rtl / "pll.v").write_text(pg.render_pll_v(req))
    # What the wizard would report: the request rounded onto the finest VCO's step grid
    # (displaced by off_steps steps), truncated to whole ps.
    vco = max(v for v in range(300_000_000, 1_600_000_001, 1_000_000) if v % req.clk_sys_hz == 0)
    step = 1e12 / (8 * vco)
    phase_ps = int((round(req.phase_ps / step) + off_steps) * step)
    f1 = req.clk_sys_hz if freq1_hz is None else freq1_hz
    (rtl / "pll" / "pll_0002.v").write_text(
        f"\t\t.number_of_clocks({pg.PLL_OUTPUTS}),\n"
        f'\t\t.output_clock_frequency0("{req.clk_sys_hz / 1e6:.6f} MHz"),\n'
        '\t\t.phase_shift0("0 ps"),\n'
        f'\t\t.output_clock_frequency1("{f1 / 1e6:.6f} MHz"),\n'
        f'\t\t.phase_shift1("{phase_ps} ps"),\n')


def selftest() -> int:
    plants = []

    def plant(label, tree="base"):
        def deco(fn):
            plants.append((label, fn, tree))
            return fn
        return deco

    def sub(path: Path, old: str, new: str) -> None:
        text = path.read_text()
        if old not in text:
            raise AssertionError(f"selftest: {old!r} not in {path}")
        path.write_text(text.replace(old, new, 1))

    @plant("top level: CLOCK_RATE_HZ disagrees with the record")
    def _(root, cfg):
        sub(root / TOP_NAME, f"CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};", "CLOCK_RATE_HZ = 50_000_000;")

    @plant("top level: the retired SDRAM_RATE_HZ reappears (an old branch merged in)")
    def _(root, cfg):
        sub(root / TOP_NAME, f"localparam CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};",
            f"localparam CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};\nlocalparam SDRAM_RATE_HZ = 100_000_000;")

    @plant("top level: the retired SDRAM_SYNC reappears (an old branch merged in)")
    def _(root, cfg):
        sub(root / TOP_NAME, f"localparam CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};",
            f"localparam CLOCK_RATE_HZ = {cfg.clk_sys_hz:_};\nlocalparam SDRAM_SYNC = 1'b0;")

    @plant("top level: TRACE_EN flipped against the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "TRACE_EN = 1'b0;", "TRACE_EN = 1'b1;")

    @plant("top level: PERF_LOG_EN flipped against the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "PERF_LOG_EN = 1'b0;", "PERF_LOG_EN = 1'b1;")

    @plant("top level: IO_LATENCY_PROFILE disagrees with the record")
    def _(root, cfg):
        sub(root / TOP_NAME, "IO_LATENCY_PROFILE = 2'd0;", "IO_LATENCY_PROFILE = 2'd2;")

    @plant("top level: MPU_EN flipped without its header")
    def _(root, cfg):
        sub(root / TOP_NAME, "MPU_EN = 1'b0;", "MPU_EN = 1'b1;")

    @plant("top level: CDROM_EN flipped without its OSD slot", tree="nocd")
    def _(root, cfg):
        sub(root / TOP_NAME, "CDROM_EN = 1'b0;", "CDROM_EN = 1'b1;")

    @plant("top level: the default build's CDROM_EN dropped with its OSD slot left in place")
    def _(root, cfg):
        sub(root / TOP_NAME, "CDROM_EN = 1'b1;", "CDROM_EN = 1'b0;")

    @plant("top level: CDROM_LOG_EN on in a build whose record has no CD log")
    def _(root, cfg):
        sub(root / TOP_NAME, "CDROM_LOG_EN = 1'b0;", "CDROM_LOG_EN = 1'b1;")

    @plant("top level: DBG_GDC_EN on in a build whose record has no debug instruments")
    def _(root, cfg):
        sub(root / TOP_NAME, "DBG_GDC_EN = 1'b0;", "DBG_GDC_EN = 1'b1;")

    @plant("top level: DBG_SNOOP_HI disagrees with the record's snoop window", tree="dbg")
    def _(root, cfg):
        sub(root / TOP_NAME, "DBG_SNOOP_HI = 32'h0002fc00;", "DBG_SNOOP_HI = 32'h0002fe00;")

    @plant("top level: DBG_TRIG_KIND dropped although the record names a trigger", tree="dbg")
    def _(root, cfg):
        sub(root / TOP_NAME, "DBG_TRIG_KIND = 3;", "DBG_TRIG_KIND = 0;")

    @plant("top level: the framework's DBG_POST edited away from the default 32")
    def _(root, cfg):
        sub(root / TOP_NAME, "DBG_POST = 32;", "DBG_POST = 8;")

    @plant("qsf: the record gains a debug instrument the top level does not carry")
    def _(root, cfg):
        sub(root / QSF_NAME, '"name":"base"', '"name":"base","dbg":{"gdc":true}')

    @plant("top level: a CD build whose CDROM_AUDIO_EN dropped the CD-DA player")
    def _(root, cfg):
        sub(root / TOP_NAME, "CDROM_AUDIO_EN = 1'b1;", "CDROM_AUDIO_EN = 1'b0;")

    @plant("top level: HPS_VDNUM disagrees with CDROM_EN", tree="nocd")
    def _(root, cfg):
        sub(root / TOP_NAME, "HPS_VDNUM = 3;", "HPS_VDNUM = 5;")

    @plant("top level: the default CD build's HPS_VDNUM back to 3 (no slot 4)")
    def _(root, cfg):
        sub(root / TOP_NAME, "HPS_VDNUM = 5;", "HPS_VDNUM = 3;")

    @plant("top level: CONF_STR_DISKS back to the retired second disk's entry", tree="nocd")
    def _(root, cfg):
        sub(root / TOP_NAME, '"S2,D88FDDHDM,Mount FDD2;";', '"S3,IMG,Mount HDD1;";')

    @plant("top level: the CD-ROM's Eject offered in a build without the CD", tree="nocd")
    def _(root, cfg):
        sub(root / TOP_NAME, '"T[10],Eject FDD2;";', '"T[10],Eject FDD2;T[11],Eject CD-ROM;";')

    @plant("top level: a CD build whose Eject line lost the CD-ROM's entry")
    def _(root, cfg):
        sub(root / TOP_NAME, '"T[10],Eject FDD2;T[11],Eject CD-ROM;";', '"T[10],Eject FDD2;";')

    @plant("top level: a CD build whose mount line lost the CD-ROM's slot")
    def _(root, cfg):
        sub(root / TOP_NAME, '"S2,D88FDDHDM,Mount FDD2;S4,ISOPCD,Mount CD-ROM;";',
            '"S2,D88FDDHDM,Mount FDD2;";')

    @plant("qsf: the technique row edited by hand")
    def _(root, cfg):
        other = "SPEED" if cfg.fit_technique == "AREA" else "AREA"
        sub(root / QSF_NAME, f"OPTIMIZATION_TECHNIQUE {cfg.fit_technique}", f"OPTIMIZATION_TECHNIQUE {other}")

    @plant("qsf: the record's clk_sys changed (top level, PLL and SDC still the old one)")
    def _(root, cfg):
        sub(root / QSF_NAME, f'"clk_sys_hz":{cfg.clk_sys_hz}', '"clk_sys_hz":90000000')

    @plant("qsf: the record's derived phase is not what the I/O model derives")
    def _(root, cfg):
        sub(root / QSF_NAME, f'"sdram_phase_ps":{cfg.phase()[0]}', '"sdram_phase_ps":8000')

    @plant("qsf: a retired SPLIT-CLOCK record (sdram_hz != clk_sys) with its block")
    def _(root, cfg):
        sub(root / QSF_NAME, '"sdram_phase_ps":', f'"sdram_hz":100000000,"sdram_sync":false,"sdram_phase_ps":')

    @plant("qsf: the ALSA macro dropped from the block (record still says off)")
    def _(root, cfg):
        sub(root / QSF_NAME, 'set_global_assignment -name VERILOG_MACRO "MISTER_DISABLE_ALSA=1"\n', "")

    @plant("qsf: the record says YC on while the block still disables it")
    def _(root, cfg):
        sub(root / QSF_NAME, '"yc_en":false', '"yc_en":true')

    @plant("qsf: a stray MISTER_DISABLE_YC outside the managed block")
    def _(root, cfg):
        sub(root / QSF_NAME, "source sys/sys.tcl",
            'set_global_assignment -name VERILOG_MACRO "MISTER_DISABLE_YC=1"\nsource sys/sys.tcl')

    @plant("SDC: the computed block's clock line edited")
    def _(root, cfg):
        sub(root / SDC_NAME, f"clk_sys {pg.mhz_text(cfg.clk_sys_hz)} MHz", "clk_sys 50.0 MHz")

    @plant("SDC: a retired split-clock multicycle inside the computed block")
    def _(root, cfg):
        sub(root / SDC_NAME, pg.SDC_PROFILE_END,
            "set_multicycle_path -from $pc9821_clk_sys -to $pc9821_clk_sdram -setup -end 3\n"
            + pg.SDC_PROFILE_END)

    @plant("SDC: a shared line edited")
    def _(root, cfg):
        sub(root / SDC_NAME, "set_output_delay -clock PC9821_SDRAM_CLK -max  1.5",
            "set_output_delay -clock PC9821_SDRAM_CLK -max  1.0")

    @plant("SDC: a computed comment lost its '#'")
    def _(root, cfg):
        sub(root / SDC_NAME, "# so there is no second clock domain", "so there is no second clock domain")

    @plant("PLL: output 1 (the SDRAM pin clock) is not at clk_sys")
    def _(root, cfg):
        _fake_pll(root, cfg, freq1_hz=100_000_000)

    @plant("PLL: output 1's phase is off by more than a VCO step")
    def _(root, cfg):
        _fake_pll(root, cfg, off_steps=-13)

    @plant("PLL: pll.v requests a different phase than the record")
    def _(root, cfg):
        sub(root / "rtl" / "pll.v", f'gui_phase_shift1" value="{cfg.phase()[0]}"',
            'gui_phase_shift1" value="4000"')

    @plant("PLL: a retired three-output (split-clock) PLL")
    def _(root, cfg):
        sub(root / "rtl" / "pll" / "pll_0002.v", f".number_of_clocks({pg.PLL_OUTPUTS})",
            ".number_of_clocks(3)")

    @plant("SDC missing while generation is required")
    def _(root, cfg):
        (root / SDC_NAME).unlink()

    # qsf_set: the overrides are part of the record, so the block must render from it exactly.
    @plant("qsf: the record gains a qsf_set the block does not carry")
    def _(root, cfg):
        sub(root / QSF_NAME, '"name":"base"',
            '"name":"base","qsf_set":{"PHYSICAL_SYNTHESIS_EFFORT":"NORMAL"}')

    @plant("qsf: an override's row edited by hand", tree="over")
    def _(root, cfg):
        sub(root / QSF_NAME, "ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM",
            "ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL")

    @plant("qsf: a stack row the override drops (@default) put back by hand", tree="over")
    def _(root, cfg):
        sub(root / QSF_NAME, "set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL",
            "set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON\n"
            "set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL")

    @plant("qsf: an override's name also set outside the managed block", tree="over")
    def _(root, cfg):
        sub(root / QSF_NAME, "source sys/sys.tcl",
            "set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL\nsource sys/sys.tcl")

    @plant("qsf: the record's qsf_set names a forbidden assignment (SEED)", tree="over")
    def _(root, cfg):
        sub(root / QSF_NAME, '"qsf_set":{', '"qsf_set":{"SEED":"3",')

    configs = {
        "base": PROFILES["base"],
        "lightoc": PROFILES["lightoc"],
        "mediumoc": PROFILES["mediumoc"],
        # base itself is a CD build since 2026-10-10; the --no-cdrom opt-out is its own tree.
        "nocd": dataclasses.replace(PROFILES["base"], name="custom", preset="base", cdrom_en=False),
        "dbg": dataclasses.replace(PROFILES["base"], name="custom", preset="base", dbg=(
            ("cpu", True), ("snoop", "0x2fa00:0x2fc00"), ("trig", "reload:0x2fb20"),
            ("trig2", "0x3d900:0x3da00"), ("gdc", True))),
        "over": dataclasses.replace(PROFILES["base"], name="custom", preset="base", qsf_set=(
            ("PHYSICAL_SYNTHESIS_REGISTER_RETIMING", QSF_SET_DEFAULT),
            ("ROUTER_TIMING_OPTIMIZATION_LEVEL", "MAXIMUM"),
            ("OPTIMIZATION_MODE", "AGGRESSIVE PERFORMANCE"))),
    }
    failures = 0

    # The preset contract (owner, 2026-10-09): every preset runs the SDRAM on clk_sys, base is
    # 80 MHz, lightoc is base under another name, and a custom clock moves the SDRAM with it.
    contract_parser = argparse.ArgumentParser(add_help=False)
    add_override_args(contract_parser)
    want_hz = {"base": 80_000_000, "lightoc": 80_000_000, "trace": 80_000_000,
               "iofaithful": 80_000_000, "midilink": 80_000_000, "mediumoc": 100_000_000,
               "heavyoc": 120_000_000}
    if set(want_hz) != set(PROFILES):
        print(f"SELFTEST FAIL: preset contract names {sorted(want_hz)}, PROFILES has "
              f"{sorted(PROFILES)}")
        failures += 1
    for argv, want in (*(([n], hz) for n, hz in want_hz.items()),
                       (["--custom", "--clk-sys-mhz", "90"], 90_000_000)):
        got_cfg = resolve_config(None if argv[0].startswith("--") else argv[0],
                                 contract_parser.parse_args(
                                     argv if argv[0].startswith("--") else argv[1:]))
        req = got_cfg.pll_request()
        if got_cfg.clk_sys_hz != want or req.clk_sys_hz != want:
            print(f"SELFTEST FAIL: preset contract {' '.join(argv)} -> clk_sys "
                  f"{got_cfg.clk_sys_hz}, want {want}")
            failures += 1
        else:
            print(f"selftest: preset contract {' '.join(argv)} -> {want // 10**6} MHz clk_sys = SDRAM")
    # The CD contract (owner, 2026-10-10: "default to enabling the CD across the board"): every
    # preset builds the drive with its CD-DA player, none carries the debug command log, and
    # --no-cdrom / --no-cdrom-audio still opt out.
    for name, preset in PROFILES.items():
        if preset.dbg:
            print(f"SELFTEST FAIL: preset {name} builds a debug instrument ({dict(preset.dbg)}): "
                  "the framework is off in every preset")
            failures += 1
        if not (preset.cdrom_en and preset.cdrom_audio_en) or preset.cdrom_log_en:
            print(f"SELFTEST FAIL: preset {name} is not a full CD build without the log "
                  f"(cdrom_en {preset.cdrom_en}, cdrom_audio_en {preset.cdrom_audio_en}, "
                  f"cdrom_log_en {preset.cdrom_log_en})")
            failures += 1
    print(f"selftest: CD contract - all {len(PROFILES)} presets build the CD drive + CD-DA, no log")
    # The debug-framework contract: the options resolve to the localparams the RTL takes, a bad
    # combination is refused, and a spec that cannot mean what it says never reaches the top level.
    for argv, want in ((["base", "--dbg-snoop", "2fa00:2fc00"], {"snoop_en": 1, "snoop_lo": 0x2fa00, "snoop_hi": 0x2fc00}),
                       (["base", "--dbg-trig", "pc:f800:1234"], {"trig_kind": 1, "trig_cs": 0xf800, "trig_addr": 0x1234}),
                       (["base", "--dbg-trig", "wr:1002", "--dbg-post", "100"], {"trig_kind": 2, "trig_addr": 0x1002, "post": 100}),
                       (["base", "--dbg-cpu", "--dbg-sample-ms", "5"], {"cpu": 1, "sample_ms": 5}),
                       (["base", "--gdc-log"], {"gdc": 1})):
        got_cfg = resolve_config(argv[0], contract_parser.parse_args(argv[1:]))
        bad = {k: (got_cfg.dbg_params[k], v) for k, v in want.items() if got_cfg.dbg_params[k] != v}
        if bad:
            print(f"SELFTEST FAIL: {' '.join(argv)} resolves to {bad} (got, want)")
            failures += 1
        else:
            print(f"selftest: {' '.join(argv)} -> {want}")
    for argv in (["base", "--trace", "--dbg-cpu"], ["base", "--dbg-trig2", "1000:2000"],
                 ["base", "--dbg-snoop", "2000:1000"], ["base", "--dbg-trig", "jump:1"],
                 ["base", "--dbg-sample-ms", "5"], ["base", "--dbg-post", "9"]):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                resolve_config(argv[0], contract_parser.parse_args(argv[1:]))
        except SystemExit:
            print(f"selftest: {' '.join(argv)} is refused")
        else:
            print(f"SELFTEST FAIL: {' '.join(argv)} is accepted")
            failures += 1
    for argv, field in ((["base", "--no-cdrom"], "cdrom_en"),
                        (["base", "--no-cdrom-audio"], "cdrom_audio_en")):
        got_cfg = resolve_config(argv[0], contract_parser.parse_args(argv[1:]))
        if getattr(got_cfg, field):
            print(f"SELFTEST FAIL: {' '.join(argv)} still sets {field}")
            failures += 1
        else:
            print(f"selftest: {' '.join(argv)} opts out ({field} off)")
    if PROFILES["lightoc"].knobs() != PROFILES["base"].knobs():
        print("SELFTEST FAIL: lightoc is no longer an alias of base (their knobs differ)")
        failures += 1
    for retired in ("--sdram-mhz", "--sdram-sync", "--no-sdram-sync"):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                contract_parser.parse_args([retired] + (["100"] if retired == "--sdram-mhz" else []))
        except SystemExit:
            print(f"selftest: the retired {retired} is refused")
        else:
            print(f"SELFTEST FAIL: the retired {retired} is still accepted")
            failures += 1
    with tempfile.TemporaryDirectory(prefix="build-profile-selftest-") as tmp:
        def fresh(cfg: Config) -> Path:
            root = Path(tmp) / "tree"
            shutil.rmtree(root, ignore_errors=True)
            root.mkdir()
            for name in (TOP_NAME, QSF_NAME):
                shutil.copy2(PROJECT_DIR / name, root / name)
            apply_config(cfg, root, dry_run=False, generate=False)
            (root / SDC_NAME).write_text(render_config_sdc(cfg))
            _fake_pll(root, cfg)
            return root

        for tree, cfg in configs.items():
            clean = agreement(fresh(cfg), require_generated=True)
            if clean:
                print(f"SELFTEST FAIL: the clean {tree} tree reports problems:\n  "
                      + "\n  ".join(clean))
                failures += 1
            else:
                print(f"selftest: clean {tree} tree -> no problems")
        for label, fn, tree in plants:
            cfg = configs[tree]
            root = fresh(cfg)
            fn(root, cfg)
            found = agreement(root, require_generated=True)
            if found:
                print(f"selftest: caught  {label}: {found[0].splitlines()[0][:110]}")
            else:
                print(f"SELFTEST FAIL: missed {label}")
                failures += 1
    print(f"build_profile.py --selftest: {'PASS' if not failures else 'FAIL'} "
          f"({len(plants)} plants, {failures} failure(s))")
    return 1 if failures else 0


# ---------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------

def run_quartus() -> int:
    return subprocess.call(["quartus_sh", "--flow", "compile", PROJECT], cwd=PROJECT_DIR)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("profile", nargs="?", choices=sorted(PROFILES), help="the preset to apply")
    parser.add_argument("--list", action="store_true", help="list the presets")
    parser.add_argument("--show", action="store_true", help="show the recorded configuration")
    parser.add_argument("--check", action="store_true",
                        help="verify the top level, the qsf record, and (when present) the "
                             "generated PLL and SDC agree; exit 0/1")
    parser.add_argument("--tree", type=Path, default=PROJECT_DIR,
                        help="the tree --check/--show inspect (default: this checkout)")
    parser.add_argument("--require-generated", action="store_true",
                        help="with --check: the generated PLL and SDC must exist")
    parser.add_argument("--selftest", action="store_true",
                        help="plant PLL/SDC/top-level/qsf disagreements; --check must catch each")
    parser.add_argument("--pll-into", metavar="DIR", type=Path,
                        help="generate DIR's recorded configuration's PLL into DIR/rtl and its "
                             "SDC into DIR/; used by tools/build.py on its scratch tree")
    parser.add_argument("--print-config", action="store_true",
                        help="print the configuration the arguments resolve to (or the active "
                             "one) as JSON, and exit without changing anything")
    parser.add_argument("--quartus-check", action="store_true",
                        help="put the resolved (or the active) configuration's qsf_set to Quartus "
                             "in the container and report each verdict; exit 0/1")
    parser.add_argument("--no-generate", action="store_true",
                        help="apply without generating the PLL/SDC (no container needed)")
    parser.add_argument("--dry-run", action="store_true", help="print changes without writing")
    parser.add_argument("--compile", action="store_true", help="run quartus_sh after applying")
    add_override_args(parser)
    args = parser.parse_args(argv)
    has_config_args = bool(args.profile or override_argv(args))

    if args.list:
        for c in PROFILES.values():
            print(f"{c.name:10} {c.description}")
        return 0

    if args.selftest:
        return selftest()

    if args.print_config:
        config = resolve_config(args.profile, args) if has_config_args else active_config(args.tree)
        if config is None:
            raise SystemExit("no recorded configuration")
        print(config.record_json())
        return 0

    if args.quartus_check:
        config = resolve_config(args.profile, args) if has_config_args else active_config(args.tree)
        if config is None:
            raise SystemExit("no recorded configuration")
        problems = qsf_set_problems(config.qsf_set) or quartus_check_qsf_set(config.qsf_set)
        for problem in problems:
            print(f"QSF_SET: {problem}", file=sys.stderr)
        print(f"qsf_set: {len(config.qsf_set)} override(s), "
              f"{'REFUSED' if problems else 'all accepted by Quartus'}")
        return 1 if problems else 0

    if args.show:
        config = active_config(args.tree)
        print("No recorded configuration" if config is None else describe(config))
        return 0

    if args.check:
        problems = agreement(args.tree, require_generated=args.require_generated)
        for problem in problems:
            print(f"PROFILE MISMATCH: {problem}", file=sys.stderr)
        if problems:
            return 1
        config = active_config(args.tree)
        assert config is not None
        generated = (args.tree / SDC_NAME).exists() and (args.tree / "rtl/pll/pll_0002.v").exists()
        rb = pg.read_back(args.tree / "rtl") if generated else None
        print(f"profile agreement: '{config.name}' - top level, qsf record"
              f"{', generated PLL and SDC' if generated else ' (PLL/SDC not generated here)'} "
              f"agree: {describe(config, rb)}")
        return 0

    if args.pll_into:
        dest = args.pll_into
        config = active_config(dest) or active_config(PROJECT_DIR)
        if config is None:
            raise SystemExit(f"no '# Active config' record in {dest / QSF_NAME}; run "
                             "./build_profile.py <profile> first")
        rb = generate_outputs(config, dest)
        print(f"Generated {dest}/rtl/pll* and {dest}/{SDC_NAME}: {describe(config, rb)}")
        return 0

    if not has_config_args:
        parser.error("choose a preset (or --custom / --profile-file / overrides), or "
                     "--list/--show/--check")
    config = resolve_config(args.profile, args)
    apply_config(config, PROJECT_DIR, dry_run=args.dry_run, generate=not args.no_generate)
    if args.compile and not args.dry_run:
        return run_quartus()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

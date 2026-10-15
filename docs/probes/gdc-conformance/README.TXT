PC-98 GDC CHARACTERIZATION / CONFORMANCE SUITE
==============================================
Version 1.0 RC6, 2026-09-17
DOS packaging revision: strict CRLF batch/documentation files

PURPOSE
-------
This suite characterizes the graphics uPD7220-compatible GDC in PC-98
machines without using display raster timing as an oracle.  It is intended to
produce real-hardware traces from which the controller model can be derived
and emulator implementations can then be compared.

The screen is normally disabled while tests run.  Results come from raw GVRAM,
CURD, status/FIFO samples and readback data, not from visual appearance.

IMPORTANT
---------
Real hardware is the oracle.  A FAIL is experimental data, not a reason to
throw the run away.  Always preserve the complete GDCRES directory from the
machine, including CSV, VRD, RC, RUNINFO and MACHINE.TXT files.

Before a hardware run, edit MACHINE.TXT.  Set GDC_CLOCK_RUN to the clock you
intend to test and describe how the clock was selected.  The programs also
record the BIOS clock flags, so a mismatch is useful diagnostic information.

QUICK REAL-HARDWARE PROCEDURE
-----------------------------
For a complete SAFE capture at one GDC clock:

  1. Edit MACHINE.TXT.
  2. Select the desired GDC clock and reboot if the machine requires it.
  3. CLEAN.BAT
  4. RUNFULL.BAT
  5. Copy the ENTIRE GDCRES directory off the machine and label it with the
     machine and GDC clock, for example PC98_25_SAFE or PC98_50_SAFE.

RUNFULL already runs every safe profile in this order:

  RUNCORE -> RUNADDR -> RUNPITCH -> RUNDRAW -> RUNRDX -> RUNRESET -> RUNTIME

RUNTIME is therefore already included and is run last.  Do not run the
individual batch files again unless repeating a particular experiment.

After the safe GDCRES directory has been copied, RUNUNDEF.BAT may be run as an
explicit opt-in fingerprint of reserved/undefined behavior.  Preserve the
post-RUNUNDEF GDCRES separately from the safe copy.  If RUNUNDEF hangs, reset
the machine; the safe dataset copied before it is still the primary capture.

Repeat the safe procedure after selecting the other GDC clock.  DO NOT merge
the 2.5 MHz and 5 MHz GDCRES directories.

For maximum safety, collect BOTH safe clock datasets before running RUNUNDEF
at either clock.  This prevents an undefined-command hang from delaying the
main acquisition.

TEST PROFILES
-------------
RUNCORE.BAT   Safe first run: CURS/CURD/MASK, parser/state, FIFO/status,
              WDAT, uPD7220A WG behavior, basic RDAT, FIGD ROP/pattern.

RUNADDR.BAT   Physical GVRAM plane mapping, 18-bit EAD aliasing/carry,
              pixel/word boundary stepping and PITCH carry probes; raw VRD.

RUNPITCH.BAT  Dedicated PITCH/DGD characterizer.  Runs four restartable
              chunks and covers PITCH values 0,1,2,7,8,15,16,20,31,39,40,41,
              63,64,79,80,81,127,128,160,254,255; DGD 0/1; dot,
              horizontal/vertical FIGD, GCHRD in two orthogonal directions,
              one-hot WDAT and full-MASK WDAT stepping in all eight DIR values.
              The full-MASK family isolates pure word-address/PITCH stepping
              from dAD boundary behavior.

RUNDRAW.BAT   FIGD dot/line/raw-DDA/rectangle/arc/chaining plus GCHRD PRAM
              orientation, area fill, zoom, slant and safe edge fingerprints.

RUNRDX.BAT    Extended RDAT matrix: word/low/high, all DIR values, DC
              0,1,2,15,16,17 and several MASK values.

RUNRESET.BAT  RESET/FIFO/parser recovery only.  It intentionally does not
              characterize SYNC/raster timing.  BIOS restores the GDC after
              every destructive probe.

RUNTIME.BAT   GDC command/execution timing characterizer.  Uses the PC-98
              system PIT as a raw tick reference and records every sample in
              GDCTRAW.CSV plus robust summaries in GDCTIME.CSV.  It is the
              final stage of RUNFULL.

RUNFULL.BAT   All safe profiles above.  Does NOT run undefined/reserved cases.

RUNUNDEF.BAT  Explicit opt-in only.  Reserved/undefined command combinations
              may behave badly or hang.  Preserve the safe RUNFULL dataset
              before running this profile.

CLEAN.BAT     Removes only files created under GDCRES.

RESULT SEMANTICS
----------------
STRICT  The tested behavior is treated as a direct documented invariant.
        A FAIL must still be retained; it may expose a PC-98-specific rule or
        an error in the current interpretation of the documentation.

INFO    No emulator or guessed software model is used as the oracle.  Exact
        observed bytes/words/status/CURD state are the result.

ERROR   A bounded timeout, I/O failure or recovery problem occurred.  Other
        completed files in the run remain valuable.

RAW VRAM DUMPS (.VRD)
---------------------
GDCVRD1 files are sparse binary before/after dumps.  They preserve EVERY word
changed by a case even when the CSV human-readable summary is truncated.
Each change stores plane, word offset, before value and after value.  These
are the primary rendering traces for FIGD/GCHRD/WDAT/PITCH tests.

Host tools in the developer package decode and render VRD records.  The PGM
renderer accounts for PC-98 CPU-visible byte-local bit order and shows a
delta footprint rather than a palette screenshot.

INDIVIDUAL PROGRAMS
-------------------
GDCCURS   CURS/CURD, 18-bit EAD, dAD, implicit/explicit MASK ordering.
GDCSTATE  FIGS defaults, parameter parser and persistent ROP/pattern state.
GDCADDR   GVRAM plane/EAD mapping, 18-bit carry/alias and boundary stepping.
GDCFIFO   Tight status sampling, DRAWING/FIFO behavior, parser recovery.
GDCWDAT   Graphics-mode WG=0 WDAT truth table, byte transfers, streaming,
          DC/DIR stepping; raw VRD.
GDCWG     uPD7220A CURS.WG extension: bit0-replicated vs direct WDAT data,
          ROP/MASK matrix and WG persistence; raw VRD.
GDCRDAT   Basic RDAT, DATA READY/FIFO turnaround and abort behavior.
GDCRDX    Extended RDAT count/direction/MASK matrix.
GDCROP    FIGD MOD/ROP, PRAM pattern phase and long pattern lines; raw VRD.
GDCPITCH  Complete monolithic pitch test (manual use).
GDPIT0-3  Restartable chunks used by RUNPITCH.BAT.
GDCDRAW   dot, canonical small-vector matrix, raw DDA, rectangle/raw rectangle,
          arc/raw arc and chaining; raw VRD.
GDCGCHR   64 one-hot PRAM bits x DIR, PRAM 8..15 address decode, areas,
          zoom x1..x16, REPLACE and slant; raw VRD.
GDCQUIRK  Safe plane-boundary/MASK edge fingerprints; raw VRD.
GDCRESET  RESET/parser/FIFO recovery, no display timing characterization.
GDCTIME   command parser/FIFO drain and execution-time fingerprints for FIGD,
          line slope/direction/length, ROP/pattern, PITCH/DGD, rectangle, arc,
          GCHRD and WDAT.  Summary in GDCTIME.CSV; every raw PIT sample in
          GDCTRAW.CSV.
GDCUNDEF  reserved/undefined opt-in probes.

SAFETY / RECOVERY
-----------------
Polling loops are bounded.  GRCG/EGC are disabled for naked-GDC tests.  Test
programs keep graphics output disabled and use BIOS setup to recover standard
640x400 GDC state before exit.  Undefined/reserved probes are isolated from
normal profiles.

If a machine nevertheless hangs, reset it and retain every file already
committed in GDCRES.  Result rows and VRD records are committed incrementally.

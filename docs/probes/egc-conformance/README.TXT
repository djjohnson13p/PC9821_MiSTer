PC-98 EGC CONFORMANCE / FINGERPRINT SUITE v1.3
================================================

This directory can be copied as-is to a PC-98 DOS volume.

Before a real-hardware run, edit MACHINE.TXT if possible.

Recommended order:

  RUNREAD.BAT   - read / compare / read-shifter / color-key
  RUNWRITE.BAT  - write / ALU / PLOAD_W / write-shifter / state
  RUNALL.BAT    - complete suite, including combined-state run
  CLEAN.BAT     - removes only files created under EGCRES\

All output is placed under EGCRES\.

IMPORTANT FOR REAL HARDWARE
---------------------------
A FAIL is still useful experimental data.  Do not discard EGCRES because
READSUM.TXT, WRITESUM.TXT or SUMMARY.TXT says FAIL.  Copy the complete
EGCRES directory off the machine.

v1.3 CORRECTIONS
----------------
* FG/BG writes are performed only after selecting FG/BG in port 04A2h.
* Normal PLOAD_R loads the selected PAT plane only.  Four-plane PAT setup
  uses four selected reads.  Compare+PLOAD_R is tested separately.
* The high-byte accelerated color-key write seen on the V166 is not forced
  into a strict oracle; EGCWRITE decomposes the byte write path.

SHIFT COVERAGE
--------------
Write-side: all 256 srcbit/dstbit pairs are strict tests.
Read-side: representative 1,2,7,8,15 phases, both alignment directions,
sequential carry, reverse direction and byte reads are fingerprinted.
Compare with nonzero alignment is fingerprinted separately.

FILES
-----
EGCALL.EXE    all groups
EGCROP.EXE    all 256 ternary ROPs
EGCSHFT.EXE   write shifter / length
EGCQUIRK.EXE  legacy/reserved fingerprints
EGCREAD.EXE   focused read/compare/color-key
EGCWRITE.EXE  focused write/ALU/PLOAD/shifter/state

The complete developer package contains detailed documentation and host-side
fingerprint decoders.

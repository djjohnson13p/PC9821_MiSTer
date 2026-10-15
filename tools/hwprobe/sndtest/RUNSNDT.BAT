@ECHO OFF
REM ============================================================
REM  SNDTEST: controlled OPNA (YM2608) audio-calibration stimulus
REM  for the PC-9801-86 (the SSG:FM balance re-measure).
REM  Copy SNDTEST.COM + this file to a DOS disk. Run:  RUNSNDT
REM  Send back SNDTEST.TXT **and the line-out recording**.
REM
REM  SET THE LEVEL FIRST, THEN START THE RECORDER. This is a
REM  calibration signal, not music, and it does NOT ramp: the
REM  first sound is the SSG's maximum (the SEG 00 marker at
REM  volume 15 = 0 dB) and the loudest state in the run is the
REM  final quiet/loud pair, where every source runs at maximum.
REM  The loudest thing the card can make is its own FM+ADPCM
REM  clamp - a level game content commands - and the run ends
REM  silent. Prefer line-out over headphones.
REM
REM  The program's first sound is the double-beep start marker
REM  (SEG 00, 2971 Hz, two 100 ms beeps with a 150 ms gap) -
REM  that is the recording's t0, and every later segment's
REM  offset is in SNDTEST.TXT (and checked by
REM  tools/sndtest_check.py).
REM
REM  RECORD RAW / UN-NORMALIZED at the machine's own volume, WAV,
REM  and do not apply gain or normalization afterwards: the whole
REM  point is absolute level.
REM  Total run ~1.5-2 minutes, 45 segments, each bracketed by 0.5 s
REM  of silence.
REM
REM  SAFETY: no disk access, no DMA. It writes only the base-bank
REM  OPNA ports 0x188/0x18A (SSG/rhythm/FM registers) and the
REM  8259 slave IMR, which RESTORE replays. 0xA460 and the
REM  extended bank are never touched. The run ends silent.
REM ============================================================

IF NOT EXIST SNDTEST.COM GOTO NOPROG

ECHO Running SNDTEST (about 1.5-2 minutes; recorder on, level already set)...
SNDTEST > SNDTEST.TXT

ECHO.
FIND "SNDTEST DONE" SNDTEST.TXT > NUL
IF ERRORLEVEL 1 GOTO INCOMPLETE
ECHO SNDTEST DONE - all 45 segments printed.
ECHO Copy SNDTEST.TXT and the recording off the machine.
GOTO END

:NOPROG
ECHO SNDTEST.COM is not in this directory.
GOTO END

:INCOMPLETE
ECHO SNDTEST did not reach its DONE line: the card may be absent or a
ECHO segment hung. The LAST "SEG nn" line in SNDTEST.TXT names where.
ECHO Send SNDTEST.TXT anyway - the segments before it are still valid.

:END

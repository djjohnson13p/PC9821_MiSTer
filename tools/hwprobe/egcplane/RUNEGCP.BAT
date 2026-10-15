@ECHO OFF
REM RUNEGCP.BAT - collect the EGC plane-count benchmark.
REM
REM Copy EGCPLANE.COM and this file to the machine, then:
REM     RUNEGCP
REM and send back EGCP.TXT.
REM
REM The output SHOULD be redirected (the batch does it). The GVRAM is scribbled by design (this is a graphics
REM benchmark); the EGC/GRCG are left off and the 0xA6 access page at 0. The disk
REM is never written (INT 21h AH=02/4C only).

IF NOT EXIST EGCPLANE.COM GOTO NOPROG

ECHO Running the EGC plane-count benchmark (a few seconds)...
EGCPLANE > EGCP.TXT

FIND "END:EGCPLANE" EGCP.TXT > NUL
IF ERRORLEVEL 1 ECHO    EGCP.TXT  INCOMPLETE - no END:EGCPLANE marker
IF NOT ERRORLEVEL 1 ECHO    EGCP.TXT  ok
ECHO Send EGCP.TXT back. Decode with: python3 tools/hwprobe/egcplane/egcplane_decode.py EGCP.TXT
GOTO END

:NOPROG
ECHO EGCPLANE.COM is not in this directory.
ECHO Copy EGCPLANE.COM here first, then run RUNEGCP again.

:END

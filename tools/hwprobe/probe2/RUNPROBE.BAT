@ECHO OFF
REM RUNPROBE.BAT - collect every PC-9821 hardware measurement in one run.
REM
REM Copy PROBE2.COM and this file to the machine, then:
REM     RUNPROBE
REM and send back ALL.TXT (or the individual files if a section hung).
REM
REM The order is deliberate. PROBE2 with no arguments performs no writes at
REM all, so its values are the genuine POST/DOS residue and must be captured
REM before anything else touches a latch - including this batch file's own
REM output is fine (the console writes text VRAM, which is why PROBE2 takes
REM its VRAM snapshot before printing its first character). /SRST runs last
REM because it is the only section that can leave a drive busy.

IF NOT EXIST PROBE2.COM GOTO NOPROG

ECHO [1/7] read-only snapshot (POST residue)...
PROBE2 > R.TXT
ECHO [2/7] port scan...
PROBE2 /PORTS > PORTS.TXT
ECHO [3/7] GDC status histograms...
PROBE2 /GDC > GDC.TXT
ECHO [4/7] calendar...
PROBE2 /CAL > CAL.TXT
ECHO [5/7] ATA: IDENTIFY and LBA 0 read...
PROBE2 /ATA > ATA.TXT
ECHO [6/7] GVRAM windows...
PROBE2 /VRAM > VRAM.TXT
ECHO [7/7] ATA soft reset (last)...
PROBE2 /SRST > SRST.TXT

ECHO.
ECHO Section completion (a section that hung leaves BEGIN: with no END:):
FIND "END:SNAPSHOT" R.TXT > NUL
IF ERRORLEVEL 1 ECHO    R.TXT  INCOMPLETE - no END:SNAPSHOT marker
IF NOT ERRORLEVEL 1 ECHO    R.TXT  ok
FIND "END:PORTS" PORTS.TXT > NUL
IF ERRORLEVEL 1 ECHO    PORTS.TXT  INCOMPLETE - no END:PORTS marker
IF NOT ERRORLEVEL 1 ECHO    PORTS.TXT  ok
FIND "END:GDC" GDC.TXT > NUL
IF ERRORLEVEL 1 ECHO    GDC.TXT  INCOMPLETE - no END:GDC marker
IF NOT ERRORLEVEL 1 ECHO    GDC.TXT  ok
FIND "END:CAL" CAL.TXT > NUL
IF ERRORLEVEL 1 ECHO    CAL.TXT  INCOMPLETE - no END:CAL marker
IF NOT ERRORLEVEL 1 ECHO    CAL.TXT  ok
FIND "END:ATA" ATA.TXT > NUL
IF ERRORLEVEL 1 ECHO    ATA.TXT  INCOMPLETE - no END:ATA marker
IF NOT ERRORLEVEL 1 ECHO    ATA.TXT  ok
FIND "END:VRAM" VRAM.TXT > NUL
IF ERRORLEVEL 1 ECHO    VRAM.TXT  INCOMPLETE - no END:VRAM marker
IF NOT ERRORLEVEL 1 ECHO    VRAM.TXT  ok
FIND "END:SRST" SRST.TXT > NUL
IF ERRORLEVEL 1 ECHO    SRST.TXT  INCOMPLETE - no END:SRST marker
IF NOT ERRORLEVEL 1 ECHO    SRST.TXT  ok

COPY /B R.TXT+PORTS.TXT+GDC.TXT+CAL.TXT+ATA.TXT+VRAM.TXT+SRST.TXT ALL.TXT > NUL
IF EXIST ALL.TXT ECHO Combined capture written to ALL.TXT
ECHO.
ECHO Send ALL.TXT back, or the individual files if a section was incomplete.
GOTO END


:NOPROG
ECHO PROBE2.COM is not in this directory.
ECHO Copy PROBE2.COM here first, then run RUNPROBE again.

:END
@ECHO OFF
REM RUNGFX2.BAT - collect the per-subsystem graphics benchmark.
REM
REM Copy GFXBENC2.COM and this file to the machine, then:
REM     RUNGFX2
REM and send back GFX2.TXT.
REM
REM The output MUST be redirected: the text-TRAM section writes the text plane
REM (0xA0000), which is the visible console, so an unredirected run's later lines
REM cannot be read on screen. The GVRAM is scribbled by design (this is a graphics
REM benchmark); the EGC/GRCG are left off and the 0xA6 access page at 0. The disk
REM is never written (INT 21h AH=02/4C only).

IF NOT EXIST GFXBENC2.COM GOTO NOPROG

ECHO Running the per-subsystem graphics benchmark (a few seconds)...
GFXBENC2 > GFX2.TXT

FIND "END:GFXBENC2" GFX2.TXT > NUL
IF ERRORLEVEL 1 ECHO    GFX2.TXT  INCOMPLETE - no END:GFXBENC2 marker
IF NOT ERRORLEVEL 1 ECHO    GFX2.TXT  ok
ECHO Send GFX2.TXT back. Decode with: python3 tools/hwprobe/gfxbenc2/gfxbenc2_decode.py GFX2.TXT
GOTO END

:NOPROG
ECHO GFXBENC2.COM is not in this directory.
ECHO Copy GFXBENC2.COM here first, then run RUNGFX2 again.

:END

@ECHO OFF
REM ============================================================
REM  MEMMAP - the memory map as DOS and an extender see it.
REM  Copy MEMMAP.COM + this file to a DOS disk and run:  RUNMEM
REM
REM  Run it TWICE on each machine (Xe10 and core, same RAM size):
REM    1. booted with DOOM's own CONFIG.SYS/AUTOEXEC.BAT
REM       (HIMEM/EMM386 as DOOM runs) -> rename MEMMAP.TXT MEMDOOM.TXT
REM    2. booted CLEAN (no HIMEM, no EMM386): this is the only
REM       boot where the PHYS section and its write tests run
REM       -> rename MEMMAP.TXT MEMCLEAN.TXT
REM
REM  WRITES: A20 (0xF2/0xF6, restored); with NO XMS driver, the
REM  dword at 0xF80000 and at N MiB + 0x100 (N = 1..127), each
REM  saved first and restored. Ports 0x043B/0x0461/0x0463/0x063F
REM  are only READ.
REM ============================================================

IF NOT EXIST MEMMAP.COM GOTO NOPROG
ECHO Running MEMMAP...
MEMMAP > MEMMAP.TXT
ECHO.
ECHO Done. Send back MEMMAP.TXT (renamed as above).
GOTO END

:NOPROG
ECHO MEMMAP.COM is not in this directory.
ECHO Copy MEMMAP.COM here first, then run RUNMEM again.

:END

@ECHO OFF
REM ============================================================
REM  IRQWD - the masked-ack / request-withdraw capture.
REM  Fresh boot.  Run:  RUNWD        -> IRQWD.TXT
REM  Decode: python3 tools/hwprobe/irqwd/irqwd_decode.py IRQWD.TXT
REM  It masks one line at a time, triggers a request, polls the
REM  IRR until it latches, does the acking access, and reads the
REM  IRR again.  postack bit set = HOLD; clear = WITHDRAW.
REM  Nothing is delivered and no vector is touched, so the
REM  keyboard cannot be left disabled.  IRQ1 asks you to press a
REM  key (bounded wait; the prompt is on the screen too).  It
REM  saves and restores the master/slave IMRs, 0x0432 and the
REM  calendar rate, and stops the OPNA timers.  It never
REM  reprograms the PIT.  A hang is a BEGIN: with no END: - the
REM  rows before it are still valid; power-cycle and send the file.
REM ============================================================
IF NOT EXIST IRQWD.COM GOTO NOPROG
IRQWD > IRQWD.TXT
ECHO.
ECHO IRQWD finished.  Copy IRQWD.TXT off the machine BEFORE the next boot.
GOTO END

:NOPROG
ECHO IRQWD.COM is not in this directory.
:END

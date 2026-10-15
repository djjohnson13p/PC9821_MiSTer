@ECHO OFF
REM ============================================================
REM  RUNINTEG: the storage-integrity run (INTEG.COM). Read
REM  tools/hwprobe/integ/integ.s (its header) first.
REM
REM
REM  Copy to ONE DOS directory: INTEG.COM, this file, and the
REM  host-generated manifests (integ_manifest.py), one per drive:
REM     C_INTEG.MAN  the hard disk's files   (--drive C:)
REM     A_INTEG.MAN  a floppy's files        (--drive A:)
REM     E_INTEG.MAN  the CD's files          (--drive E:)
REM
REM    RUNINTEG          the verifies and the write/read-back, silent CD
REM    RUNINTEG /PLAY    the same WHILE CD-DA plays: INTEG P starts the audio
REM                      (MSCDEX; see integ.s), the checks run, INTEG S stops it.
REM                      INTEG_P.TXT holds the PLAY row: it must say PLAY OK
REM
REM  Output: INTEG_C.TXT, INTEG_A.TXT, INTEG_E.TXT (verify), INTEG_WC.TXT,
REM  INTEG_WA.TXT (write/read-back). Each ends "INTEG END FAILS=nnnn";
REM  anything but 0000 is a corrupt read or write.  Copy them off.
REM  INTEG_OK.TXT is written LAST: its presence means the run finished
REM  (tools/mister_regress.py polls for it).
REM  The write mode creates and deletes C:\INTEGTMP.DAT / A:\INTEGTMP.DAT.
REM ============================================================
IF "%1"=="/PLAY" INTEG P > INTEG_P.TXT
IF EXIST C_INTEG.MAN INTEG V C_INTEG.MAN > INTEG_C.TXT
IF EXIST A_INTEG.MAN INTEG V A_INTEG.MAN > INTEG_A.TXT
IF EXIST E_INTEG.MAN INTEG V E_INTEG.MAN > INTEG_E.TXT
INTEG W C: /K:512 > INTEG_WC.TXT
IF EXIST A_INTEG.MAN INTEG W A: /K:256 > INTEG_WA.TXT
IF "%1"=="/PLAY" INTEG S >> INTEG_P.TXT
ECHO done > INTEG_OK.TXT
ECHO done: look for "FAILS=0000" at the end of each INTEG_*.TXT

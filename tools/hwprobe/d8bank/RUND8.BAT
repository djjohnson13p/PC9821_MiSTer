@ECHO OFF
REM D8BANK - the 0xD8000 window per I/O 0x063C bank select (EMM386 /UMB boot hang).
REM Run on PLAIN DOS (no EMM386/VEM486). Writes D8BANK.TXT and D8BANK0..3.BIN.
D8BANK > D8BANK.TXT

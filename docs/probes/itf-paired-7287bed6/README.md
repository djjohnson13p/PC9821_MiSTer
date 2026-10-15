# Paired ITF/DOS snapshots (probe bundle 7287bed6)

The `D2` conventional-memory snapshot taken by the same probe binary on the Xe10 (`xe10/`)
and on this core (`mister/`), each after a cold and a warm boot. DOS text encoding and CRLF
are retained. Both runs booted DOS 6.20 with a plain conventional-memory profile (neither
HIMEM nor EMM386 loaded), so these are bare-conventional baselines.

Only the `D2` files are kept: they are the ones cited (the FDC's drive-1 work-area byte
`[0x55C]`). The probe's MCB-chain diagnostics in the original bundle had known decoding
defects and are not evidence.

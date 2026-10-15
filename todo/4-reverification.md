# 4. Re-verification items

Claims that rest on a single sample, or a divergence whose cause is still unknown.

42. **`0x7C` 16-bit word `IN`.** **CAPTURE-PENDING.** Only byte reads of `0x7C` were captured
    (open bus). **Done when:** a word-read probe shows whether a word read returns a live
    register, and `pc9821_iobus.sv` follows it.

43. **DMA bank ports `0x21/0x23/0x25/0x27`: low-nibble width.** **NEEDS RE-VERIFICATION.** The
    latch masks with `& 0x0F` from one capture (`docs/probes/RDBACK.TXT`: `A5 -> 05`); NP2kai's
    IA32 build stores the byte unmasked. **Done when:** a second marker (e.g. `0x5A`) confirms the
    mask is exactly the low nibble.

47. **ADPCM-A rhythm sounds on the core without a driver; the machine's is silent.**
    **CAPTURE-PENDING.** With PMD resident the drum levels agree within 0.9 dB (-35.8 vs
    -34.9 dBFS); with no driver the machine is silent and the core plays. Until resolved,
    drum-level comparisons use the PMD-resident run. **Done when:** the PMD load-time writes that
    enable the rhythm (sound-BIOS ROM mapping, a board mixer setup, or the -86's ADPCM clock) are
    logged on the core and reproduced one by one on the machine, and the core gates the rhythm
    the same way.

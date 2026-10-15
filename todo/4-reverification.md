# 4. Re-verification items

Claims that exist but rest on a single sample or need a re-check before they are relied on.

41. **I/O timing ladder: the `0x5F` anchor.** **VERIFIED (HW) - settled.** The early `/TIME`
    ladders disagreed with each other (each run had its own time base). The self-calibrating
    `ioprobe` (`docs/probes/IO.TXT`) measures the `0x5F` write at 1621 ns over its control, and
    `docs/probes/IDELAT.TXT`'s calibration row agrees (1647 ns): the documented 600 ns is the
    inserted wait only, and the class table's 81-clock axis is right. Quote absolute ns only from
    the self-calibrating probes. Nothing further is owed; item 82 carries the per-class decision.

42. **`0x7C` 16-bit word `IN`.** **CAPTURE-PENDING.** Only byte reads of `0x7C` were captured
    (open bus). Whether a word read returns a live register is unmeasured. **Next:** a
    word-read probe.

43. **DMA bank ports `0x21/0x23/0x25/0x27`: low-nibble width.** **NEEDS RE-VERIFICATION.** The
    latch is implemented with a `& 0x0F` width taken from one capture (`docs/probes/RDBACK.TXT`:
    `A5 -> 05`); NP2kai's IA32 build stores the byte unmasked. **Next:** a second marker (e.g.
    `0x5A`, and a value with high bits in other positions) to confirm the mask is exactly the low
    nibble.

44. **GDC LPEN constants.** **NEEDS RE-VERIFICATION.** See item 13: repeat the capture before
    changing the model.

45. **SSG / PC-speaker DC convention.** **UNVERIFIED (INFERRED).** The YM2608 outputs the SSG on
    a separate analog pin, and the core joins it to the FM+ADPCM sum zero-mean (a DC block, i.e.
    the board's series coupling capacitor), not clamped with FM. ymfm adds its SSG after the
    clamp. **Next:** confirm the PC-9801-86's SSG coupling and sign from a capture or the
    schematic before changing the mix. The FM+ADPCM sum stays clamped once at `jt08_acc`.

47. **ADPCM-A rhythm needs a driver on the machine, not on the core.** **CAPTURE-PENDING.** The
    rhythm path matches the die (the shipped rhythm ROM is the genuine die ROM, the six-drum bus is
    the die's 16-bit wrap, the junction clamp rails at +-32768), and the core's drum level is
    within 0.9 dB of the machine's with PMD resident (-35.8 vs -34.9 dBFS). But the machine's
    rhythm is SILENT with no driver resident, while the core plays it without one. **Open:** what
    PMD enables (the sound BIOS's rhythm-ROM mapping, a board mixer setup, or the -86's ADPCM
    clock). Until known, drum-level comparisons must use the PMD-resident run. **Next:** find
    which writes PMD makes at load that enable the rhythm (log them on the core, then reproduce
    them one by one on the machine).

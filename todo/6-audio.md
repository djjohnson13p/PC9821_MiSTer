# 6. Audio: OPNA/SSG/ADPCM

78. **OPNA `0xA466` DAC-control handling.** **UNVERIFIED (INFERRED).** The core adopts NP2kai's
    Policenauts/WinNT workaround, which is not hardware evidence. **Done when:** a capture or a
    datasheet justifies (or replaces) it.

87. **OPNA junction boundary: the die's 18-bit wrap vs the core's sum + clamp16.**
    **UNVERIFIED (INFERRED).** For reachable inputs (ADPCM-B unwired) the die's 18-bit junction
    mask (YM2608-LLE `fmopna_impl.c`) is inert and its shifter rails at +-32768, equal to the
    core's clamp (`jt08_acc.v`); above +-131072 the die would wrap where the core rails. The
    die's 14-bit per-channel mask may make the wrap unreachable. **Done when:** a die-sourced
    boundary bench settles reachability (`sndtest`'s BD+SD+TOM hot-triple is the machine
    stimulus).

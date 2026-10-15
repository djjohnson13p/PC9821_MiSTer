# 6. Audio: OPNA/SSG/ADPCM, rhythm, MIDI

57. **MIDI out (MPU-PC98II) is opt-in: the `midilink` build profile only.** **KNOWN GAP (BY
    DESIGN).** `src/pc9821/core/pc9821_mpu.sv` models the card's registers at `0xE0D0`/`0xE0D2`
    (response queue, DRR/DSR read-back, command ACKs, the all-notes-off burst, the H.CLK tick) and
    a 31250-baud serialiser on `UART_TXD`, so MiSTer's MidiLink carries it to USB MIDI or a network
    peer. It is built only by `build_profile.py midilink` (the `base` build leaves it out for area).
    Not implemented: MIDI IN, the intelligent-mode sequencer, and an MT32-pi on the user port.
    Capture-pending: the card's true H.CLK rate, its BUSY/DSR latencies, whether command `0xB9`
    exists, and whether `0xE0D1`/`0xE0D3` answer.

61. **WSS/MSS (PCM 16-bit) audio is not implemented.** **KNOWN GAP.** Only the PC-9801-86
    (OPNA + PCM86) and the beeper are modelled; titles that need a Windows Sound System-class
    card get no PCM from it.

78. **OPNA register leftovers.** **UNVERIFIED (INFERRED).** (a) The seed `ssg_reg[14] = 0xFF` is
    cosmetic. (b) The `0xA466` DAC-control handling adopts NP2kai's Policenauts/WinNT workaround,
    which is not hardware evidence. **Next:** a hardware or datasheet justification for (b).

87. **OPNA junction boundary: the die's 18-bit wrap vs the core's sum + clamp16.**
    **UNVERIFIED (INFERRED).** For the inputs this build can reach (ADPCM-B unwired), the die's
    18-bit junction mask (YM2608-LLE `fmopna_impl.c`) is inert and its output shifter rails at
    +-32768, which equals the core's clamp. Above +-131072 the die would wrap (a large positive
    sum rails negative) where the core rails positive. Before any change, resolve against the LLE:
    the die masks each channel's output at 14 bits, so its own FM contribution is bounded far below
    the core's raw 24-slot sum, and the wrap may be unreachable even with ADPCM-B. **Next:** a
    die-sourced boundary bench and a reachability decision. `sndtest`'s hot-triple segment (BD+SD+TOM
    at full level) is the machine stimulus.

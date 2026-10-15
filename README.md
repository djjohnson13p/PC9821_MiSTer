# PC-9821 z486 MiSTer core

A PC-9821 (NEC Xe10) core for
[MiSTer](https://github.com/MiSTer-devel/Main_MiSTer), with the 486 CPU in
`src/z486/` maintained in this repository (Apache-2.0; the licence files in that
directory carry the grant). It emulates a
mid-range 486 PC-9821: the PC-98 memory map and firmware interface, GDC text
and graphics, YM2608 sound, ATA IDE storage, keyboard, joystick and RTC. NEC
firmware is copyrighted and is not included — the core runs the ROM set dumped
from your own machine.

## What works

- Boots the authentic NEC Xe10 firmware set to DOS. The Xe firmware set does not work yet.
- Runs Touhou 1-5, including sprite-heavy gameplay.
- 640x400 16-colour planar GVRAM with GRCG/EGC drawing, ANK and JIS kanji,
  palette, 848x440 GDC timing.
- YM2608 (FM, SSG, ADPCM rhythm) and the PC-9801-86 PCM block through the
  MiSTer mixer.
- ATA IDE storage from MiSTer-mounted images (CHS and LBA28, PIO).
- An ATAPI CD-ROM drive with CD-DA audio (ISO or PCD images), in every build.
- PC-98 keyboard, two-button joystick, RTC/calendar, PIT, PIC, software DIPs.

## Requirements

- A MiSTer DE10-Nano with the SDRAM addon board.
- Your own PC-9821 Xe10 ROM dump: `BANK0.BIN`..`BANK7.BIN`, `BIOS.ROM`,
  `FONT.ROM`, plus optional YM2608 rhythm samples. The pack is not
  redistributable and is **not included**. `make pack` builds it; the OSD
  `Load ROM pack` (`F0,BIN`) loads it.
- `firmware/diagnostic/` is the in-tree bring-up pack.

## DOS setup and drivers

The core runs your own NEC MS-DOS installation from a hard-disk image. None of the drivers
below are included: they come from your machine's NEC MS-DOS.
Inside DOS the hard disk is `A:` and the CD is `Q:` in the configuration below.

### CD-ROM

The drive is ATAPI on the built-in IDE, at **bank 1's master**, the position NEC's own
built-in-CD drivers look at. The hard disk is always **bank 0's master**, with or without the CD
built in - the layout of a stock CD-equipped Xe10. Mount a disc
with the OSD's `Mount CD-ROM` and remove it with `Eject CD-ROM`. Images are `.ISO` (data only)
or `.PCD`. A PCD carries the track list, so mixed-mode discs with CD-DA audio need one. The core
cannot mount a `.cue` directly: a core only sees the one file an OSD slot opens, never the BIN
files a CUE names. Convert a CUE/BIN set (single or multiple BIN files, data and audio tracks,
pregaps) into a PCD in either of two ways:

- **On the MiSTer:** put the `.cue` and its `.bin` files anywhere under `games/PC9821/` and run
  `pc9821_cue2pcd` from the main menu's Scripts entry (`tools/mister_load.sh` installs it in
  `Scripts/`). It writes a `.pcd` beside each `.cue` that does not already have an up-to-date one,
  checks free space first, and never changes the `.cue`/`.bin` files. Delete them yourself once the
  PCD works if you want the space back. A 650 MB disc takes a minute or two.
- **On a PC:** `python3 tools/cue2pcd.py game.cue game.pcd`.

The configuration verified on the MiSTer is NEC's `NECCD.SYS` plus Microsoft's `MSCDEX.EXE`:

```
REM CONFIG.SYS
DEVICE=A:\DOS\HIMEM.SYS
DEVICE=A:\DOS\NECCD.SYS /D:CD_101
LASTDRIVE=Z

REM AUTOEXEC.BAT
LH A:\DOS\MSCDEX.EXE /D:CD_101 /L:Q
```

- **`NECCD.SYS`** is the driver to use. Its banner reads "Sony ATAPI CDROM Device Driver 2.10".
  It reads data and plays CD-DA through MSCDEX, and handles programs that call the driver
  directly. It works both with HIMEM only and with EMM386 `/UMB`.
- **The `/D:` name must match** between the driver and MSCDEX. `CD_101` is NEC's convention;
  any name works if both lines use it.
- **`PATACD.SYS /D:CD_101`**, the generic ATAPI driver, finds the drive and DOS can read files
  through it. It rejects some IOCTL calls that programs make to the driver directly, so prefer
  `NECCD.SYS`.
- **`NECCDM.SYS` and `NECCDD.SYS`**, NEC's other built-in-CD drivers, expect the same bank-1
  master position but are **not verified** on this core. `NECCDA.SYS`/`NECCDB.SYS` are for SCSI
  cards and do not apply.
- **A CD-DA play blocks file reads.** While an audio track plays, NECCD answers file reads with
  `CDR101: Not ready`. This is NEC driver behaviour: it polls the drive, sees "audio playing" and
  refuses before reading. It matches NP2kai's drive model.

### Memory managers

- **`HIMEM.SYS`** is needed by almost everything (`DOS=HIGH`).
- **`EMM386.EXE /UMB`** works for EMS and upper memory, including with the CD drivers loaded
  high.

## Building and running

```sh
make base                         # 80 MHz profile, the default and shipping build
make build                        # fit -> output_files/z486_mister.rbf (containerised)
make bench                        # run the Verilator unit benches
make pack PC98_DUMPS=/path/dumps  # build the firmware pack from your dumps
MISTER_HOST=root@MiSTer ./tools/mister_load.sh   # deploy and load on the card over ssh
```

Build profiles: `base` (80 MHz, the default and shipping build), `trace` (the **debug
build**: base + instruction-trace/perf-log telemetry, and the one profile fit with
`OPTIMIZATION_TECHNIQUE AREA`), `iofaithful` (base + the machine-timed I/O class table),
`midilink` (base + the MPU-PC98II MIDI card), `lightoc` (an alias of `base`, kept for old
commands), and two faster overclocks — `mediumoc` (100 MHz) and `heavyoc` (120 MHz, at the
board SDRAM's ~120 MHz limit). The SDRAM runs on clk_sys in every one of them: there is one
core clock and no SDRAM clock-domain crossing. Any field of a profile can be overridden, or a
custom one defined (`./build_profile.py base --trace`, `./build_profile.py --custom
--clk-sys-mhz 90`, `--profile-file FILE`); the PLL and the constraints are generated for it.
Real timing closure is ~54 MHz, so every preset, `base` included, runs past closure (the
ao486/MiSTer convention; the 80 MHz build is hardware-verified), and stability is board- and
temperature-dependent. Every preset builds the ATAPI CD-ROM drive (ISO/PCD images, with
CD-DA audio) on IDE bank 1, mounted from the OSD's `Mount CD-ROM`; `--no-cdrom` leaves it out
and `--no-cdrom-audio` builds a data-only drive. Deeper detail lives in
[`docs/pc9821-port-status.md`](docs/pc9821-port-status.md).

## Documentation

- [`AGENTS.md`](AGENTS.md) - the contributor and coding-agent guide: repository layout, build
  profiles, the containerised Quartus build, the gates, and how to test on a real MiSTer
  (deploying, screenshots, scripted keys and mouse, the debug UART, the regression runner).
- [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) - the contribution entry point and the
  project's design rule (the Single-Cycle Event Discipline).
- [`docs/pc9821-port-status.md`](docs/pc9821-port-status.md) - implementation status and
  measured machine behaviour.
- [`docs/z486-local-patch.md`](docs/z486-local-patch.md) - how the vendored CPU is kept in step
  with its fork.
- [`docs/timing.md`](docs/timing.md) - where the critical paths are and the known free cuts.
- [`docs/trade-candidates.md`](docs/trade-candidates.md) - open area/latency trade-offs.
- [`TODO.md`](TODO.md) - the open-work list.

## Known issues and limitations

**Supported machine**

- Only the Xe10 firmware set is supported. The tools can build and load an Xe pack
  (`--machine xe`), but the core does not run the Xe firmware yet.

**Timing and builds**

- Every build runs past timing closure (real closure is about 54 MHz; the shipping `base` build
  is 80 MHz). 80 MHz is stable on the boards it has been tested on, but stability is board- and
  temperature-dependent. Custom builds above about 87.5 MHz are unreliable: 90 MHz depends on the
  placement seed and 95 MHz and up do not boot. If a build misbehaves, try `base`.
- The `CPU Speed` OSD setting slows only the CPU (a gated CPU clock); the bus and every device
  keep their full speed, and z486's cycles per instruction are not a real 486's or 286's. The
  settings are approximate speeds for games that run too fast, not period-accurate timing.

**DOS, drivers and games**

- DOOM does not start under EMM386 on this core: boot it with HIMEM only.
- Flame Zapper Kotsujin fails with NEC's `EMM.SYS` (1989) as its EMS driver: the intro runs
  slowly with sprites left uncleared, or the screen stays black. It runs correctly under
  `EMM386.EXE /UMB`. Whether a real Xe10 runs it under `EMM.SYS` is not known.
- CD-ROM: use `NECCD.SYS` + `MSCDEX.EXE` (see above). `NECCDM.SYS` and `NECCDD.SYS` are
  untested; `PATACD.SYS` reads files but rejects some direct driver calls.

**Hardware not modelled, or partial**

- Floppy: D88, raw and HDM images read and write, and raw images can be formatted, but a FORMAT
  on a D88 image answers write-protected, and the media-type/rpm selection (2HD vs 2HS) is not
  checked against the image.
- The DMA controller (uPD71071) serves the floppy; the PC-9801-86 PCM is not fed by DMA.
- WSS/MSS 16-bit audio is absent.
- PEGC 256-colour: the display side (registers, packed scanout, 256-entry palette) is
  implemented; the PEGC plane-mode drawing engine is not.
- Most GDC2 (graphics GDC) drawing commands are accepted but not executed: SCROLL, display
  control and the WRITE family (WDAT/VECTW/CSRW/WRITE) are implemented; the line, rectangle,
  arc and character drawing figures are not.
- The serial port is not modelled.
- Only the 24 kHz (640x400) display timing is modelled; the 15 kHz and 31 kHz modes are not.
- Text mode always uses 16-line character rows, so the 20- and 30-line text modes do not
  display correctly. Only the first text scroll area is shown (no split screen), smooth
  scrolling is not modelled, and the monochrome graphics mode (`0x68` bit 1) shows colour.
- MIDI out (an MPU-PC98II) exists only in the opt-in `midilink` build profile, out only.
- Some rarely used ports are approximations pending real-machine captures (for example `0x66`,
  `0x6C`, `0x60` bit 6, the `0x043F` read-back and the IDE work-RAM window at `0xDA000`);
  [`TODO.md`](TODO.md) lists each with what would settle it.

NEC and Yamaha ROM data are copyrighted; supply your own dumps.

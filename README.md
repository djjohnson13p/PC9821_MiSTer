# PC-9821 z486 MiSTer core

A PC-9821 (NEC Xe10) core for [MiSTer](https://github.com/MiSTer-devel/Main_MiSTer), built on
the z486 486 CPU. It boots NEC's Xe10 firmware to MS-DOS and runs PC-98 DOS software, including
CD-ROM titles with CD audio.

## What works

- The NEC Xe10 firmware set boots to DOS. The Xe firmware set does not work yet.
- Touhou 1-5 run, including sprite-heavy gameplay.
- 640x400 16-colour graphics with GRCG/EGC drawing, ANK and JIS kanji text.
- YM2608 sound (FM, SSG, ADPCM rhythm) and the PC-9801-86 PCM.
- IDE hard-disk images, an ATAPI CD-ROM drive with CD audio, and floppy images.
- PC-98 keyboard, two-button joystick and the real-time clock.

## What you need

- A MiSTer DE10-Nano with an SDRAM board.
- The Xe10 BIOS pack, which is **not included**. Download `pc98pack-xe10.bin` from
  <https://archive.org/download/PC9821-xe-xe10-bios>. Only that file is needed; the Xe pack
  does not run yet.
- A PC-98 hard-disk image with NEC MS-DOS installed. The DOS drivers mentioned below come with
  NEC MS-DOS and are not included.

## Installing

Copy these to the SD card:

| file | where |
|---|---|
| the core, `PC9821Z486.rbf` | `_Computer/PC9821Z486.rbf` |
| the menu entry, `PC9821Z486.mgl` | the card's root |
| the BIOS pack | `games/PC9821/pc98pack-xe10.bin` |
| your hard-disk image | anywhere; `games/PC9821/` is where the file browser opens |

## Running

1. Choose **PC9821Z486** in the MiSTer menu. The MGL starts the core and loads the BIOS pack;
   loading the `.rbf` on its own leaves the core without a BIOS.
2. Open the OSD (F12), choose **Mount HDD** and pick your hard-disk image. Mounting it restarts
   the machine, which then boots from that disk.

Useful OSD settings:

- **RAM Size**: 16 MB by default.
- **CPU Speed**: slows the CPU for software that runs too fast. The speeds are approximate,
  not period-accurate; `Full` is normal.
- **Mount CD-ROM**, **Mount FDD1/FDD2**: insert a CD or floppy image.

## DOS setup

Inside DOS, with the configuration below, the hard disk is `A:` and the CD is `Q:`.

**Memory**

- `HIMEM.SYS` is needed by almost everything (`DOS=HIGH`).
- `EMM386.EXE /UMB` provides EMS and upper memory.

**CD-ROM**

Use NEC's `NECCD.SYS` with Microsoft's `MSCDEX.EXE`. The `/D:` name must be the same on both
lines:

```
REM CONFIG.SYS
DEVICE=A:\DOS\HIMEM.SYS
DEVICE=A:\DOS\NECCD.SYS /D:CD_101
LASTDRIVE=Z

REM AUTOEXEC.BAT
LH A:\DOS\MSCDEX.EXE /D:CD_101 /L:Q
```

`PATACD.SYS` also reads files but rejects some calls that programs make to the driver directly.
`NECCDM.SYS` and `NECCDD.SYS` are untested.

**CD images**

Mount `.ISO` (data only) or `.PCD` images. Discs with CD audio tracks need a `.PCD`; the core
cannot open a `.CUE`/`.BIN` set directly. To convert one, put the `.cue` and its `.bin` files
under `games/PC9821/` and run `pc9821_cue2pcd` from the MiSTer menu's Scripts entry. It writes a
`.pcd` next to each `.cue` and leaves the originals alone.

## Known issues

- Only the Xe10 firmware set works.
- DOOM does not start under EMM386: boot it with HIMEM only.
- Flame Zapper Kotsujin fails with NEC's `EMM.SYS` (1989) as its EMS driver: the intro runs
  slowly with sprites left uncleared, or the screen stays black. It runs correctly under
  `EMM386.EXE /UMB`.
- While a CD audio track plays, `NECCD.SYS` refuses file reads (`CDR101: Not ready`). NEC's
  driver does this on real hardware too.
- Floppy: a FORMAT on a D88 image fails as write-protected.
- Not implemented: 16-bit WSS/MSS audio, the serial port, the 15 kHz and 31 kHz display modes,
  the 20- and 30-line text modes, split-screen and smooth text scrolling, the monochrome graphics
  mode, PEGC 256-colour drawing (256-colour display works), and the graphics GDC's line, arc,
  rectangle and character drawing.

## Development

Start with [`AGENTS.md`](AGENTS.md): the repository layout, the containerised Quartus build, the
build profiles, the test gates, and how to test on a real MiSTer. The basic build is:

```sh
make base     # apply the default 80 MHz build profile
make build    # fit the core -> output_files/z486_mister.rbf
make bench    # run the simulation benches
```

`make pack PC98_DUMPS=<dir>` builds a BIOS pack from your own Xe10 ROM dumps.

NEC and Yamaha ROM data are copyrighted and are not part of this repository. The z486 CPU in
`src/z486/` is Apache-2.0 (see the licence files there).

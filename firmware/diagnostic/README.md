# Redistributable native-platform diagnostic

`post.s` is an original, minimal real-mode payload for validating this core. It
contains no NEC firmware. `build.py` uses GNU `as` and `objcopy` to produce a
32 KiB ITF image in a 512 KiB ROM pack and generates deterministic synthetic
ANK glyph patterns without reading any external font. The extracted ANK window
occupies pack offsets `0x30000-0x30FFF`, separate from both BIOS banks.

```sh
./firmware/diagnostic/build.py --out /tmp/pc9821-diagnostic.bin
```

POST port `0x0EE0` values are:

| Code | Meaning |
|---|---|
| `10` | reset vector and real-mode entry reached |
| `20` | low-RAM DWORD write/read passed |
| `30` | text-GDC start and TRAM banner writes completed |
| `5A` | diagnostic completed; firmware is in its idle loop |
| `E1` | low-RAM test failed |

The full-system regression builds and loads this pack through the real ioctl
loader:

```sh
./tests/pc9821/run_boot.sh
```

It verifies POST progression, low-RAM signature `5A3C0BAD`, and the first TRAM
character/attribute bytes after z486 execution.

These are **test programs, not firmware**: they exist to drive the CPU, memory
and I/O paths from a known stimulus, and they never stand in for the machine's
BIOS. `ipl.s` is an original 512-byte PC-98 fixed-disk IPL carrying the `IPL1`
marker at bytes 4-7; it emits POST `A5`, writes low-RAM signature `0D05B007`,
updates TRAM, and enters a stable loop. Build it with:

```sh
./firmware/diagnostic/build.py --out /tmp/diag.bin \
  --disk-out /tmp/pc98-ipl.img
```

The end-to-end disk test mounts your own image through the MiSTer image
protocol, against the authentic firmware pack:

```sh
PC98_PACK=/path/to/pc98pack.bin PC98_USERDISK=/path/to/image.img \
  ./tests/pc9821/run_userdisk.sh
```

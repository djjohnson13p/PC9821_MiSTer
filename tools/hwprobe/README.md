# hwprobe - measuring a real PC-9821

DOS `.COM` programs that measure a real PC-9821, so the core's behaviour can be checked
against the machine rather than against an emulator. Their captures are kept in
[`docs/probes/`](../../docs/probes/), and benches cite those captures as the source of
their expected values. Only the probes whose captures (or whose decoders) are still cited
are kept here.

## Building

```
make -C tools/hwprobe            # every probe; or e.g. make -C tools/hwprobe ioprobe/ioprobe.com
make -C tools/hwprobe clean
```

GNU `as`/`ld`/`objcopy` (32-bit i386 support) are all that is needed. The build is
reproducible (same source, same bytes), and it refuses an image over the 65,280-byte DOS
`.COM` limit. The binaries are not committed. `pegcwatch` builds as `PEGCW.COM` (8.3 name).

## The probes

Each tool lives in its own folder: `<tool>/<tool>.s`, an optional `<tool>_decode.py`
(the capture decoder) and a `RUN*.BAT` (the DOS batch that runs it and redirects its output).

| Probe | What it measures | Capture |
|---|---|---|
| `probe2` | the general section-selectable probe: port sweep, memory windows, ROM shadow, VRAM/CG, GDC, EMS, game port, memory switches; write-then-read sections (`/RDBACK`, `/PIT`, `/VSYNC`, `/WIPE`) are opt-in and print a `PORT: was -> now` restore report. `wipe_decode.py` decodes `/WIPE` | `R10`, `PORTS`, `WIN`, `SHADOW*`, `VRAM*`, `GDC`, `RDBACK`, `PIT*`, `VSYNC`, `WIPE-rerun`, `EMS`, `JOY`, `MEMSW`, `ATA`, `TIME`, `TRS` |
| `ioprobe` | per-port I/O access cost for every class the core's I/O wait table names, each beside an interleaved control row; absolute ns against the ARTIC counter | `IO.TXT` |
| `ideprobe` | the IDE/ATA interface: bank select, task-file read-back, IDENTIFY, DIAG/reset error bytes, the IDE IRQ | `IDE.TXT` |
| `idelat` | IDE READ latency: command -> first DRQ, per-sector PIO, throughput, poll cost; read-only on disk; self-checks its two time bases | `IDELAT*.TXT` |
| `gfxbench` | raw VRAM/TRAM window bandwidth (`rep stosw`/`rep lodsw`) | `GFXB.TXT` |
| `gfxbenc2` | per-operation GVRAM drawing latency: plane writes, GRCG, EGC, text, net of loop-shell controls | `GFX2*.TXT` |
| `irqwd` | whether a masked 8259 request is withdrawn or held after the device is acked (keyboard, IDE, OPNA, calendar, PIT) | `IRQWD.TXT` |
| `opnapro` | PC-9801-86 OPNA register read-back | `OPNA.TXT` |
| `sndtest` | the OPNA audio-calibration stimulus: fixed segments of known register state (FM/SSG level and frequency sweeps, rhythm) paced by the ARTIC counter; record the line-out while it runs. `tools/sndtest_check.py` checks a transcript, `tools/sndtest_balance.py` measures recordings | `SNDTEST-*.txt` |
| `pegcwatch` | `PEGCW <program>`: runs a child and reports the PEGC (256-colour) state it leaves behind | `PEGC.TXT` |
| `memmap` | what the memory-size chain tells a DOS extender (BDA, XMS/EMS/VCPI/DPMI answers, the 15-16 MiB system space) | - |
| `a20map` | how the A20 mask treats physical addresses above 1 MiB | `A20MAP-XE10.TXT` |
| `d8bank` | what the `0xD8000` window holds for each `0x063C` bank select | `D8BANK-XE10.TXT` |
| `integ` | storage-path integrity: hashes files on the hard disk, floppy and CD and compares them with a manifest built from the image (`integ_manifest.py`). Used by `tools/mister_regress.py`'s `probe` mode | - |

## Running a probe

1. **Run a new or changed probe on the core first.** It must finish and restore what it
   touches; only then is it fit for the real machine.
2. Boot the machine fresh to a plain DOS prompt (no EMM386 unless the probe says otherwise),
   copy the `.COM` and its `RUN*.BAT` to the disk, and run the batch; it redirects stdout to a
   `.TXT`. DOS filenames are 8.3 and `.BAT` files must be CRLF (`unix2dos`).
3. Copy the capture off before the next step, and run the SAME binary on the core so the two
   captures are comparable. A probe that wraps another program (`pegcwatch`) must be run from
   that program's own directory.
4. Commit raw captures under `docs/probes/` unmodified (CRLF and all) and decode them with the
   tool's `_decode.py`.

Writing sections are opt-in, run under `cli`, save every as-found byte and print the
restore proof. A section that hangs is identified by a `BEGIN:` line with no matching `END:`.

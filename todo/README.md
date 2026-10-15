# TODO - index

## How to read the status tags

Every item carries one of these. The tag says how well the underlying claim is
established, not how important it is.

| Tag | Meaning |
|---|---|
| **VERIFIED (HW)** | A real Xe10 capture in `docs/probes/` measures this directly. Safe to implement; still needs a fail-first bench whose expected value comes from the capture (never from our RTL). |
| **NEEDS RE-VERIFICATION** | A number or claim that exists but must be re-checked before it is relied on. |
| **CAPTURE-PENDING** | No valid measurement exists. A named probe or experiment must be run on the machine first. |
| **UNVERIFIED (INFERRED)** | Implemented from NP2kai/firmware/RTL reading only, with no hardware measurement. |
| **DECISION (OWNER)** | Blocked on a maintainer decision, not on work. |
| **KNOWN GAP** | A documented limitation; not a defect until scope changes. |

Evidence hierarchy for every item: real hardware captures > the real machine > NP2kai
(primary software reference) > qemu-pc98 > MAME/ymfm > ReC98. Our own RTL and benches are
never evidence of what the hardware does.

Implementation rules: any RTL change ships with a fail-first bench and passes
`tools/bench.py --all`, `tools/check_lint.py`, `tools/gen_bench_sources.py --check`,
`tests/pc9821/run_z486_suite.sh` and the boot golden (`CYCLES used=930544`; a change that
moves it is reported with per-change attribution rather than re-pinned silently), plus a
Quartus compile. `sys/` is frozen; `src/opna/` changes go only in marked `LOCAL CHANGE`
blocks listed in `src/opna/LICENSE-SCOPE.md`; `src/z486/` changes are made in the z486
fork first and re-vendored (`docs/z486-local-patch.md`). Never delete a seed sweep's
`output_files/`.

---

<!-- TODO-SPLIT:INDEX:BEGIN -->

This directory is the live open-work list, one file per theme. The repo-root
[`TODO.md`](../TODO.md) is the short index. The status-tag legend is above.

## Sections

| # | Section | File |
|---|---|---|
| 1 | RTL changes ready to implement from machine captures | `todo/1-rtl-from-captures.md` |
| 2 | Probe corrections and re-runs | `todo/2-probe-corrections.md` |
| 3 | Capture-pending hardware questions | `todo/3-capture-pending.md` |
| 4 | Re-verification items | `todo/4-reverification.md` |
| 5 | Owner decisions | `todo/5-owner-decisions.md` |
| 6 | Audio: OPNA/SSG/ADPCM, rhythm, MIDI | `todo/6-audio.md` |
| 6 | Video: display, GDC/CRTC raster, drawing | `todo/6-video.md` |
| 6 | Storage: IDE/ATA, FDC, CD-ROM | `todo/6-storage.md` |
| 6 | Platform: CPU, I/O bus, clocks, fitter | `todo/6-platform.md` |
| 6 | Tools and gates | `todo/6-tools-and-gates.md` |
| 7 | Standing engineering rules this list must respect | `todo/7-standing-rules.md` |

## Items

Every item keeps its number forever. The numbers are stable public IDs: RTL comments,
docs, tools and tests cite them as `item NN`. Never renumber. When an item is closed it is
DELETED and its number is RETIRED (listed below) and never reused; any `item NN` reference
to it must be reworded first (`tools/check_todo_split.py` fails on a reference to a retired
number).

Retired numbers: 1, 2, 4, 5, 6, 7, 8, 9, 12, 14, 39, 46, 48, 49, 50, 51, 52, 54, 55, 58, 60, 65, 69, 70, 71, 73, 74, 75, 76, 77, 80, 81, 83, 84, 86, 88, 89, 90, 91, 92, 93, 95, 96, 100, 103, 104, 105, 107, 108, 109, 111, 116, 117, 119, 120, 122, 123, 124, 125

| # | Title | File |
|---|---|---|
| 3 | `0x9A8` is a real latch, not a constant. | `todo/1-rtl-from-captures.md` |
| 10 | The PIT channel-0 divisor read, and one-byte write retention. | `todo/2-probe-corrections.md` |
| 11 | VSYNC delivery while in service: held and delivered at the EOI. | `todo/2-probe-corrections.md` |
| 13 | GDC light-pen (LPEN) read-back needs a repeat before it is trusted. | `todo/2-probe-corrections.md` |
| 15 | Analog palette register width and mirror. | `todo/3-capture-pending.md` |
| 16 | `0xA8` width test in analog mode. | `todo/3-capture-pending.md` |
| 17 | GDC `mode1` (`0x68`) read model. | `todo/3-capture-pending.md` |
| 18 | OPNA `0x18E` read with extended select `0x0F`. | `todo/3-capture-pending.md` |
| 19 | OPNA status-2 (`0x18C`) timer bits: masked by the `0x110` flag register or not? | `todo/3-capture-pending.md` |
| 20 | `0x18A` read after `0x188 = 0x0F` / `0x08`. | `todo/3-capture-pending.md` |
| 21 | `0x0433`: IDE connect flag or IRQ-pending? | `todo/3-capture-pending.md` |
| 22 | CRTC horizontal porch split. | `todo/3-capture-pending.md` |
| 23 | GDC status bit 6 (blank) duty. | `todo/3-capture-pending.md` |
| 24 | Game-port opposite-direction priority and discharge table. | `todo/3-capture-pending.md` |
| 25 | EGC 3-byte unaligned store order. | `todo/3-capture-pending.md` |
| 26 | GDC SCROLL partition walk past partition 2. | `todo/3-capture-pending.md` |
| 27 | `0x0432` bit-7 encoding. | `todo/3-capture-pending.md` |
| 28 | `0x043F` read-back encoding. | `todo/3-capture-pending.md` |
| 29 | `0x074E` with another unit or head selected. | `todo/3-capture-pending.md` |
| 30 | `0x060` (text GDC status) bit 6. | `todo/3-capture-pending.md` |
| 31 | `0xE0000` answering nothing. | `todo/3-capture-pending.md` |
| 32 | Calendar (uPD4990A) bit order. | `todo/3-capture-pending.md` |
| 33 | Drive IDENTIFY words. | `todo/3-capture-pending.md` |
| 34 | `0xDA000`/`0x1E8E` IDE work-RAM gate. | `todo/3-capture-pending.md` |
| 35 | `0x989x` write behaviour. | `todo/3-capture-pending.md` |
| 36 | `0x6C` and the `0x60-0x6F` decode. | `todo/3-capture-pending.md` |
| 37 | CG window even offsets. | `todo/3-capture-pending.md` |
| 38 | OPNA ADPCM-B over the data bus. | `todo/3-capture-pending.md` |
| 40 | PCM86 and the 8237 DMA. | `todo/3-capture-pending.md` |
| 41 | I/O timing ladder: the `0x5F` anchor. | `todo/4-reverification.md` |
| 42 | `0x7C` 16-bit word `IN`. | `todo/4-reverification.md` |
| 43 | DMA bank ports `0x21/0x23/0x25/0x27`: low-nibble width. | `todo/4-reverification.md` |
| 44 | GDC LPEN constants. | `todo/4-reverification.md` |
| 45 | SSG / PC-speaker DC convention. | `todo/4-reverification.md` |
| 47 | ADPCM-A rhythm needs a driver on the machine, not on the core. | `todo/4-reverification.md` |
| 53 | z486 reset-state divergences. | `todo/5-owner-decisions.md` |
| 56 | HELP key held through boot. | `todo/5-owner-decisions.md` |
| 57 | MIDI out (MPU-PC98II) is opt-in: the `midilink` build profile only. | `todo/6-audio.md` |
| 59 | Floppy: D88 FORMAT and 2HS/rpm media gating are not implemented. | `todo/6-storage.md` |
| 61 | WSS/MSS (PCM 16-bit) audio is not implemented. | `todo/6-audio.md` |
| 62 | PEGC 256-colour: the display works, the plane engine does not. | `todo/6-video.md` |
| 63 | Most GDC2 (graphics GDC) drawing commands are accepted but not executed. | `todo/6-video.md` |
| 64 | The serial port (8251 at `0x30`/`0x32`) is not modelled. | `todo/6-platform.md` |
| 66 | In-game disk-load latency (Touhou 5 dialogue loads). | `todo/6-storage.md` |
| 67 | Faster `idiv`. | `todo/6-platform.md` |
| 68 | The `pixel_ce` video chain is multi-cycle but not constrained as such. | `todo/6-video.md` |
| 72 | `audio_clip` bench: re-source the "model twin" rows. | `todo/6-tools-and-gates.md` |
| 78 | OPNA register leftovers. | `todo/6-audio.md` |
| 79 | Upstream `pll_hdmi` negative slack. | `todo/6-platform.md` |
| 82 | I/O access cost per port class: machine bus time or the shortest stall. | `todo/6-platform.md` |
| 85 | GDC SYNC raster residuals. | `todo/6-video.md` |
| 87 | OPNA junction boundary: the die's 18-bit wrap vs the core's sum + clamp16. | `todo/6-audio.md` |
| 94 | Software-DIP store: the machine's own post-POST state. | `todo/3-capture-pending.md` |
| 97 | The `0x0461` window's page 0/1: alias or hole. | `todo/3-capture-pending.md` |
| 98 | `0x043B` bit 2: the 15-16 MiB system space's polarity. | `todo/3-capture-pending.md` |
| 99 | Machine settings the OSD cannot yet offer. | `todo/3-capture-pending.md` |
| 101 | `src/opna` has no vendor-diff gate, unlike `src/z486`. | `todo/6-tools-and-gates.md` |
| 102 | The block adapter's `win_flush` window re-mount has no fail-first test. | `todo/6-storage.md` |
| 106 | CD-ROM: what works and what is unverified. | `todo/6-storage.md` |
| 110 | The DIP store's write-side parity bits. | `todo/3-capture-pending.md` |
| 112 | Memory-switch cell `0x79` at a second RAM size. | `todo/3-capture-pending.md` |
| 113 | GRCG presentation bubble: a timing fix that costs one clk_sys per GRCG store. | `todo/6-video.md` |
| 114 | Masked-request withdraw on the acking access: IRQ15 still unmeasured. | `todo/3-capture-pending.md` |
| 115 | z486 micro-code: the loop-top RNI never fires, so a string REP does not retire per iteration. | `todo/6-platform.md` |
| 118 | `0xF6` read-back with A20 masked: the Xe10 reads `5E`, the core `5F`. | `todo/1-rtl-from-captures.md` |
| 121 | IDE bank placement under Linux's `pc98ide` driver. | `todo/3-capture-pending.md` |

## Adding to the list

1. Take the next free number: one more than the highest number in the item table or the
   retired list.
2. Put the item body in the theme file it belongs to, as `NN. **Title.** **STATUS TAG.** ...`.
3. Add a row to the item table above, and to the section map if you made a new file.
4. Run `python3 tools/check_todo_split.py`.

<!-- TODO-SPLIT:INDEX:END -->

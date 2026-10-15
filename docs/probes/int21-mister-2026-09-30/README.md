# INT21 telemetry captures (Touhou 5 OOM)

Raw debug-UART captures from this core on a MiSTer, `trace` profile, plain conventional
DOS profile (neither HIMEM nor EMM386 loaded), taken 2026-09-30 with
`tools/run_on_mister.sh capture`. Retained byte-for-byte.

| file | what it is |
|---|---|
| `CAL21.TXT` | the in-process DOS allocator calibration the probe prints (its own CF/AX/BX rows) |
| `int21-calibration.log` | UART capture of that calibration run |
| `th05-trace.log` | UART capture of the TH05 run (`OP.EXE` startup) |
| `th05-trace-2.log` | the frozen instruction ring at the failure (the capture the root cause was read from) |

`*-decoded.txt` beside them are **derived, not tracked**: a pure function of the
raw logs. Regenerate with

```
tools/decode_telemetry.py --clk-mhz=50 int21-calibration.log > int21-calibration-decoded.txt
tools/decode_telemetry.py --clk-mhz=50 th05-trace.log > th05-trace-decoded.txt
tools/decode_telemetry.py --clk-mhz=50 th05-trace-2.log > th05-trace-2-decoded.txt
```

The `--clk-mhz=50` is required for a byte-for-byte match: the decoder assumes
83.333 MHz (the production profile) by default, and cyc->seconds/rates differ
otherwise. Verified byte-identical on 2026-09-30, so the retained copies are
reproducible and no derived text is committed here.

At the failure the screen is solid black except
`Not enough free memory. Free up some memory & restart.`

## What these captures establish

The tracer is calibrated, so its IN/OUT results are real DOS returns rather than
entry echoes: the decoded calibration log reproduces `CAL21.TXT`'s rows from `int21-calibration.log` at the same caller `CS`.
On the game path the first 336 KB allocation succeeds, the second Borland C0
startup shrink returns `AX=0007` (DOS "memory control blocks destroyed") and the
second allocation then reports a largest free block that is exactly the tail left
after the first buffer - so the visible OOM is downstream of a corrupted arena.

Caveat: this is trace analysis, not proof of CPU
retirement or branch behaviour; the wire format carries no ES/PSP/MCB or
message-print event.

## Resolution (2026-09-30)

The arena damage was **downstream of a CPU front-end bug**: a near RET predicted from
the return-address stack into the SAME 16-byte line as its real target was adopted
at the PREDICTED byte, so `OP.EXE` re-executed bytes and skipped its XOR layer.
Fixed in the z486 fork and re-vendored; **Touhou 5 now works on the MiSTer.**

# Core-side probe captures

These are the CORE's half of a same-binary comparison: the same DOS probe programs whose real-Xe10
captures sit one directory up, run on this core on the owner's MiSTer. They are evidence of what
the core did, never of what the hardware does.

| file | probe | build | its machine counterpart |
|---|---|---|---|
| `EGCP-core.TXT` | `tools/hwprobe/egcplane` | pc9821 `e5d6cdf3` (RBF `8d990ed6...`), 80 MHz, the plane-PARALLEL EGC | `docs/probes/EGCP.TXT` |
| `GFX2-core.TXT` | `tools/hwprobe/gfxbenc2` | the same build | `docs/probes/GFX2.TXT` |

Both were captured on the MiSTer with that build and copied here unmodified. Decode them with the
probe's own decoder (`tools/hwprobe/egcplane/egcplane_decode.py`,
`tools/hwprobe/gfxbenc2/gfxbenc2_decode.py`). `tb_pc9821_egc_xe10_pace` takes its CPU loop-shell
time and its load-path calibration from `EGCP-core.TXT`.

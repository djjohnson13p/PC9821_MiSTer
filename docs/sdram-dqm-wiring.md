# MiSTer SDRAM DQM wiring — settled

Status: **settled from primary sources** (no hardware discriminator required). This
note records the evidence and the design contract the controller must honour so the
PEGC packed-store path can use masked byte writes instead of read-modify-write.
Work item: trade-candidate T23's DQM half.

## 1. The module

The MiSTer 128 MB SDRAM add-on (the "XSDS" board, and the family of compatible
boards) is **2 x AS4C32M16SB**, i.e. two x16 SDRAM chips of 64 MB each:

| property | value |
|---|---|
| capacity | 128 MB (2 x 64 MB) |
| chips | 2 x AS4C32M16SB-6TIN |
| per chip | 4 banks x 8192 rows x 1024 columns x 16 bits |
| connector | 40-pin header (P1) |
| bus width | 16 bits (DQ[15:0]) |
| CKE | tied to VCC on the board (power-down/self-refresh impossible) |
| CS | one connector line `CS1`; `CS2 = ~CS1` via an on-board inverter |

Sources:
- Official schematic: `MiSTer-devel/Hardware_MiSTer`, `releases/sdram_xsds_3.0.pdf`
  (also `Addons/SDRAM_xsds/sdram_xsds.SchDoc`). The net labels show both chips'
  `DQML` and `DQMH` connected to `A11` and `A12` at the connector.
- `birdybro/SDRAMsim_MiSTer`, `CONTROLLER_GUIDE.md` ("At a glance", "The 40-pin
  connector", "Three XSDS-specific quirks"), derived from that schematic and the
  AS4C32M16SB datasheet.
- Reference simulation model: `birdybro/SDRAMsim_MiSTer`,
  `xsds_128mbyte_sdram_model.sv:72-74`
  (`wire chip_ldqm = Addr[11]; wire chip_udqm = Addr[12];`).

## 2. DQM is carried on A[11]/A[12]

The chips' `DQML`/`DQMH` pins are wired to the connector's `A11`/`A12`, so there is
**no separate DQM pin**. A controller drives a byte mask by putting it on
`A[12:11]` during the read/write command, and the MiSTer-standard form is:

```systemverilog
assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];
```

`CONTROLLER_GUIDE.md` states this pattern "appears in ~80 of the ~91 reference
controllers" it surveyed. It is the same mechanism JTFRAME calls **ADQM**:
- `modules/jtframe/hdl/sdram/jtframe_sdram_bank_core.v:23-24` —
  "JTFRAME_SDRAM_ADQM enables A12=DQMH, A11=DQML mode. This slows down the memory
  but is required for some MiSTer memory modules."
- `:89-95` — `ifdef MISTER` selects `ADQM = 1`.
- `:126` — `assign {sdram_dqmh, sdram_dqml} = ADQM ? sdram_a[12:11] : dqm;`
- `:281-284` — the column command: `sdram_a[12:11] <= wrtng ? wrmask : 2'b00;`
  ("A12 and A11 used as mask in MiSTer 128MB module").

## 3. The per-command A[12:11] contract

From `CONTROLLER_GUIDE.md` section "DQM is driven via A[11] and A[12]":

| command | A[12:11] carries | notes |
|---|---|---|
| ACT | row bits A12/A11 | DQM is don't-care (no data transfer) |
| READ | `00` | DQM has a **2-clock output-mask latency**; this core never masks reads |
| WRITE | byte mask `{UDQM, LDQM}` | active high (1 = mask); captured with the write data |
| PRE | reserved / don't-care | A10 = all-banks |
| MRS | `00` | per the datasheet |

Address mapping for a 27-bit byte address (128 MB):
`[0]` byte-in-word (selects the DQM half), `[10:1]` column A[9:0],
`[12:11]` bank BA[1:0], `[25:13]` row A[12:0], `[26]` `CS1` (high chip select).

## 4. What our controller already does, and the delta

`src/memory/sdram.v:225` already drives the standard tie:

```systemverilog
assign SDRAM_DQM = HAS_DQM ? dqm_mask : a[12:11];
```

so with `HAS_DQM=0` the DQM pins mirror `a[12:11]`. The gat is that the controller
puts `00` on `a[12:11]` during its WRITE column command and therefore cannot mask,
so a partial write takes `RMW_READ -> RMW_ACT -> WRITE` (a read and a re-activated
merge write). `dqm_mask` is computed but, with `HAS_DQM=0`, never driven.

The delta is the MiSTer-standard one: **put the byte mask on `a[12:11]` in the
write column command** and issue a single masked WRITE. The read and gather
paths already drive `a[12:11]=00` (READ, `GATH_WR`) or row bits (ACT), which the
contract above requires.

## 5. Scope

Target: 128 MB modules that use the standard `A[11]/A[12]` DQM tie (the XSDS and
compatible boards). The core supports 128 MB modules only. The
standard pattern is the de-facto MiSTer norm, so a single scheme covers the
supported population; a hypothetical module that ties the chip DQM inactive and
routes address only through those pins is **not** compatible with masking and is
out of scope (it would still need the RMW path, which is retained as a
compile-time fallback).

## 6. Verification contract

- `tests/pc9821/sdram_chip_model.sv` must tie `Ldqm=A[11]`, `Udqm=A[12]` and apply
  the mask (it currently ignores DQM), or every masked-write bench is vacuous.
- A masked WRITE must be byte-exact and preserve masked-off neighbours for every
  byte-enable pattern; a masked write and the old RMW must produce identical memory.
- MRS must carry `A[12:11]=00`; READ/MRS must carry `00`; ACT must carry row bits.
- A planted defect (inverted mask, wrong lane, mask not placed on `a[12:11]`) must
  fail the bench.

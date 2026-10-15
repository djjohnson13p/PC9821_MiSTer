// PC-9821 native z486 memory subsystem: firmware loader + map + arbitration.

`default_nettype none

module pc9821_memory_subsystem #(
    parameter [15:0] IOCTL_INDEX = 16'd0,
    parameter [26:0] PACK_BYTES = 27'h010_0000,
    // The build's clk_sys frequency: the GVRAM's per-operation costs are captured TIMES
    // (pc9821_gvram_arb's GVRAM_PERIODS), so they are converted from this and from nothing else.
    parameter integer SYS_CLOCK_HZ = 50_000_000,
    // The gather session's entry count (pc9821_pegc_storebuf's GATHER_K; the
    // controller's own must agree - z486_mister.sv passes both from one value).
    parameter integer GATHER_K = 4
) (
    input wire clk,
    input wire reset,
    input wire [3:0] top_bank,
    // 0x043F's 0x2 nibble: which of the machine's three measured states the 64 KiB EMS
    // window at 0xB0000-0xBFFFF is in. 0 = identity/VRAM, 1 = the RAM page, 2 = unmapped.
    // See pc9821_iobus's ems_state and pc9821_memory_map.
    input wire [1:0] ems_state,
    input wire ide_rom_enable,
    // 0x063C bits 1-0: the 0xD8000 window's ROM bank (pc9821_iobus d8_bank).
    input wire [1:0] d8_bank,
    // The IDE work RAM's 0x1E8E visibility gate (pc9821_iobus): decoded by the
    // mapper, which routes the gated-off state to the absent-area responder.
    input wire ide_ram_gate,
    input wire bios_ram_gate,
    // 0x043F's 0x8 nibble (pc9821_iobus top_shadow_en): the writable layer over the
    // 0xF8000-0xFFFFF window is enabled. See fw_shadow_dirty below.
    input wire top_shadow_en,
    // 0x0461 window-0 base (see pc9821_memory_map.sv).
    input wire [7:0] win0_sel,
    // pc9821_iobus's registered `win0_sel != 8'h08` (see pc9821_memory_map.sv).
    input wire       win0_sel_moved,
    // 0x043B bit 2: the 15-16 MiB system-space window (hole + mirror). Reset leaves it OFF,
    // so 15-16 MiB is RAM until the guest clears the bit (see pc9821_iobus).
    input wire sys16m_en,

    // THE PEGC MMIO VIEW (the 0x6A dat 0x21 select, pc9821_crtc's mode2_256col):
    // while it is up the 0xE0000 window is the PEGC register file and the two
    // packed windows replace the planar ones (see pc9821_memory_map). The register
    // file itself (pc9821_pegc) lives below and owns the bank/mode/vram-enable
    // state; this input is the view select only. pegc_256e is the FF2 dat-0x68
    // VRAM-boundary f/f: it zeroes the packed display page's 0xA4 TERM (MAME
    // pc9821.cpp:98; the SCROLL walk's own page bit, scan_walk_page, still
    // applies), and scan_dot is the dot within the column, for the packed
    // buffer's byte select (row 3). scan_dot_ce is that dot's ENABLE - high during the
    // clk_sys cycle the dot counter advances at the end of (pc9821_system's pixel_ce) -
    // which the packed fetch needs to present its dword address one clk early at a
    // 4-dot group boundary (pc9821_pegc_scan's byte-select header).
    input wire pegc_256,
    input wire pegc_256e,
    input wire [2:0] scan_dot,
    input wire scan_dot_ce,
    input wire scan_dot_act,

    // Runtime memory sizing (OSD RAM size): guest RAM ends at
    // guest_ram_bytes and the 1 MiB firmware reserve starts at pack_base
    // (== guest_ram_bytes in the system wiring).
    input wire [31:0] pack_base,
    input wire [31:0] guest_ram_bytes,

    // GDC graphics page currently mapped into the CPU's VRAM window (port 0xA6).
    input wire gvram_access_page,

    // GRCG register write port. pc9821_system decodes ports 0x7C/0x7E from the
    // device bus and passes the strobe here, because the engine that sees them
    // now lives inside pc9821_gvram: the GRCG is a CLIENT of the one GVRAM
    // datapath, not a second route to the planes.
    input wire       grcg_we,
    input wire [7:0] grcg_addr,
    input wire [7:0] grcg_din,
    // The GRCG's CG-mode bit 7, exported from pc9821_gvram so the core can AND it into
    // the EGC's memory-dispatch gate (NP2kai VOPBIT_EGC && VOPBIT_GRCG).
    output wire      grcg_expand,
    // The GRCG's live mode register. The 0x7C guest read does NOT answer it -
    // that port is write-only and reads open bus 0xFF (docs/probes/RDBACK.TXT:152),
    // NP2kai's io/crtc.c crtc_i7c being the weaker source - so this wire reaches
    // only pc9821_crtc's unconsumed grcg_mode_r input.
    output wire [7:0] grcg_mode_r,

    // EGC. `egc_enable` is the chip's real gate (0x6A num 2, the wire
    // pc9821_gdc_text exports). With it on, a CPU access to a graphics-plane
    // window is transformed by the EGC instead of being a plain plane access --
    // and it is now safe to turn on, because the EGC issues column accesses on
    // pc9821_gvram's own port rather than a backend route the GRCG could
    // re-expand as tile writes (the tile-write hazard).
    input wire        egc_enable,
    input wire [15:0] egc_access,
    input wire [15:0] egc_fgbg,
    input wire [15:0] egc_ope,
    input wire [15:0] egc_fg,
    input wire [15:0] egc_mask,
    input wire [15:0] egc_bg,
    input wire [15:0] egc_sft,
    input wire [15:0] egc_leng,
    input wire        egc_shift_we,

    // The graphics GDC's draw-engine visit (pc9821_gdc2's WRITE path, the GDC2 WRITE slice):
    // one store/read at a time on the GVRAM's CPU-side port share (pc9821_gvram_share),
    // carried as the same plane-window operands a CPU access of that shape would present
    // so the GRCG/EGC store paths and the plain lane walk serve it unchanged.
    input  wire        gdc_mem_valid,
    output wire        gdc_mem_ready,
    input  wire        gdc_mem_write,
    input  wire        gdc_mem_route_egc,
    input  wire        gdc_mem_route_grcg,
    input  wire        gdc_mem_page,
    input  wire [1:0]  gdc_mem_plane,
    input  wire [14:0] gdc_mem_offset,
    input  wire [31:0] gdc_mem_din,
    input  wire [3:0]  gdc_mem_be,
    output wire        gdc_mem_resp,
    output wire [31:0] gdc_mem_rdata,

    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [15:0] ioctl_dout,
    output wire        ioctl_wait,
    output wire        rom_ready,
    output wire        load_error,
    output wire        cpu_run,

    // The scanout's read side. The GVRAM block owns the line fetch
    // the ping-pong line buffer and its pacing; these ports are the raster's
    // view of it: hand it the line tick and the line's origin and read the
    // assembled columns out of the buffer the display pipeline is pointing at.
    input  wire        scan_enable,
    input  wire        scan_line_tick,
    input  wire        scan_page,
    input  wire [14:0] scan_line_base,
    // The PACKED walk's own page bit (pc9821_gdc2's gfx_walk_page: SCROLL start
    // word bit 14). Consumed only by the packed fetch (pc9821_pegc_scan's page
    // composition); the planar fetch takes scan_page alone.
    input  wire        scan_walk_page,
    // The 200-line interleave's odd display line: no graphics fetch for it (pc9821_gvram_scan).
    input  wire        gfx_odd_line,
    input  wire [6:0]  line_rd_addr,
    input  wire        line_rd_sel,
    output wire [31:0] line_data,
    output wire        line_sel,
    output wire        line_ready,
    // The packed scanout's view (row 3): its byte for the current dot and its
    // own line-ready/line-select (pc9821_system picks the pair by pegc_256).
    output wire [7:0]  peg_packed_idx,
    output wire        peg_line_sel,
    output wire        peg_line_ready,

    // 4 KiB ANK 8x16 font window from pack offsets 0x30000-0x30FFF.
    // This is deliberately separate from the top BIOS at 0x20000-0x27FFF.
    output wire [17:0] font_addr,
    output wire [15:0] font_data,
    output wire        font_we,

    // z486 native memory requester. THE FILL FORM IS WORD BEATS, EVERYWHERE: a
    // cache-line read (cpu_line_read with burstcount 4) is answered as FOUR word
    // beats on cpu_dout/cpu_resp_valid (see the line-to-beat converter below); the
    // 128-bit line form no longer leaves this module at all.
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_din,
    output wire [31:0] cpu_dout,
    input  wire [3:0]  cpu_be,
    input  wire [7:0]  cpu_burstcount,
    input  wire        cpu_line_read,
    input  wire        cpu_valid,
    input  wire        cpu_write,
    output wire        cpu_ready,
    output wire        cpu_resp_valid,

    // Byte-wide text RAM port owned by the GDC dual-port RAM.
    output wire [13:0] tram_addr,
    output wire  [7:0] tram_din,
    output wire        tram_we,
    input  wire  [7:0] tram_dout,

    // Memory-mapped CG window (0xA4000-0xA4FFF). The window is a 32-byte
    // repeating view of the glyph selected by the GDC's CG registers; the
    // window owns the byte position and the GDC's class table owns the byte, so
    // the two views cannot disagree about a glyph.
    output wire  [4:0] cg_win_byte_sel,
    output wire        cg_win_rd,
    input  wire  [7:0] cg_win_dout,
    output wire  [7:0] cg_win_din,
    output wire        cg_win_we,
    // The GDC sets this while the selected code's SDRAM glyph burst is in flight, so the
    // window responder waits. An undriven input is 0 (no hold).
    input  wire        cg_win_byte_hold,

    // The character generator's glyph fetch: a straight read of the pack's
    // FONT.ROM copy at pack_base + FONT_PACK_OFFSET, one 8-dword burst (the whole
    // 32-byte glyph block) per request.
    // It runs on the SDRAM's SECOND port (fmem_*) because the backend's
    // responses carry no tag -- a second requester on port 0 could be handed the
    // CPU's data -- and because that port is otherwise unused, so a glyph fetch
    // never stalls a CPU access.
    input  wire  [18:0] font_req_addr,   // byte address inside the font region
    input  wire         font_req,
    output wire         font_word_valid,
    output wire  [31:0] font_word_data,

    output wire [31:0] fmem_addr,
    output wire [31:0] fmem_din,
    output wire        fmem_valid,
    output wire        fmem_write,
    output wire  [3:0] fmem_be,
    output wire  [7:0] fmem_burstcount,
    input  wire        fmem_ready,
    input  wire [31:0] fmem_dout,
    input  wire        fmem_resp_valid,

    // The packed scanout's line fetch, on the SDRAM's FOURTH port (row 6): the
    // controller serves four requesters round-robin and the fourth was tied idle
    // until this lane. Read-only bursts (160 dwords per line).
    output wire [31:0] pmem_addr,
    output wire [31:0] pmem_din,
    output wire        pmem_valid,
    output wire        pmem_write,
    output wire  [3:0] pmem_be,
    output wire  [7:0] pmem_burstcount,
    input  wire        pmem_ready,
    input  wire [31:0] pmem_dout,
    input  wire        pmem_resp_valid,

    // THE uPD71071's BUS-MASTER PORT (pc9821_iobus's u_dma): the third owner of the
    // physical backend. It STORES for a port-to-memory transfer (a floppy READ) and, since
    // the floppy write path (Stage B), READS for a memory-to-port one (WRITE DATA:
    // the engine reads a byte, then strobes it to the FDC). A read owes one response beat,
    // so its accept is recorded in the response-route queue with a DMA tag and its beat is
    // delivered here (dma_resp_valid/dma_dout) instead of to the mapper.
    input  wire [31:0] dma_addr,
    input  wire [31:0] dma_din,
    input  wire [3:0]  dma_be,
    input  wire        dma_valid,
    input  wire        dma_write,
    output wire        dma_ready,
    output wire [31:0] dma_dout,
    output wire        dma_resp_valid,

    // The SDRAM module geometry (the controller's own sdram_size,1/2/3 =
    // 32/64/128 MB): the store buffer groups its gather sessions by the physical
    // row, which that geometry decides (pc9821_pegc_storebuf's rowkey).
    input  wire  [1:0] sdram_size,

    // Physical SDRAM/backend request
    output wire [31:0] mem_addr,
    output wire [31:0] mem_din,
    // Port 0's two-word write payload, word 1 (pc9821_pegc_storebuf's pair drain;
    // split_sdram_backend carries it to the controller's din0_hi).
    output wire [31:0] mem_din_hi,
    // The G3 gather-RMW session request (pc9821_pegc_storebuf's group drain;
    // split_sdram_backend carries it to the controller's gath0/gath0_extra):
    // mem_gath qualifies a write of mem_burstcount (1..GATHER_K) same-row partial
    // stores, entry 0 on mem_addr/mem_din/mem_be and entries 1.. on mem_gath_extra
    // ({addr[26:0], din[31:0], be[3:0]} per entry).
    output wire        mem_gath,
    output wire [440:0] mem_gath_extra,
    input  wire [31:0] mem_dout,
    output wire [3:0]  mem_be,
    output wire [7:0]  mem_burstcount,
    output wire        mem_valid,
    output wire        mem_write,
    input  wire        mem_ready,
    input  wire        mem_resp_valid,

    // Graphics telemetry: the GVRAM's four counter bus, packed {GR, GT, EG, PW}. They
    // are outputs, so a caller that does not want them leaves them open; pc9821_system wires them
    // into the watchdog's graphics record.
    output wire [127:0] dbg_gfx_stats,

    // The GVRAM's walk telemetry: one pulse per one-visit array walk and one per clk_sys
    // of it. pc9821_system counts them into the perf record's GW/GC fields.
    output wire         dbg_walk_start,
    output wire         dbg_walk_cycle,

    // The EGC/GRCG operation telemetry: the EGC's command-accept and per-unit-commit
    // pulses and the GRCG's per-store pulse, passed out of pc9821_gvram. pc9821_system counts them
    // into the perf record's ET/EU/GS fields.
    output wire         dbg_egc_txn,
    output wire         dbg_egc_unit,
    output wire         dbg_grcg_store,

    // The GVRAM's visible-region telemetry: one pulse per clk_sys the GRCG and the EGC
    // each own the array, passed RAW out of pc9821_gvram. pc9821_system ANDs them with the video
    // domain's v_active and counts the result into the perf record's GV/EV fields.
    output wire         dbg_gr_owned,
    output wire         dbg_eg_owned,

    // ...and the PLAIN plane-window client's ownership, the third write arm. Farland Story's
    // store path is this one (its GS/GR/GT stay flat while GW/GC/PW move), so a page-coincidence
    // probe built on the GRCG alone cannot see the leak the probe exists to find.
    output wire         dbg_pw_owned,

    // The page-coincidence probe: the CPU's GVRAM access page and the page the scanout
    // is latched on, passed RAW as LEVELS out of pc9821_gvram. pc9821_system feeds them to
    // pc9821_perf_msg, which counts the cycles a GRCG store is in flight while the two are EQUAL
    // (the record's PC) and reports both as status fields (SP/AP).
    output wire         dbg_access_page,
    output wire         dbg_scan_page_q
);

  wire selected_download = ioctl_download && (ioctl_index == IOCTL_INDEX);

  wire load_valid, load_ready;
  wire [31:0] load_addr, load_din;
  wire [3:0] load_be;
  wire [7:0] load_burstcount;
  wire load_write;
  wire saw_download;

  wire [31:0] map_addr, map_din, map_cpu_dout;
  wire [127:0] map_cpu_line_dout;
  wire [3:0] map_be;
  wire [7:0] map_burstcount;
  wire map_valid, map_write, map_ready;
  wire map_cpu_ready, map_cpu_resp_valid, map_cpu_line_resp_valid;

  // THE 15-16 MiB SYSTEM-SPACE WINDOW (port 0x043B bit 2; the guest enables it, reset leaves it
  // off). With it set the machine puts no SYSTEM RAM at 0xF00000-0xFFFFFF, but it is not all
  // hole: 0xFA0000-0xFFFFFF aliases the low 0xA0000-0xFFFFF (NP2kai reduces the address by
  // 0xF00000 and dispatches it through its LOW-memory table, i386c/cpumem.c memsys_rd8/wr8;
  // qemu-pc98 builds the same alias at 0xfa0000 over lowmem[0xa0000..0x100000], hw/i386/pc98-mem.c
  // sys16m_mirror + mem_apply_sys16m), 0xF00000-0xF7FFFF is the PEGC's 512 KiB extended VRAM
  // and only 0xF80000-0xF9FFFF answers nothing. THE TRANSLATION MUST PRECEDE THE ROUTE
  // SELECTS below, or an aliased read would be served from guest RAM instead of the text VRAM,
  // CG window or plane it aliases.
  // EVERY WINDOW BOUND BELOW IS A BIT SLICE, NOT THE 32-BIT RANGE COMPARE IT READS AS: a window
  // inside a 1 MiB space is "the block-selector bits equal the block and the next bit(s) say which
  // part of it", and the magnitude compares left carry chains in series with the address muxes.
  // Each identity is bit-equal for EVERY 32-bit input (checked exhaustively below 2^20 and over
  // every high prefix), so the alias bench's boundary cases are unchanged.
  wire sys16m_mirror = sys16m_en &&
                       !(|cpu_addr[31:24]) && (cpu_addr[23:16] >= 8'hFA);
  wire sys16m_hole   = sys16m_en &&
                       !(|cpu_addr[31:24]) && ((cpu_addr[23:16] & 8'hFE) == 8'hF8);
  // The PEGC extended-VRAM window. qemu-pc98's pegc_post (PEGC_POST_SIZE = 0x80000) and NP2kai's
  // memvgaf (vramex[0x80000]) are the same 512 KiB, decoded at 0xF00000 and enabled by the same
  // 0x043B bit that turns the system RAM there into the hole. The mapper turns each access into
  // one ordinary backend read/write at peg_base. Decoded on route_addr BELOW (the window-0
  // biased address), so a 0x0461 window over these pages reaches the same EVRAM its direct
  // encoding does (aliases.md A6) rather than raw SDRAM.
  // THE PEGC'S HIGH ALIAS (M3/M4): the same 512 KiB linear VRAM is decoded at
  // 0xFFF00000-0xFFF7FFFF as well (qemu pegc_high; NP2kai memp_read8 forwards
  // >= 0xfff00000 && < 0xfff80000 to memvgaf). Translating it to 0x00F00000 lets the SAME
  // peg_window decode and the SAME peg_base arithmetic serve both, with no second window.
  // THE HIGH ALIAS DOES NOT DEPEND ON 0x043B: NP2kai's memp_read8 decodes it with no
  // system-space term (i386c/cpumem.c:805), and MAME's pegc_vram_view maps it under the
  // [0xE0102] gate alone while its m_hole_15M_view covers only 0x00F00000-0x00FFFFFF
  // (MAME src/mame/nec/pc9821.cpp:684-691). Only the 0xE0102
  // enable (peg_aperture_open below) gates it. tb_pc9821_sys16m CHK-9.
  wire peg_high = (&cpu_addr[31:24]) && (cpu_addr[23:20] == 4'hF) && !cpu_addr[19];
  // BOTH TRANSLATIONS ARE BIT SPLICES, NOT SUBTRACTIONS. sys16m_mirror's range has bits [23:20]
  // all 1, so `addr - 0xF00000` clears [23:20] and leaves [19:0] -- the borrow cannot reach them.
  // peg_high's range has bits [31:24] all 1, so `addr - 0xFF000000` likewise leaves [23:0]. The
  // carry chains they are NOT cost 1.17 ns of 19.1 ns clk_sys path.
  // THE BIOS AT THE TOP OF 4 GiB, IN BOTH A20 ALIASES: 0xFFFE8000-0xFFFFFFFF and its
  // bit-20-cleared twin 0xFFEE8000-0xFFEFFFFF are the E8000-FFFFF BIOS window (MAME
  // pc9821.cpp:688-689 maps the IPL bank device at both). The reset fetch is at 0xFFFFFFF0
  // with A20 MASKED, and the Xe10's gate clears physical bit 20 only
  // (docs/probes/A20MAP-XE10.TXT: BIT20-ONLY; z486's PC-98 preset now does the same), so the
  // first fetch reaches the bus as 0xFFEFFFF0 and only this alias makes it the ROM. Before the
  // preset changed, its 1 MiB wrap folded that fetch onto 0x000FFFF0 instead. Bit slice:
  // [31:21] all ones, [20] either, [19:15] >= 5'b11101 (0xE8000); it subsumes the mapper's
  // fw_high (0xFFFF8000-0xFFFFFFFF), which now only sees already-translated addresses.
  // tb_pc9821_sys16m CHK-10.
  wire bios_top  = (&cpu_addr[31:21]) && (cpu_addr[19:15] >= 5'b11101);
  wire [31:0] eff_addr = sys16m_mirror ? {12'd0, cpu_addr[19:0]} :
                         peg_high       ? {8'd0,  cpu_addr[23:0]} :
                         bios_top       ? {12'd0, cpu_addr[19:0]} :
                                          cpu_addr;
  // WINDOW 0's 0x0461 bias, the same translation pc9821_memory_map applies to its own windows
  // (d_addr = cpu_addr + win0_sel*0x10000 - 0x80000 for win0_sel != 0x08). The text VRAM and
  // CG route selects are THIS file's, so they must see the translated address too: without it
  // a window-0 = 0x0A access to guest 0x80000/0x84000 misses 0xA0000/0xA4000 and lands in RAM
  // (M1/M2).
  // THE 0x80000-0x9FFFF MEMBERSHIP TEST COLLAPSES TO RAW ADDRESS BITS, and with it the
  // eff_addr mux, the sys16m_mirror compare and peg_high leave win0_moved's cone
  // entirely.  The test is on the POST-translation address ([31:20] zero and [19:17]
  // == 100 on eff_addr), but no translation arm can change the answer: eff_addr[19:17]
  // is cpu_addr[19:17] under all three arms; the mirror arm can never produce the window
  // (its cpu_addr[23:16] >= 8'hFA needs cpu_addr[19:16] >= 4'hA where the window needs
  // cpu_addr[19:16] in 4'h8..4'h9 - disjoint); and the PEGC arm's eff_addr[31:20] is
  // {8'd0, cpu_addr[23:20]}, zero only where peg_high (which requires [23:20] == 4'hF)
  // cannot hold.  So translate-then-test is exactly the first-MiB bit slice
  // pc9821_memory_map's win0_in_window uses (one spelling for the one concept).
  // The old factored form carried peg_high IN SERIES with win0_moved through a term that
  // is identically zero, and that series cost sat on the lightoc fit's worst path
  // (peg_high~1/2 -> win0_moved~3/4, ~1.4 ns of the ext_addr_r -> u_gmem porta_we_reg
  // cone) and on the 2026-09-28 fit's ext_addr_r -> u_gmem cone (peg_high~1 ->
  // win0_moved~2 -> gvram_window~1).
  // Bit-equal for every 32-bit input, not only the reachable ones (SAT over all free input
  // bits), and
  // tb_pc9821_gvram_porta_equiv pins the port stream through every alias - including its
  // 9d corner (the 0xAB08_0000 class), which is exactly the dead-term case.
  // win0_sel_moved: pc9821_iobus's registered `win0_sel != 8'h08`, equal to it every cycle.
  wire win0_moved = !(|cpu_addr[31:20]) && (cpu_addr[19:17] == 3'b100) &&
                    win0_sel_moved;
  // Inside the window the bias add touches bit 16 upward only: eff_addr - 0x80000 is exactly
  // eff_addr[16:0], and win0_sel << 16 lands the page in [23:16]. So this is a 9-bit add with the
  // low 16 bits wired through, not the 32-bit carry chain `+ {8'd0,win0_sel,16'd0} - 0x80000`
  // (another ~1 ns of path). win0_sel[0] is always 0 (pc9821_iobus masks 0xFE), but
  // the eff_addr[16] carry term keeps the odd-value arithmetic identical anyway.
  // cpu_addr[16] (eff_addr[16] is cpu_addr[16] under every arm: the mirror and the PEGC
  // splice keep [19:0] and [23:0] verbatim), so the increment's carry term skips the mux.
  wire [8:0] win0_hi = {1'b0, win0_sel} + {8'd0, cpu_addr[16]};
  /* verilator lint_off UNUSEDSIGNAL */   // route_addr[11:0]: the >= guest_ram_bytes compare moved to the map (addr_ge_ram)
  wire [31:0] route_addr = win0_moved ? {7'd0, win0_hi, eff_addr[15:0]} : eff_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  // The PEGC extended-VRAM window (the decode commented above): on route_addr,
  // the post-window-0 address every other route uses, so the overlay and its
  // direct encoding agree (aliases.md A6).
  // The direct 0xF00000 encoding needs the system-space window ON; the high alias (spliced
  // to the same route_addr) does not.
  wire peg_window    = (sys16m_en || peg_high) &&
                       !(|route_addr[31:24]) && (route_addr[23:20] == 4'hF) &&
                       !route_addr[19];
  // Window 0 = 0x0A aliases QEMU's 32 KiB tvram overlay, which swallows the CG offset too
  // (0x84000 -> 0xA4000 is still the text VRAM there, M1); the direct address keeps
  // the 16 KiB TRAM and the CG window, because the CG window has the higher priority.
  // 0xA0000-0xA7FFF, and window 0 = 0x0A swallows only the 16 KiB TRAM half of it.
  wire tram_window = !(|route_addr[31:20]) && (route_addr[19:16] == 4'hA) && !route_addr[15];
  wire tram_select = tram_window && (win0_moved || !route_addr[14]);
  // The GVRAM route. The mapper owns the plane-window decode (window 0's bias
  // included) and emits a plane index and a plane offset; pc9821_gvram owns the
  // planes from there. Both are functions of cpu_addr alone, so gating the
  // mapper's cpu_valid with gvram_select cannot loop.
  wire map_gvram_window;
  wire gvram_select = map_gvram_window;
  wire map_pegc_reg_win, map_pegc_nc, map_pegc_packed;
  wire map_addr_ge_ram;
  wire peg_reg_select = map_pegc_reg_win;
  wire [1:0]  map_gvram_plane;
  wire [14:0] map_gvram_offset;
  wire [31:0] gvram_cpu_dout;
  wire [127:0] gvram_cpu_line_dout;
  wire gvram_cpu_ready, gvram_cpu_resp_valid, gvram_cpu_line_resp_valid;
  // The ONE responder for both 0xA0000-range byte windows (pc9821_window_responder). The two
  // routes are never in flight together, so the shared engine's outputs are this file's
  // `win_*` and the ready/response muxes below carry three registered routes, not four.
  wire [31:0] win_cpu_dout;  wire [127:0] win_cpu_line_dout;
  wire win_cpu_ready, win_cpu_resp_valid, win_cpu_line_resp_valid;
  // The PEGC register file's route (pc9821_pegc): a REGISTERED responder exactly as
  // pc9821_open_bus is, on the map's pegc_reg_win decode.
  wire [31:0] peg_cpu_dout;  wire [127:0] peg_cpu_line_dout;
  wire peg_cpu_ready, peg_cpu_resp_valid, peg_cpu_line_resp_valid;
  wire pegc_plane_mode, pegc_vram_en;
  wire [3:0] pegc_bank_a, pegc_bank_b;

  // The memory-mapped CG window at 0xA4000-0xA4FFF (the deferral D3 now
  // implemented): not RAM, but a 32-byte repeating view of the selected glyph,
  // sharing the writable user-CG store with port 0xA9. Serving it from guest
  // RAM is what made the authentic ITF's switch-image verify fail at
  // BANK4@0xFC681. 0xE0000-0xE7FFF is still served from the GVRAM bias; that
  // separate open-bus question is untouched here.
  wire cg_win_select = !win0_moved && tram_window && route_addr[14] &&
                       !route_addr[13] && !route_addr[12];
  // THE 12 KiB GAP BETWEEN THE TEXT RAM AND THE PLANES, 0xA5000-0xA7FFF: the machine reads
  // 0xFF there and DISCARDS stores -- the absent-region shape, not RAM. Nothing decoded it, so
  // the mapper's default arm served it as live guest storage at d_addr. It is not an alias and
  // not a window that is one bit too wide: `tram_window` deliberately spans the whole 32 KiB so
  // window 0 = 0x0A can lay the 32 KiB text overlay over 0xA0000-0xA7FFF (see tram_select), and
  // the DIRECT encoding's upper 12 KiB had no owner of its own. This is that owner.
  // Machine: docs/probes/VRAM.TXT:141-142 (`A600wrote= 00 FF 55 AA` / `got= FF FF FF FF`,
  // reproduced in VRAM2.TXT:153-154) with its neighbouring A000/A200 (TRAM) and A800/B000/B800
  // (planes) rows round-tripping in the SAME capture, so the probe was writing and reading
  // working storage either side of the hole; NP2kai drops the store there the same way
  // (mem/memtram.c:73-100 has no write arm past 0xA5000).
  // `!tram_select` is what keeps the window-0 alias out of it: with win0_moved set,
  // tram_select already claims the whole 32 KiB, so a 0x0461 = 0x0A overlay keeps the shape
  // the same capture pins (`0461=0A ... a=5AA5`, the marker round-tripping at the window base).
  wire tram_gap = tram_window && !tram_select && !cg_win_select;
  // The C-Bus absent ROM area (0xC0000-0xD7FFF) is decoded by the mapper -- on
  // the translated address, so window 0 = 0x0C inherits it -- and routed here to
  // the registered responder: the machine reads all ones there and discards
  // stores. It has to be a route rather than the map's own
  // answer, because the map's local paths reply in the accept cycle and that
  // wedges z486 (see the local_open_bus note in pc9821_memory_map.sv).
  wire map_absent_area;
  wire map_ems_open_bus;
  // The EMS window (0x043F 0x2 nibble) at 0xB0000-0xBFFFF. State 1 is 64 KiB of page RAM
  // and is served by the mapper from ems_page_base; state 2 is the machine's unmapped state
  // and is answered by the registered responder below, never the map's combinational local
  // path (which wedges z486). The map DECODES both (on the same post-window-0 address as its
  // other regions) and this file only routes them - the absent-ROM area's shape.
  // ems_page_base sits one PACK_BYTES above the pack, in the 256 KiB the SDRAM budget
  // already reserves above it, so it costs no new budget (see the GVRAM instance's note).
  /* verilator lint_off WIDTHEXPAND */ // PACK_BYTES (27b) zero-extends to 32b exactly; the page base is bounded inside the SDRAM reserve
  wire [31:0] ems_page_base = pack_base + PACK_BYTES + 32'h0004_8000;
  /* verilator lint_on WIDTHEXPAND */
  // THE TOP-WINDOW SHADOW: the writable layer of 0xF8000-0xFFFFF, 32 KiB inside
  // the SAME 256 KiB SDRAM reserve the EMS page uses, past the page's 64 KiB. The loader
  // tees the pack's BIOS-top bank into it; the mapper reads it as the window once its
  // first store lands. The reserve already exists, so this costs no SDRAM budget and no
  // M10K blocks (the PCM buffer sits a further 0x40000 above the reserve).
  /* verilator lint_off WIDTHEXPAND */ // PACK_BYTES (27b) zero-extends to 32b exactly; the base is bounded inside the SDRAM reserve
  wire [31:0] fw_shadow_base = pack_base + PACK_BYTES + 32'h0005_8000;
  /* verilator lint_on WIDTHEXPAND */
  // The PEGC extended VRAM: 512 KiB of one-byte-wide RAM (not the four-plane fold)
  // placed above the 32 KiB PCM buffer at pack_base + 0x140000 so it adds no M10K and takes only
  // the SDRAM the budget already reserves (docs/pc9821-port-status.md).
  /* verilator lint_off WIDTHEXPAND */ // PACK_BYTES (27b) zero-extends to 32b exactly; the base is bounded inside the SDRAM reserve
  wire [31:0] peg_base = pack_base + PACK_BYTES + 32'h0008_0000;
  /* verilator lint_on WIDTHEXPAND */
  // Set once a gated store has landed in the shadow and cleared by reset, so the boot after
  // an OSD reset reads the pack's pristine BIOS-top bank until the ITF stores again. That
  // is what lets the ITF's SECOND ROM-sum pass (run after it enables the shadow) still read
  // ROM instead of the previous boot's stored byte.
  reg fw_shadow_dirty;
  wire fw_shadow_store;

  // The GVRAM's 256 KiB lives in M10K now, so its old SDRAM region above the firmware
  // reserve is unused: no gvram_base and no requester. The EMS page and the top-window shadow stay
  // where put them (above the PCM buffer) so the SDRAM map is unchanged.
  // THE 0xE0102 GATE ON THE FLAT APERTURE (row 2): with the register file's VRAM
  // enable bit clear the 0xF00000 window is NOT the store - NP2kai's memvgaf_rd8
  // answers 0xFF and memvgaf_wr8 drops the store unless `mio2[PEGC_REG_VRAM_ENABLE]
  // & 1` (mem/memvga.c), and MAME's pegc_vram_view is disabled the same way
  // (pc9821.cpp pegc_mmio_map 0x102). That is the open-bus responder's own shape
  // (0xFF per byte, stores discarded), so the access routes there. qemu gates the
  // aperture on 256-colour mode as well (pegc_post_readb) - recorded, not followed:
  // NP2kai and MAME gate on the register alone, and the real ITF's phase-2 block
  // sets [0xE0102]=1 inside its own 0x6A 0x21 bracket before filling
  // (BANK4@0x1434-0x144C disassembled from the owner's pack).
  wire peg_aperture_open = peg_window && !pegc_vram_en;
  wire open_select = !cg_win_select && !peg_window &&
                     (map_absent_area || map_pegc_nc || map_ems_open_bus || sys16m_hole ||
                      tram_gap ||
                      (map_addr_ge_ram &&
                       !(&route_addr[31:15]))) ||
                     peg_aperture_open;
  wire [31:0] open_cpu_dout;
  wire [127:0] open_cpu_line_dout;
  wire open_cpu_ready, open_cpu_resp_valid, open_cpu_line_resp_valid;

  // A selected download takes ownership immediately, before the loader has
  // registered its first word. Holding ownership until rom_ready also keeps a
  // reset CPU from reading uninitialized firmware.
  wire loader_owns = selected_download || load_valid || !rom_ready;
  assign cpu_run = rom_ready && !load_error && !selected_download;

          // WHICH RESPONSE BELONGS TO WHOM. The map's response must not be inferred from "the most
          // recent accept": the backend serves one request at a time, but the clock bridge's ack
          // path is two clk_sys cycles SHORTER than its response path, so a second accept can arrive
          // before the first response (measured on this bridge: ready2=10107 < resp1=10109). A
          // one-deep flag would be overwritten by the second accept and the first response gated
          // off, so that CPU waits forever for a completion that was delivered. A read accept
          // therefore QUEUES its
          // owed beat count and the response beats pop it; `sdram` answers one resp_valid per read
          // dword, so an entry carries its dword count. A write queues nothing (it owes no response).
          //
          // THE ROUTE FIELD IS GONE because only one route ever reads: pc9821_rom_loader drives
          // mem_write=1, so `read_accept` (backend accept && !mem_write) can
          // only be the mapper's. The old rt_route[]/OWNER_* restated that fact every cycle; a
          // response's route is now the response itself.
  reg  [7:0] rt_beats [0:3];
  // THE ROUTE FIELD IS BACK, one bit: the DMA bus master READS too now (WRITE DATA's
  // memory-to-port bytes), so a queued read is the mapper's or the DMA's, and its response
  // beat goes to the one that issued it. Before this the DMA's read was answered by NOBODY:
  // dma_resp_valid was tied 0, so the engine waited in S_RESP forever and a floppy WRITE hung
  // on hardware with no byte reaching the FDC (fdd-write lane, the MiSTer COPY test), while
  // the beat itself was counted as the mapper's.
  reg  [3:0] rt_dma;
  reg  [2:0] rt_wr, rt_rd;
  reg  [7:0] rt_left;
  wire map_accepted;
  wire rt_full;
  wire rt_empty;

  pc9821_rom_loader #(
      .IOCTL_INDEX(IOCTL_INDEX),
      .PACK_BYTES(PACK_BYTES)
  ) loader (
      .clk(clk), .reset(reset), .pack_base(pack_base),
      .shadow_base(fw_shadow_base),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
      .ioctl_wait(ioctl_wait),
      .mem_valid(load_valid), .mem_ready(load_ready),
      .mem_addr(load_addr), .mem_din(load_din), .mem_be(load_be),
      .mem_burstcount(load_burstcount),
      .mem_write(load_write),
      .rom_ready(rom_ready), .load_error(load_error),
      .saw_download(saw_download)
  );

  // BOTH BYTE WINDOWS ARE ONE RESPONDER. pc9821_tram_bridge and pc9821_cg_window were the
  // same eight-state byte-walk engine written twice; pc9821_window_responder is that engine
  // once, with the backend muxed by route_cg. Sharing is legal because the two routes are
  // NEVER in flight together, and that is a property of the ROUTE/select logic rather than of
  // the sequencer: tram_select requires the post-window-0 address's bit 14 clear and
  // cg_win_select requires bit 14 set with !win0_moved, so the two are disjoint for EVERY
  // input (SAT-proved over the shipped predicate text,
  // and caught at runtime by the route-overlap check further down); the engine's cpu_valid is
  // exactly their OR, so it can never be fed two routes at once; and one z486 memory request
  // is in flight at a time. The select is held for the life of the request, which is what
  // makes route_cg stable across the walk. There is NO per-device state to lose on a route
  // switch -- base, write data, byte index and the 128-bit accumulator are the request in
  // flight -- which is the test that makes this share legal where a share with per-device
  // state would not be.
  //
  // eff_addr[13:0] carries both routes: the TRAM route uses the full 14 bits, and the CG
  // window's route (route_addr[14] with !route_addr[13] && !route_addr[12], under
  // !win0_moved so eff_addr == route_addr) keeps [13:12] zero, so the responder's 14-bit
  // indexed sum equals the old 13-bit off_sum exactly.
  pc9821_window_responder u_window (
      .clk(clk), .reset(reset || !cpu_run),
      .route_cg(cg_win_select),
      .cpu_addr(eff_addr[13:0]), .cpu_din(cpu_din), .cpu_be(cpu_be),
      .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid && cpu_run && (tram_select || cg_win_select)),
      .cpu_write(cpu_write), .cpu_dout(win_cpu_dout),
      .cpu_line_dout(win_cpu_line_dout), .cpu_ready(win_cpu_ready),
      .cpu_resp_valid(win_cpu_resp_valid),
      .cpu_line_resp_valid(win_cpu_line_resp_valid),
      .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we),
      .tram_dout(tram_dout),
      .byte_sel(cg_win_byte_sel), .byte_rd(cg_win_rd),
      .byte_dout(cg_win_dout), .byte_din(cg_win_din), .byte_we(cg_win_we),
      .byte_hold(cg_win_byte_hold)
  );

  // The pack's FONT.ROM copy. FONT_PACK_OFFSET is where the 1 MiB pack carries the whole
  // FONT.ROM verbatim (0x46800 bytes, at the old 512 KiB reserve boundary; see
  // tools/pack_layout.py). The JIS glyph classes read it from here.
  localparam [31:0] FONT_PACK_OFFSET = 32'h0008_0000;
  // One glyph block is ONE 8-dword burst, so the requester holds font_req for the whole
  // block and the port answers eight font_word_valid beats (one dword each, in address
  // order). font_left counts the beats still owed; only an idle port issues, and it stays
  // busy until the last beat lands, so a held font_req cannot retrigger mid-burst.
  localparam [3:0] FONT_BURST_WORDS = 4'd8;
  reg  [3:0] font_left;
  wire font_issue = font_req && (font_left == 4'd0);

  assign fmem_addr       = pack_base + FONT_PACK_OFFSET + {13'd0, font_req_addr};
  assign fmem_valid      = font_issue;
  assign fmem_write      = 1'b0;
  assign fmem_din        = 32'd0;
  assign fmem_be         = 4'b1111;
  assign fmem_burstcount = {4'd0, FONT_BURST_WORDS};
  assign font_word_valid = fmem_resp_valid;
  assign font_word_data  = fmem_dout;

  always @(posedge clk) begin
    if (reset) font_left <= 4'd0;
    else if (font_left != 4'd0) begin
      if (fmem_resp_valid) font_left <= font_left - 4'd1;
    end else if (font_issue && fmem_ready) begin
      font_left <= FONT_BURST_WORDS;
    end
  end

  pc9821_open_bus open_bus (
      .clk(clk), .reset(reset || !cpu_run),
      .cpu_valid(cpu_valid && cpu_run && open_select),
      .cpu_write(cpu_write), .cpu_line_read(cpu_line_read),
      .cpu_dout(open_cpu_dout), .cpu_line_dout(open_cpu_line_dout),
      .cpu_ready(open_cpu_ready), .cpu_resp_valid(open_cpu_resp_valid),
      .cpu_line_resp_valid(open_cpu_line_resp_valid)
  );

  // THE PEGC REGISTER FILE (row 1), on the map's pegc_reg_win decode. It owns the
  // bank/mode/VRAM-enable state the map's packed arms and the aperture gate above
  // consume. Its responder is the open_bus shape: accept and response in separate
  // cycles (see pc9821_pegc's header for the register semantics and the recorded
  // divergences).
  pc9821_pegc u_pegc (
      .clk(clk), .reset(reset || !cpu_run),
      .cpu_valid(cpu_valid && cpu_run && peg_reg_select),
      .cpu_write(cpu_write), .cpu_line_read(cpu_line_read),
      .cpu_addr(eff_addr[14:0]), .cpu_din(cpu_din), .cpu_be(cpu_be),
      .cpu_dout(peg_cpu_dout), .cpu_line_dout(peg_cpu_line_dout),
      .cpu_ready(peg_cpu_ready), .cpu_resp_valid(peg_cpu_resp_valid),
      .cpu_line_resp_valid(peg_cpu_line_resp_valid),
      .bank_a(pegc_bank_a), .bank_b(pegc_bank_b),
      .plane_mode(pegc_plane_mode), .vram_en(pegc_vram_en)
  );

  pc9821_memory_map mapper (
      .top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(d8_bank),
      .ide_ram_gate(ide_ram_gate),
      .ems_state(ems_state), .ems_page_base(ems_page_base),
      .bios_ram_gate(bios_ram_gate), .win0_sel(win0_sel), .win0_sel_moved(win0_sel_moved),
      .top_shadow_en(top_shadow_en), .fw_shadow_dirty(fw_shadow_dirty),
      .fw_shadow_base(fw_shadow_base), .fw_shadow_store(fw_shadow_store),
      .pack_base(pack_base), .guest_ram_bytes(guest_ram_bytes),
      // The PEGC extended-VRAM window: the subsystem decodes it (it owns sys16m_en) and
      // the mapper serves it, so the access takes the ordinary backend route and its own
      // valid/ready/response discipline rather than a second responder beside the map.
      .peg_window(peg_window), .peg_base(peg_base),
      // The PEGC 256-colour window arms: the packed
      // windows' bank splice takes the ordinary backend route below; the register-file
      // and not-connected decodes are routed above/below to their responders.
      .pegc_256(pegc_256), .pegc_plane(pegc_plane_mode),
      .pegc_bank_a(pegc_bank_a), .pegc_bank_b(pegc_bank_b),
      // The packed-arm decode is the store buffer's route qualifier now (the
      // posted PEGC stores, pc9821_pegc_storebuf); the arm itself takes the
      // ordinary backend route below.
      .pegc_packed(map_pegc_packed),
      .pegc_reg_win(map_pegc_reg_win),
      .pegc_nc(map_pegc_nc),
      // The map decodes the plane windows and nothing else: the planes
      // themselves are pc9821_gvram's (the instance below), which owns them in M10K.
      .gvram_window(map_gvram_window), .gvram_win_plane(map_gvram_plane),
      .gvram_win_offset(map_gvram_offset),
      .cpu_addr(eff_addr), .cpu_din(cpu_din),
      // ... and the untranslated address with eff_addr's arm, so the map's control decodes
      // select the translation last (the three arms are mutually exclusive: the mirror needs
      // [31:24] zero, the PEGC alias [31:24] all ones with bit 19 clear, the BIOS alias bit 19 set).
      .cpu_addr_raw(cpu_addr), .xl_low20(sys16m_mirror || bios_top), .xl_peg(peg_high),
      // The mapper's WORD response is sourced from the backend below (the only port-0 reader);
      // its own cpu_dout/cpu_resp_valid answer its unreachable local open-bus path and stay open.
      // Its LINE response (cpu_line_dout/cpu_line_resp_valid) IS wired out: the 128-bit line
      // form has no backend producer, so the mapper's local path is the whole of it.
      /* verilator lint_off PINCONNECTEMPTY */   // intentional: this route's word responses are sourced from the backend below
      .cpu_dout(), .cpu_line_dout(map_cpu_line_dout),
      .cpu_be(cpu_be),
      .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid && cpu_run && !tram_select && !open_select &&
                 !cg_win_select && !gvram_select && !peg_reg_select),
      .cpu_write(cpu_write),
      .cpu_ready(map_cpu_ready), .cpu_resp_valid(), .cpu_line_resp_valid(map_cpu_line_resp_valid),
      /* verilator lint_on PINCONNECTEMPTY */
      .absent_area(map_absent_area), .addr_ge_ram(map_addr_ge_ram), .ems_open_bus(map_ems_open_bus),
      .mem_addr(map_addr), .mem_din(map_din), .mem_dout(mem_dout),
      .mem_be(map_be),
      .mem_burstcount(map_burstcount),
      .mem_valid(map_valid), .mem_write(map_write), .mem_ready(map_ready),
      // Drained inputs: the mapper's own response outputs are open, but an undriven INPUT is a
      // defect (tools/check_port_lists.py), so they keep the real accept-gated backend signals.
      .mem_resp_valid(mem_resp_valid && !loader_owns && map_accepted)
  );

  // THE MAP ROUTE'S WORD RESPONSE IS THE BACKEND'S, NOT THE MAPPER'S ADDRESS DECODE. The mapper's
  // own cpu_dout/cpu_resp_valid answer its LOCAL open-bus path (an out_of_range read replies
  // 0xFFFFFFFF in the accept cycle, pc9821_memory_map). That path is UNREACHABLE in this
  // subsystem: every out_of_range address is already covered by open_select below, and the
  // mapper's cpu_valid is gated with !open_select, so its local_open_bus is provably 0 for every
  // input this file can present (tb_pc9821_memory_map pins the standalone shape;
  // tb_pc9821_memory_subsystem pins this one). Sourcing map_cpu_dout/map_cpu_resp_valid from the
  // backend is therefore bit-identical. Selecting them inside the mapper would put the CPU
  // address on the 128-bit response mux, which measured as
  // `ext_addr_r -> map decode -> line mux -> z486 icache fill`, 19.100 ns / 16 levels. The backend
  // is the ONLY port-0 READER (pc9821_rom_loader drives mem_write=1), so every backend read
  // response is this route's. The LINE form has no backend producer at all (cache fills complete
  // as burstcount==4 word responses), so it stays the mapper's own local_open_bus decode.
  assign map_cpu_dout            = mem_dout;
  assign map_cpu_resp_valid      = mem_resp_valid && !loader_owns && map_accepted;

  // The one four-plane GVRAM datapath, in FIVE pieces: the array
  // (pc9821_gvram_mem), the thin arbiter (pc9821_gvram_arb, the owner latch + client mux +
  // the CPU's array datapath), the scanout line buffer (pc9821_gvram_scan, a sibling that
  // only reads port B), and the two engines (pc9821_grcg, pc9821_egc), instantiated here so
  // neither can grow a second route to the planes -- which is the whole point of this route.
  // The array is block RAM, so the group makes NO backend request and takes no requester
  // slot here: `gvram_select` gates the CPU-side route and nothing else.
  wire [15:0] gma_addr;
  wire [31:0] gma_din;
  wire  [3:0] gma_be;
  wire        gma_we, gma_en;
  wire [31:0] gma_dout;
  wire [15:0] gmb_addr;
  wire        gmb_en;
  wire [31:0] gmb_dout;
  wire        grcg_expand_gate, grcg_tcr_gate;
  wire        grcg_cl_valid, grcg_cl_write;
  wire [15:0] grcg_cl_addr;
  wire [31:0] grcg_cl_wdata;
  wire        grcg_cl_cap;
  wire        grcg_cl_cap_rmw;
  wire  [3:0] grcg_cl_hold_be;
  wire        grcg_cl_hold_rmw;
  wire  [3:0] grcg_cl_hold_datum0;
  wire  [3:0] grcg_cl_hold_mergeable;
  wire  [3:0] grcg_cl_wbe, grcg_cl_be;
  wire [31:0] grcg_cl_tile;
  wire        grcg_cl_rmw, grcg_cl_burst;
  wire [63:0] grcg_cl_wdata2;
  wire        grcg_cl_ready, grcg_cl_done;
  wire [31:0] grcg_cpu_dout;
  wire        grcg_cpu_ready, grcg_cpu_resp_valid;
  wire        grcg_dbg_busy, grcg_dbg_rmw, grcg_dbg_write;
  wire        egc_cl_valid, egc_cl_write;
  wire [15:0] egc_cl_addr;
  wire [31:0] egc_cl_wdata;
  wire  [3:0] egc_cl_datum0;
  wire  [3:0] egc_cl_wbe;
  wire        egc_cl_burst;
  wire [63:0] egc_cl_wdata2;
  wire        egc_cl_ready, egc_cl_done;
  wire [31:0] egc_cpu_dout;
  wire        egc_cpu_ready, egc_cpu_resp_valid;
  wire        egc_dbg_busy;
  wire        gvram_own_grcg, gvram_own_egc;
  wire [31:0] gvram_cl_rdata;
  // The CPU-side port share (pc9821_gvram_share): the arb's CPU route and the two
  // engines' store ports see ONE master at a time - the CPU or the GDC draw engine.
  wire        gvr_valid, gvr_write, gvr_line_read, gvr_page;
  wire  [1:0] gvr_plane;
  wire [14:0] gvr_offset;
  wire [31:0] gvr_din;
  wire  [3:0] gvr_be;
  wire        gvr_gate_egc, gvr_gate_grcg, gvr_gate_tcr;
  wire        gvr_ready, gvr_resp_valid, gvr_line_resp_valid;
  wire [31:0] gvr_dout;
  wire [127:0] gvr_line_dout;

  pc9821_gvram_mem u_gmem (
      .clk(clk),
      .a_addr(gma_addr), .a_din(gma_din), .a_be(gma_be),
      .a_we(gma_we), .a_en(gma_en), .a_dout(gma_dout),
      .b_addr(gmb_addr), .b_en(gmb_en), .b_dout(gmb_dout)
  );

  // The share muxes the engine gates with the GDC visit's OWN latched route per draw;
  // `egc_enable` arrives already in its post-AND form (the EGC's enable ANDed with the
  // GRCG's mode bit 7 - pc9821_system's gdc_egc_mem_gate, NP2kai VOPBIT_EGC &&
  // VOPBIT_GRCG), which is exactly the dispatch gate the arb reads.
  pc9821_gvram_share u_gvr_share (
      .clk(clk), .reset(reset || !cpu_run),
      .cpu_req(cpu_valid && cpu_run && gvram_select),
      .cpu_write(cpu_write),
      .cpu_line_read(cpu_line_read),
      .cpu_page(gvram_access_page),
      .cpu_plane(map_gvram_plane),
      .cpu_offset(map_gvram_offset),
      .cpu_din(cpu_din),
      .cpu_be(cpu_be),
      .gate_egc(egc_enable),
      .gate_grcg(grcg_expand_gate),
      .gate_tcr(grcg_tcr_gate),
      .cpu_ready(gvram_cpu_ready),
      .cpu_resp_valid(gvram_cpu_resp_valid),
      .cpu_dout(gvram_cpu_dout),
      .cpu_line_resp_valid(gvram_cpu_line_resp_valid),
      .cpu_line_dout(gvram_cpu_line_dout),
      .gdc_valid(gdc_mem_valid),
      .gdc_write(gdc_mem_write),
      .gdc_route_egc(gdc_mem_route_egc),
      .gdc_route_grcg(gdc_mem_route_grcg),
      .gdc_page(gdc_mem_page),
      .gdc_plane(gdc_mem_plane),
      .gdc_offset(gdc_mem_offset),
      .gdc_din(gdc_mem_din),
      .gdc_be(gdc_mem_be),
      .gdc_ready(gdc_mem_ready),
      .gdc_resp_valid(gdc_mem_resp),
      .gdc_rdata(gdc_mem_rdata),
      .gvr_valid(gvr_valid),
      .gvr_write(gvr_write),
      .gvr_line_read(gvr_line_read),
      .gvr_page(gvr_page),
      .gvr_plane(gvr_plane),
      .gvr_offset(gvr_offset),
      .gvr_din(gvr_din),
      .gvr_be(gvr_be),
      .gvr_gate_egc(gvr_gate_egc),
      .gvr_gate_grcg(gvr_gate_grcg),
      .gvr_gate_tcr(gvr_gate_tcr),
      .gvr_ready(gvr_ready),
      .gvr_resp_valid(gvr_resp_valid),
      .gvr_dout(gvr_dout),
      .gvr_line_resp_valid(gvr_line_resp_valid),
      .gvr_line_dout(gvr_line_dout)
  );

  pc9821_gvram_arb #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) u_gvram_arb (
      .clk(clk), .reset(reset || !cpu_run),
      .access_page(gvr_page),
      .win_plane(gvr_plane), .win_offset(gvr_offset),
      .cpu_din(gvr_din), .cpu_be(gvr_be), .cpu_line_read(gvr_line_read),
      .cpu_valid(gvr_valid),
      .cpu_write(gvr_write),
      .cpu_dout(gvr_dout),
      .cpu_line_dout(gvr_line_dout),
      .cpu_ready(gvr_ready), .cpu_resp_valid(gvr_resp_valid),
      .cpu_line_resp_valid(gvr_line_resp_valid),
      .grcg_expand_gate(gvr_gate_grcg), .grcg_tcr_gate(gvr_gate_tcr),
      .egc_gate(gvr_gate_egc),
      .grcg_cl_valid(grcg_cl_valid), .grcg_cl_write(grcg_cl_write),
      .grcg_cl_addr(grcg_cl_addr), .grcg_cl_be(grcg_cl_be),
      .grcg_cl_wdata(grcg_cl_wdata), .grcg_cl_wbe(grcg_cl_wbe),
      .grcg_cl_cap(grcg_cl_cap), .grcg_cl_cap_rmw(grcg_cl_cap_rmw),
      .grcg_cl_hold_be(grcg_cl_hold_be), .grcg_cl_hold_rmw(grcg_cl_hold_rmw),
      .grcg_cl_hold_datum0(grcg_cl_hold_datum0),
      .grcg_cl_hold_mergeable(grcg_cl_hold_mergeable),
      .grcg_cl_tile(grcg_cl_tile), .grcg_cl_rmw(grcg_cl_rmw),
      .grcg_cl_burst(grcg_cl_burst), .grcg_cl_wdata2(grcg_cl_wdata2),
      .grcg_cl_ready(grcg_cl_ready),
      .grcg_cpu_dout(grcg_cpu_dout), .grcg_cpu_ready(grcg_cpu_ready),
      .grcg_cpu_resp_valid(grcg_cpu_resp_valid),
      .grcg_dbg_busy(grcg_dbg_busy), .grcg_dbg_rmw(grcg_dbg_rmw),
      .grcg_dbg_write(grcg_dbg_write),
      .egc_cl_valid(egc_cl_valid), .egc_cl_write(egc_cl_write),
      .egc_cl_addr(egc_cl_addr), .egc_cl_wdata(egc_cl_wdata),
      .egc_cl_datum0(egc_cl_datum0),
      .egc_cl_wbe(egc_cl_wbe), .egc_cl_burst(egc_cl_burst),
      .egc_cl_wdata2(egc_cl_wdata2), .egc_cl_ready(egc_cl_ready),
      .egc_cpu_dout(egc_cpu_dout), .egc_cpu_ready(egc_cpu_ready),
      .egc_cpu_resp_valid(egc_cpu_resp_valid), .egc_dbg_busy(egc_dbg_busy),
      .own_grcg(gvram_own_grcg), .own_egc(gvram_own_egc),
      .cl_rdata(gvram_cl_rdata),
      .grcg_cl_done(grcg_cl_done), .egc_cl_done(egc_cl_done),
      .gma_addr(gma_addr), .gma_din(gma_din), .gma_be(gma_be),
      .gma_we(gma_we), .gma_en(gma_en), .gma_dout(gma_dout),
      .dbg_gfx_stats(dbg_gfx_stats),
      .dbg_walk_start(dbg_walk_start), .dbg_walk_cycle(dbg_walk_cycle),
      .dbg_gr_owned(dbg_gr_owned), .dbg_eg_owned(dbg_eg_owned),
      .dbg_pw_owned(dbg_pw_owned),
      .dbg_access_page(dbg_access_page)
  );

  // THE PACKED SCANOUT (row 3): the 256-colour line fetch beside the planar one,
  // reading the SAME SDRAM store the packed windows write (peg_base). It runs
  // only in 256-colour mode; the planar fetch keeps its own module untouched.
  pc9821_pegc_scan u_pegc_scan (
      .clk(clk), .reset(reset || !cpu_run),
      .scan_enable(scan_enable && pegc_256),
      .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .page_force_zero(pegc_256e),
      .scan_walk_page(scan_walk_page),
      .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .dot_in_col(scan_dot), .dot_ce(scan_dot_ce), .line_rd_act(scan_dot_act),
      .packed_idx(peg_packed_idx), .line_sel(peg_line_sel),
      .line_ready(peg_line_ready),
      .peg_base(peg_base),
      .mem_addr(pmem_addr), .mem_valid(pmem_valid), .mem_write(pmem_write),
      .mem_be(pmem_be), .mem_burstcount(pmem_burstcount), .mem_din(pmem_din),
      .mem_ready(pmem_ready), .mem_dout(pmem_dout), .mem_resp_valid(pmem_resp_valid)
  );

  pc9821_gvram_scan u_gvram_scan (
      .clk(clk), .reset(reset || !cpu_run),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .gfx_odd_line(gfx_odd_line),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready),
      .scan_page_q(dbg_scan_page_q),
      .gmb_addr(gmb_addr), .gmb_en(gmb_en), .gmb_dout(gmb_dout)
  );

  // THE ENGINES' CAPTURE IS GATED BY PLANE-WINDOW MEMBERSHIP, NOT ONLY BY THE OWNER DECODE.
  // `gvram_own_{grcg,egc}` is the arb's pure mode/direction decode (cc_owns_*), so without
  // `gvram_select` an ordinary CPU access OUTSIDE the plane windows was captured as a
  // GRCG/EGC op while mode bit 7 is armed: a store became a phantom TDW/RMW walk into GVRAM
  // at (addr & 0x7FFF), and a 0x80 read stole the CPU's response with TCR garbage and left a
  // spurious second strobe when the map's real response landed (review grcg.md F1;
  // tb_pc9821_gfx_window_gate). The arb's own cpu_valid is already gated by gvram_select;
  // this is the same term on the engines' captures. It gates the READ side equally: with no
  // capture there is no engine response to reach the (address-independent) reg_word_owns
  // mux below, and a non-window read can never consume a registered route's strobe -- z486
  // matches the strobe to its one pending read (memory.sv dcache_read_pending). The
  // plane-window case is bit-identical: gvram_select is 1 there, so the term is a no-op.
  pc9821_grcg u_grcg (
      .clk(clk), .reset(reset || !cpu_run),
      .port_we(grcg_we), .port_addr(grcg_addr), .port_din(grcg_din),
      .mode_r(grcg_mode_r),
      .expand_gate(grcg_expand_gate),
      .tcr_gate(grcg_tcr_gate),
      .cpu_valid(gvr_valid && gvram_own_grcg),
      .cpu_write(gvr_write), .cpu_addr({gvr_page, gvr_offset}),
      .cpu_din(gvr_din), .cpu_be(gvr_be),
      .cpu_dout(grcg_cpu_dout), .cpu_ready(grcg_cpu_ready),
      .cpu_resp_valid(grcg_cpu_resp_valid),
      .cl_valid(grcg_cl_valid), .cl_ready(grcg_cl_ready),
      .cl_write(grcg_cl_write), .cl_addr(grcg_cl_addr),
      .cl_wdata(grcg_cl_wdata), .cl_wbe(grcg_cl_wbe), .cl_be(grcg_cl_be),
      .cl_tile(grcg_cl_tile), .cl_rmw(grcg_cl_rmw), .cl_cap(grcg_cl_cap),
      .cl_cap_rmw(grcg_cl_cap_rmw), .cl_hold_be(grcg_cl_hold_be),
      .cl_hold_rmw(grcg_cl_hold_rmw), .cl_hold_datum0(grcg_cl_hold_datum0),
      .cl_hold_mergeable(grcg_cl_hold_mergeable),
      .cl_burst(grcg_cl_burst), .cl_wdata2(grcg_cl_wdata2),
      .cl_rdata(gvram_cl_rdata), .cl_done(grcg_cl_done),
      .dbg_busy(grcg_dbg_busy), .dbg_rmw(grcg_dbg_rmw), .dbg_write(grcg_dbg_write),
      .dbg_grcg_store(dbg_grcg_store)  );

  // The GRCG's CG-mode bit 7, exported so the core can AND it into the EGC's memory-dispatch
  // gate (NP2kai VOPBIT_EGC && VOPBIT_GRCG).
  assign grcg_expand = grcg_expand_gate;

  pc9821_egc u_egc (
      .clk(clk), .reset(reset || !cpu_run),
      .reg_access(egc_access), .reg_fgbg(egc_fgbg), .reg_ope(egc_ope),
      .reg_fg(egc_fg), .reg_mask(egc_mask), .reg_bg(egc_bg),
      .reg_sft(egc_sft), .reg_leng(egc_leng), .reg_shift_we(egc_shift_we),
      .cpu_page(gvr_page), .cpu_plane(gvr_plane),
      .cpu_offset(gvr_offset), .cpu_din(gvr_din), .cpu_be(gvr_be),
      .cpu_write(gvr_write),
      .cpu_valid(gvr_valid && gvram_own_egc),
      .cpu_dout(egc_cpu_dout), .cpu_ready(egc_cpu_ready),
      .cpu_resp_valid(egc_cpu_resp_valid),
      .cl_valid(egc_cl_valid), .cl_ready(egc_cl_ready),
      .cl_write(egc_cl_write), .cl_addr(egc_cl_addr),
      .cl_wdata(egc_cl_wdata), .cl_datum0(egc_cl_datum0), .cl_wbe(egc_cl_wbe),
      .cl_burst(egc_cl_burst), .cl_wdata2(egc_cl_wdata2),
      .cl_rdata(gvram_cl_rdata), .cl_done(egc_cl_done),
      .dbg_busy(egc_dbg_busy),
      .dbg_egc_txn(dbg_egc_txn), .dbg_egc_unit(dbg_egc_unit)
  );


  // mem_ready may be permanently high; only expose it for the active route. The GVRAM's ready
  // is the one that is NOT a function of the presented request: its client is STATEFUL (a walk
  // can still be in flight when the CPU has already moved to another route's address, which is
  // exactly what a bench that holds cpu_valid past the accept does), so it must be qualified by
  // its own select or it reports an accept for a request that is not the GVRAM's.
  assign cpu_ready = win_cpu_ready || open_cpu_ready ||
                     (gvram_cpu_ready && gvram_select) ||
                     (peg_cpu_ready && peg_reg_select) ||
                     (map_cpu_ready && cpu_valid && cpu_run && !tram_select &&
                      !open_select && !cg_win_select && !gvram_select && !peg_reg_select);
  // The four REGISTERED routes are the mux's select side and the map route is the default. That
  // order is deliberate: written as a `? :` chain with the map input last, the backend's 128 bits
  // sat behind four mux levels, and the z486 icache fill hangs off exactly that output -- the tail
  // of 19.1 ns path. Merging the TRAM bridge and the CG window into one responder removes ONE
  // level there, shortening that named cone while it saves the area. The priority is unchanged
  // (tram / CG window > gvram > pegc regs > open > map); the PEGC register file's level is one
  // more mux on that same cone (the row-2 cone risk).
  wire reg_word_owns = win_cpu_resp_valid ||
                       gvram_cpu_resp_valid || peg_cpu_resp_valid || open_cpu_resp_valid;
  wire reg_line_owns = win_cpu_line_resp_valid || gvram_cpu_line_resp_valid ||
                       peg_cpu_line_resp_valid || open_cpu_line_resp_valid;
  // THE LINE FORM IS INTERNAL NOW (the cpu_line_dout/cpu_line_resp_valid PORTS are gone
  // with the beat-uniform fill, trade-candidates T22): this mux output is the converter's
  // INPUT -- the 128-bit datum the four registered responders assemble for a cache-line
  // read (pc9821_window_responder's read_data walk, pc9821_gvram_arb's C_VAL/C_WAIT walk,
  // pc9821_pegc's repeated dword, pc9821_open_bus's all-ones) and the mapper's own local
  // path (provably never 1 for a read). Kept named as it was so the benches' and userdisk's hierarchical reads
  // of the form keep resolving.
  wire [127:0] cpu_line_dout;
  wire         cpu_line_resp_valid;
  assign cpu_line_resp_valid = reg_line_owns || map_cpu_line_resp_valid;
  assign cpu_line_dout = reg_line_owns ?
                    (win_cpu_line_resp_valid ? win_cpu_line_dout :
                     gvram_cpu_line_resp_valid ? gvram_cpu_line_dout :
                     peg_cpu_line_resp_valid ? peg_cpu_line_dout : open_cpu_line_dout) :
                    map_cpu_line_dout;

  // THE LINE-TO-BEAT CONVERTER (trade-candidates T22): a cache-line fill is answered as
  // FOUR WORD BEATS whatever route served it, so the L1's fill form is uniform and
  // z486's FILL_MODE can be Z486_FILL_BEAT (the -862 ALM
  // mode). Word N of the line becomes beat N, which is
  // byte-exact BY CONSTRUCTION: both L1s gather beat N into line word N (src/z486/
  // l1_icache.sv's patch_line_word(..., fill_count, ...)) and install a line response
  // as mem_line_dout unchanged, so the L1 sees the same 16 bytes either way.
  //   * The beats start one clk_sys after the line strobe and are back-to-back. The
  //     strobe is already one clk_sys after the route's accept (the responders' own
  //     accept-then-respond split), so the z486 pending counter (memory.sv: loaded at
  //     the accept, decremented per resp_valid) sees exactly four beats and retires.
  //   * NOTHING ELSE CAN INTERLEAVE: z486's ext fabric serializes reads (memory.sv's
  //     ext_direct_req/ext_dcache_req/ext_icache_req all gate on the pending counters),
  //     so no second request can be accepted while these beats stream, and no other
  //     responder can be mid-response. The sim guard below fails loudly if that
  //     assumption is ever broken rather than dropping a fill.
  //   * The map route needs no special case: its line form is provably never 1 (its
  //     local open-bus path is unreachable for reads and its other local_accept term is
  //     write-only), so every map fill is four word beats straight from the backend.
  //   * Cost: +4 clk_sys on a fill served by an on-chip window (the strobe becomes the
  //     capture and the last beat lands four cycles later) - the T22 trade the owner
  //     approved. No D$ path moves: its fills are RAM-only and already beats.
  //   * ONE WORD IS HELD, NOT THE LINE. Every routed line
  //     source still holds its line for the four beats - the window responder's
  //     `read_data` and pc9821_gvram_arb's `c_line_r` change only inside a READ walk,
  //     pc9821_pegc's `cpu_dout` only at a read's accept, and the open-bus/map forms are
  //     all ones (the map's line strobe needs `local_open_bus`: its other local_accept term,
  //     fw_write_blocked, is write-only) - and no read can be accepted while the beats run
  //     (the serialized fabric above). So the beat register loads word N of the latched
  //     route from its source one cycle ahead of beat N, which is the same word the 128-bit
  //     capture held. The CPU-facing path is unchanged: a register into the cpu_dout mux.
  //     The sim guard below holds the 128-bit capture as a shadow and fails on any beat
  //     that differs from it.
  localparam [1:0] LB_WIN = 2'd0, LB_GVRAM = 2'd1, LB_PEG = 2'd2, LB_ONES = 2'd3;
  reg  [31:0] line_beat_word_r;
  reg  [1:0]  line_beat_idx_r;
  reg  [1:0]  line_beat_src_r;
  reg         line_beat_active_r;
  // The route whose strobe this is, in cpu_line_dout's priority order (open and map are
  // both the all-ones line).
  wire [1:0]  line_src_now = win_cpu_line_resp_valid   ? LB_WIN :
                             gvram_cpu_line_resp_valid ? LB_GVRAM :
                             peg_cpu_line_resp_valid   ? LB_PEG : LB_ONES;
  // The word the beat register loads this cycle: word 0 of the strobing route at the
  // strobe, then word idx+1 of the latched route while the beats run.
  wire [1:0]  lb_src = line_beat_active_r ? line_beat_src_r : line_src_now;
  wire [1:0]  lb_idx = line_beat_active_r ? line_beat_idx_r + 2'd1 : 2'd0;
  wire [31:0] lb_next = (lb_src == LB_WIN)   ? win_cpu_line_dout[{lb_idx, 5'b00000} +: 32] :
                        (lb_src == LB_GVRAM) ? gvram_cpu_line_dout[{lb_idx, 5'b00000} +: 32] :
                        (lb_src == LB_PEG)   ? peg_cpu_dout : 32'hFFFF_FFFF;
  wire [31:0] line_beat_word = line_beat_word_r;
  always @(posedge clk) begin
    if (reset) begin
      line_beat_word_r <= 32'd0;
      line_beat_idx_r <= 2'd0;
      line_beat_src_r <= LB_WIN;
      line_beat_active_r <= 1'b0;
    end else if (line_beat_active_r) begin
      if (line_beat_idx_r == 2'd3) line_beat_active_r <= 1'b0;
      line_beat_idx_r <= line_beat_idx_r + 2'd1;
      line_beat_word_r <= lb_next;
    end else if (cpu_line_resp_valid) begin
      line_beat_word_r <= lb_next;
      line_beat_src_r <= line_src_now;
      line_beat_idx_r <= 2'd0;
      line_beat_active_r <= 1'b1;
    end
  end
  // synthesis translate_off
  // SIM-ONLY: the 128-bit capture the beat register replaced, as a shadow. Every beat must
  // present the word the capture would have (the routed sources hold their lines - above).
  reg [127:0] line_beat_shadow_r;
  always @(posedge clk) begin
    if (!reset && !line_beat_active_r && cpu_line_resp_valid) line_beat_shadow_r <= cpu_line_dout;
    if (!reset && line_beat_active_r &&
        line_beat_word_r != line_beat_shadow_r[{line_beat_idx_r, 5'b00000} +: 32])
      $fatal(1, "pc9821_memory_subsystem: line beat %0d presents %08x, the line held %08x",
             line_beat_idx_r, line_beat_word_r,
             line_beat_shadow_r[{line_beat_idx_r, 5'b00000} +: 32]);
  end
  // synthesis translate_on
  // synthesis translate_off
  // SIM-ONLY: a response arriving while the previous fill is still splitting would be
  // merged into its beat stream and lose a fill. The serialized fabric makes it
  // impossible; fail loudly instead of corrupting the L1's line (see the note above).
  always @(posedge clk) begin
    if (!reset && line_beat_active_r &&
        (cpu_line_resp_valid || reg_word_owns || map_cpu_resp_valid))
      $fatal(1, "pc9821_memory_subsystem: a second response while a line fill is still splitting into beats");
  end
  // synthesis translate_on

  assign cpu_resp_valid = line_beat_active_r || reg_word_owns || map_cpu_resp_valid;
  assign cpu_dout = line_beat_active_r ? line_beat_word :
                    reg_word_owns ?
                    (win_cpu_resp_valid ? win_cpu_dout :
                     gvram_cpu_resp_valid ? gvram_cpu_dout :
                     peg_cpu_resp_valid ? peg_cpu_dout : open_cpu_dout) :
                    map_cpu_dout;

  wire [31:0] load_pack_offset = load_addr - pack_base;
  // ONLY the 4 KiB ANK table is teed into M10K now (pc9821_gdc_text's u_ank). The JIS grid
  // is NOT loaded into block RAM any more: it stays in the pack's SDRAM copy at pack
  // 0x80000 + FONT.ROM byte, and the GDC's fmem reader fetches glyphs from there into its
  // The JIS region's bounds are named here because
  // tb_pc9821_gdc_text pins them against the pack.
  /* verilator lint_off UNUSEDPARAM */  // kept as the region's named bounds
  localparam [31:0] JIS_PACK_BASE  = 32'h0008_0000 + 32'h0000_1800;
  localparam [31:0] JIS_PACK_BYTES = 32'd92 * 32'h0C00;
  /* verilator lint_on UNUSEDPARAM */
  wire load_ank_word = (load_pack_offset >= 32'h0003_0000) &&
                       (load_pack_offset <  32'h0003_1000);
  wire load_upper_half = |load_be[3:2];
  // ANK word 0..2047; the loader's 32-bit beat carries two 16-bit words, so the high half
  // is the low word's address plus one. The range check bounds the offset, so [11:1] is the
  // whole word address and bit 0 of the slice is the byte select inside the word.
  /* verilator lint_off UNUSEDSIGNAL */   // the ANK range check bounds this to <0x1000
  wire [17:0] load_font_word_off = {7'd0, load_pack_offset[11:1]};
  /* verilator lint_on UNUSEDSIGNAL */
  assign font_addr = load_font_word_off + {17'd0, load_upper_half};
  assign font_data = load_upper_half ? load_din[31:16] : load_din[15:0];
  assign font_we = load_valid && load_ready && load_write && load_ank_word;

  // ==== THE LAUNCHED-OWNER LOCK (memmap-audit-ramroute P1-2) ====
  // The backend's ack is a raw one-cycle pulse not tagged to a requester
  // (sdram.v's registered ready pulse, through sdram_sync_bridge), and its payload is
  // BARE - the controller latches addr/din/be from this mux at its own accept -
  // so ONE owner must hold the mux from a request's presentation to its ack. The
  // old priority chain (`dma_owns = dma_valid && !loader_owns`) was free to move
  // inside that window: a dma_valid rising 1-3 clk_sys after a CPU request was
  // presented hijacked the in-flight payload, and the CPU's ack was consumed as
  // dma_ready - the DMAC advanced on an accept its byte never got (a dropped
  // floppy byte) and a read's response-route entry was never pushed, gating the
  // CPU's response off forever. The presenting owner is now TAGGED at the first
  // presentation cycle and the mux, the accepts and the payload follow the tag
  // until the ack. A FRESH presentation still takes the old priority (loader >
  // DMA > map): a transfer byte that is never accepted is a floppy read that
  // never completes, while a delayed CPU access is only a slower CPU - the same
  // trade real DMA makes when it steals cycles - and a contending DMA now waits
  // at most the one CPU request already in flight. The lock releases at the ack
  // or at a WITHDRAWAL: a presented request can come off the bus unaccepted (the
  // store buffer's rt_full withdrawal, pc9821_pegc_storebuf's pass_withdrawn),
  // whose own contract proves that window PRE-LAUNCH, so no ack is owed for it.
  // Pinned by tb_pc9821_dma_accept_steal - which models this launch/ack contract
  // deliberately WITHOUT the bridge's payload $fatal (sdram_sync_bridge.sv's requester check),
  // because that fatal aborts a hijack before the dropped byte is observable.
  localparam [1:0] OWN_LOAD = 2'd0, OWN_DMA = 2'd1, OWN_MAP = 2'd2;
  wire [1:0] owner_fresh = loader_owns ? OWN_LOAD
                        : (dma_valid ? OWN_DMA : OWN_MAP);
  reg  [1:0] owner_r;
  reg        owner_locked;
  wire [1:0] owner_sel = owner_locked ? owner_r : owner_fresh;
  wire owner_is_load = (owner_sel == OWN_LOAD);
  wire owner_is_dma  = (owner_sel == OWN_DMA);
  wire owner_is_map  = (owner_sel == OWN_MAP);
  always @(posedge clk) begin
    if (reset) begin
      owner_locked <= 1'b0;
      owner_r      <= OWN_MAP;
    end else if (mem_ready || !mem_valid) begin
      owner_locked <= 1'b0;
    end else if (!owner_locked) begin
      owner_locked <= 1'b1;
      owner_r      <= owner_fresh;
    end
  end

  assign load_ready = mem_ready && owner_is_load;
  // The mapper is told it was accepted only when it OWNED the request the backend just accepted.
  // With the GVRAM in M10K the only remaining port-0 owners are the loader and the
  // mapper; the loader is self-gated by loader_owns, so the mapper's accept is qualified by that
  // term alone -- and by the response-route queue's back-pressure (rt_full below): a mapped
  // read is REFUSED while three are already outstanding (review r2-buffers F2).
  // The DMA owner. It takes the backend AFTER the loader (a download owns the bus) and
  // BEFORE the mapper: a transfer byte that is never accepted is a floppy read that never
  // completes, while a delayed CPU access is only a slower CPU - the same trade real DMA
  // makes when it steals cycles. The controller asks for one byte at a time and returns to
  // idle between them, so the CPU is denied at most a few cycles per byte.
  wire dma_owns = owner_is_dma;
  assign dma_ready = mem_ready && dma_owns;
  // A write completes at the ACCEPT (the backend returns nothing for it); a READ's beat is
  // the response whose queue head is tagged DMA (rt_dma, below).
  wire   rt_head_dma    = rt_dma[rt_rd[1:0]];
  assign dma_resp_valid = mem_resp_valid && !loader_owns && !rt_empty && rt_head_dma;
  assign dma_dout       = mem_dout;

  // THE PEGC POSTED STORE BUFFER (trade-candidates T21). The mapper's backend arm feeds it; PEGC
  // packed/aperture STORES are posted here
  // (accepted in 1 clk, combined per dword, drained as full writes and adjacent pairs on
  // port 0's two-word write), everything else passes through unchanged, and a PEGC-route
  // read drains the buffer first so it cannot read behind buffered bytes. Its in_ready IS
  // the mapper's mem_ready: a post completes at the buffer, a passthrough completes at the
  // backend accept exactly as every map request did before. HOLD_CYCLES is the partial
  // tail's combining window derived from SYS_CLOCK_HZ (1 us - a time, not a cycle count,
  // so the residency bound does not move with the build profile).
  wire buf_mem_valid, buf_mem_write;
  wire [31:0] buf_mem_addr, buf_mem_din, buf_mem_din_hi;
  wire  [3:0] buf_mem_be;
  wire  [7:0] buf_mem_burstcount;
  wire        buf_mem_gath;
  wire [440:0] buf_mem_gath_extra;
  wire map_slot_ready = mem_ready && owner_is_map;
  wire map_peg_route  = peg_window || map_pegc_packed;
  // A postable store: the PEGC route's one-dword write (the CPU's stores are burstcount 1).
  wire map_peg_store  = map_peg_route && map_write && (map_burstcount[7:1] == 7'd0);

  pc9821_pegc_storebuf #(
      .HOLD_CYCLES(SYS_CLOCK_HZ / 1_000_000),
      .GATHER_K(GATHER_K)
  ) u_storebuf (
      .clk(clk), .reset(reset || !cpu_run),
      .in_valid(map_valid), .in_write(map_write),
      .in_addr(map_addr), .in_din(map_din), .in_be(map_be),
      .in_burstcount(map_burstcount),
      .in_peg_route(map_peg_route),
      .in_ready(map_ready),
      .in_rd_block(rt_full),
      .sdram_size(sdram_size),
      .mem_addr(buf_mem_addr), .mem_din(buf_mem_din), .mem_din_hi(buf_mem_din_hi),
      .mem_be(buf_mem_be), .mem_burstcount(buf_mem_burstcount),
      .mem_valid(buf_mem_valid), .mem_write(buf_mem_write),
      .mem_gath(buf_mem_gath), .mem_gath_extra(buf_mem_gath_extra),
      .mem_ready(map_slot_ready),
      /* verilator lint_off PINCONNECTEMPTY */   // busy is the bench's residency instrument
      .busy()
      /* verilator lint_on PINCONNECTEMPTY */
  );
  // The map slot's backend accept (the buffer's request, when the mux gives it the port).
  wire map_slot_accept = map_slot_ready && buf_mem_valid;

  // The response-route queue. The request mux priority and this record agree by construction: a
  // read accept can only be the mapper's (the loader writes), so there is no route to record.
  wire backend_accept = mem_ready && mem_valid;
  wire read_accept    = backend_accept && !mem_write;

  // The request mux is FROZEN from a request's presentation to its ack by the
  // launched-owner lock (above), so the launched route can no longer be robbed of
  // its accept; what is left to assert is the gating itself - that the accept the
  // backend delivers lands on exactly the route whose request it was - so a route
  // added to the mux without the lock's terms is caught here rather than by a
  // silently lost request. The payload's stability until the ready is asserted one
  // level down, in sdram_sync_bridge's requester-contract check.
`ifdef VERILATOR
  always @(posedge clk) begin
    // A POST accept is buffer-internal (no backend transaction), so it may share a cycle
    // with the loader's accept; only the passthrough form is a backend request.
    if ((load_ready ? 1 : 0) + ((map_ready && !map_peg_store) ? 1 : 0) > 1)
      $error("pc9821_memory_subsystem: two port-0 routes ready in one cycle");
    if (backend_accept && !(owner_is_load ? load_ready : (dma_owns ? dma_ready : map_slot_accept)))
      $error("pc9821_memory_subsystem: backend accepted a request no route was ready for");
  end
`endif
  wire resp_beat      = mem_resp_valid;
  wire [7:0] rt_owed  = (mem_burstcount == 8'd0) ? 8'd1 : mem_burstcount;
  assign rt_empty     = (rt_wr == rt_rd);
  // The backend answers a read with one resp_valid per dword (the bridge's word path,
  // `rt_owed` beats); the 128-bit line form has no producer in this build, so no line
  // pulse can retire a head early.
  wire head_done      = (rt_left == 8'd1);
  // THE BACK-PRESSURE (review r2-buffers F2). The queue is 4 slots addressed by 3-bit
  // pointers: a 4th unretired push aliases the unread head's slot and 8 alias rt_wr ==
  // rt_rd -- the queue reads EMPTY with 8 beats owed and map_accepted then GATES OFF the
  // delivered responses: a CPU deadlock. The queue therefore refuses a new accept at
  // three outstanding (the 4th push is held until rt_rd advances), which makes overflow
  // unreachable IN RTL rather than only asserted in simulation. The release is the
  // head's own retire (or a same-cycle retire below), so the stall is the shortest one:
  // one cycle after the freeing response beat, never a counter expiry.
  assign rt_full = ((rt_wr - rt_rd) == 3'd3) && !(resp_beat && !rt_empty && head_done);
  // When the head retires, the entry promoted is the one just queued if the queue held a
  // single entry AND this cycle's accept wrote the slot it now points at. Omitting the
  // accept term (a code/comment mismatch) left rt_left = rt_owed with an EMPTY queue, so
  // the next request's route was popped from under it and map_accepted gated its response
  // off -- the CPU waits forever.
  wire [7:0] rt_promote = (rt_wr == rt_rd + 3'd1)
                          ? (read_accept ? rt_owed : 8'd0)
                          : rt_beats[rt_rd[1:0] + 2'd1];

  always @(posedge clk) begin
    if (reset) begin
      rt_wr   <= 3'd0;
      rt_rd   <= 3'd0;
      rt_left <= 8'd0;
    end else begin
      if (read_accept) begin
        rt_beats[rt_wr[1:0]] <= rt_owed;
        rt_dma[rt_wr[1:0]]   <= owner_is_dma;
        rt_wr <= rt_wr + 3'd1;
      end
      if (resp_beat && !rt_empty && (rt_left != 8'd0)) begin
        if (head_done) begin
          rt_rd   <= rt_rd + 3'd1;
          rt_left <= rt_promote;
        end else begin
          rt_left <= rt_left - 8'd1;
        end
      end else if (read_accept && rt_empty) begin
        rt_left <= rt_owed;
      end
    end
  end

  // A gated top-window store is accepted here: from now on the shadow is the window's read
  // source (pc9821_memory_map fw_shadow_read), because it holds content the pack does not.
  always @(posedge clk) begin
    if (reset) fw_shadow_dirty <= 1'b0;
    else if (fw_shadow_store && map_valid && map_ready) fw_shadow_dirty <= 1'b1;
  end

  assign map_accepted = !rt_empty && !rt_head_dma;

  // Backend request mux. With the GVRAM in M10K the port-0 owners are the loader
  // (which takes the bus for its whole download) and the mapper's store buffer
  // (pc9821_pegc_storebuf: the posted PEGC drains and the passthrough requests). They
  // are gated so no two owners drive the bus at once -- the route-isolation assertions
  // below check exactly that.
  assign mem_addr = owner_is_load ? load_addr : (dma_owns ? dma_addr : buf_mem_addr);
  assign mem_din = owner_is_load ? load_din : (dma_owns ? dma_din : buf_mem_din);
  // The pair's second dword: only the buffer's two-word drain writes it (port 0's
  // WRITE_BURST path, sdram.v's din0_hi); every other owner has no second word.
  // Neither the loader (burstcount 1) nor the DMA (burstcount 0) asks for the two-word write, and the
  // controller reads din_hi only for a burstcount-2 non-gather write, so the buffer's word needs no
  // owner gating (sdram_sync_bridge's frozen-payload assertion qualifies it the same way).
  assign mem_din_hi = buf_mem_din_hi;
  // The gather session's qualifier and entries: the buffer's group drains only
  // (the loader and the DMA send ordinary requests).
  assign mem_gath = owner_is_load ? 1'b0 : (dma_owns ? 1'b0 : buf_mem_gath);
  // The controller reads entry j of the extras only for j < burstcount of a request whose mem_gath is
  // set (sdram.v's slot maps), and mem_gath above is already zero for the loader and the DMA, so the
  // buffer's slots pass ungated.
  assign mem_gath_extra = buf_mem_gath_extra;
  assign mem_be = owner_is_load ? load_be : (dma_owns ? dma_be : buf_mem_be);
  // One byte per DMA transaction: a burst count of 0 is one dword (the same convention
  // every other request in this file uses), and the DMAC's one-hot byte enable picks the
  // lane, exactly the shape the engine's own bench drives it with.
  assign mem_burstcount = owner_is_load ? load_burstcount :
                          (dma_owns ? 8'd0 : buf_mem_burstcount);
  // The map slot's requests are the buffer's: a passthrough request is not PRESENTED
  // while rt_full (the accept signal alone cannot refuse anything - backend_accept is
  // mem_valid && mem_ready - so the back-pressure has to gate the request itself), and a
  // posted store needs no presentation at all until its drain.
  // A DMA READ obeys the response queue's back-pressure exactly as the mapper's reads do
  // (rt_full, above): it owes a beat, so a fourth outstanding read must not be launched.
  assign mem_valid = owner_is_load ? load_valid :
                     (dma_owns ? (dma_valid && (dma_write || !rt_full)) : buf_mem_valid);
  assign mem_write = owner_is_load ? load_write : (dma_owns ? dma_write : buf_mem_write);

`ifdef VERILATOR
              // Route isolation is a core contract: local apertures, normal mapped memory, and the loader
              // must never accept or answer the same transaction together. THE RESPONDER CONTRACT, written
              // here because every route is muxed into this file:
              //  1. ACCEPT AND RESPOND IN SEPARATE CYCLES - assert cpu_ready, then cpu_resp_valid (or the
              //     line form) on a LATER cycle, never the same one, or z486 never clears its in-flight flag.
              //  2. THE LATENCY IS THE PEER'S BUSINESS - never assume how many cycles. The shared
              //     backend's header states T_RCD + CAS + 2*burst_cnt - 1 from ACT to last data
              //     (src/memory/sdram.v:21). So ANY state that records
              //     an accept and is later consumed by that accept's response MUST OUTLIVE THE ACCEPT, or it
              //     expires, the response is gated off, and the CPU waits forever for a completion that was
              //     delivered. The record is a QUEUE of owed response beats keyed by accept: a
              //     read accept pushes its beat count and the response beats pop it, so an early `ready` cannot steal it.
              //  3. NEVER wait for cpu_valid to drop to leave the accept/response state: z486 keeps the
              //     request up while finalizing the previous one, so waiting for the deassert deadlocks.
  always @(posedge clk) if (!reset) begin
    if ((tram_select && open_select) || (cg_win_select && open_select) ||
        (tram_select && cg_win_select) || (gvram_select && open_select) ||
        (gvram_select && tram_select) || (gvram_select && cg_win_select) ||
        (peg_reg_select && tram_select) || (peg_reg_select && cg_win_select) ||
        (peg_reg_select && open_select) || (peg_reg_select && gvram_select))
      $fatal(1, "PC9821 memory route overlap");
    if (read_accept && rt_full)
      $fatal(1, "PC9821 response-route queue overflow");   // second line only: rt_full refuses this in RTL
    // THE VALID-HOLD CONTRACT, WHY IT IS NOT ASSERTED HERE (audit M5). The queue's push is gated
    // on the LIVE mem_valid, so a requester that drops valid before the backend's ready loses its
    // owed beat and the response is then gated off by map_accepted -- a silent CPU hang. The
    // invariant that would catch it is `mem_resp_valid -> !rt_empty`, and it is deliberately NOT
    // asserted, for a measured reason rather than a preference: this tree's own benches make that
    // excursion. tb_pc9821_memory_subsystem's two stolen-answer checks pulse a backend completion
    // that no accepted read owns (t=3825000 ns: cpu=0x000A3FE0, tram_select=1, mem_valid=0,
    // rt_wr==rt_rd), and tb_pc9821_memmap_ref's per-address probes present mem_valid around the
    // backend model's REGISTERED ready (t=125000 ns: cpu=0x000F8000, mem_valid=1, mem_ready=0,
    // rt_wr==rt_rd - an answer for a request whose ready the subsystem never saw). Both are
    // stimulus, not defects, and both would fail an assertion. What IS true by construction is the
    // other half: the accept is `mem_ready && mem_valid`, so an accept cannot be seen without
    // mem_valid being high, and a read accept always pushes. The remaining half -- a requester
    // holding its valid from launch to ready -- is a property of z486, the loader, the PCM buffer,
    // the font reader and the GVRAM walk, each verified by hand in the audit (plus the bridge's
    // `pending`, which forbade a second launch on a port); the mechanically checkable part of it,
    // valid and the payload held until the ready, IS asserted in sdram_sync_bridge.sv.
    if (resp_beat && !rt_empty && rt_left == 8'd0)
      $fatal(1, "PC9821 response-route queue head underflow");   // second line only: the decrement holds at 0 in RTL
          // A route holding its request while another route owns the backend is ARBITRATION, not a
          // violation: the request mux picks one owner and the loser waits with no ready and no
          // response until it wins.
          //
          // What must never happen is a route being ACCEPTED while another owns the request being
          // served, because it would act on a completion that is not its own. The check below catches
          // that on a decode edit.
    if (map_valid && (tram_select || open_select || cg_win_select || gvram_select ||
                      peg_reg_select))
      $fatal(1, "PC9821 mapped backend active under another owner");
    if (map_ready && !map_peg_store && owner_is_load)
      $fatal(1, "PC9821 the mapper was accepted while the loader owned the backend");
      // (A POSTED store accept is buffer-internal - no backend transaction - so it is
      // deliberately not covered here: the buffer holds it until the loader releases.)
    if ((win_cpu_ready && open_cpu_ready) ||
        (win_cpu_ready && gvram_cpu_ready) ||
        (open_cpu_ready && gvram_cpu_ready) ||
        (win_cpu_ready && peg_cpu_ready) ||
        (open_cpu_ready && peg_cpu_ready) ||
        (gvram_cpu_ready && peg_cpu_ready) ||
        (win_cpu_ready && map_cpu_ready && map_valid) ||
        (open_cpu_ready && map_cpu_ready && map_valid) ||
        (gvram_cpu_ready && map_cpu_ready && map_valid) ||
        (peg_cpu_ready && map_cpu_ready && map_valid)) begin
      $display("RSP accept: win=%b open=%b gvram=%b peg=%b map_rdy=%b map_valid=%b",
               win_cpu_ready, open_cpu_ready, gvram_cpu_ready, peg_cpu_ready,
               map_cpu_ready, map_valid);
      $fatal(1, "PC9821 multiple memory routes accepted one request");
    end
    if ((win_cpu_resp_valid && open_cpu_resp_valid) ||
        (win_cpu_resp_valid && gvram_cpu_resp_valid) ||
        (open_cpu_resp_valid && gvram_cpu_resp_valid) ||
        (win_cpu_resp_valid && peg_cpu_resp_valid) ||
        (open_cpu_resp_valid && peg_cpu_resp_valid) ||
        (gvram_cpu_resp_valid && peg_cpu_resp_valid) ||
        (win_cpu_resp_valid && map_cpu_resp_valid) ||
        (open_cpu_resp_valid && map_cpu_resp_valid) ||
        (gvram_cpu_resp_valid && map_cpu_resp_valid) ||
        (peg_cpu_resp_valid && map_cpu_resp_valid) ||
        (win_cpu_line_resp_valid && open_cpu_line_resp_valid) ||
        (win_cpu_line_resp_valid && gvram_cpu_line_resp_valid) ||
        (open_cpu_line_resp_valid && gvram_cpu_line_resp_valid) ||
        (win_cpu_line_resp_valid && peg_cpu_line_resp_valid) ||
        (open_cpu_line_resp_valid && peg_cpu_line_resp_valid) ||
        (gvram_cpu_line_resp_valid && peg_cpu_line_resp_valid) ||
        (win_cpu_line_resp_valid && map_cpu_line_resp_valid) ||
        (open_cpu_line_resp_valid && map_cpu_line_resp_valid) ||
        (peg_cpu_line_resp_valid && map_cpu_line_resp_valid) ||
        // All ten pairs of the FIVE RESPONDERS are listed -- the TRAM bridge and the CG window
        // are one responder now (pc9821_window_responder) and the PEGC register file's route
        // is the fifth (win/open/gvram/peg/map), so two of the old route pairs are no longer
        // two signals and cannot be. The ADDRESS routes' own one-hot pair lists are the
        // route-overlap and map-under-owner checks above, which now name all C(6,2)=15 pairs
        // (tram/cg_win/open/gvram/peg_reg/map). tools/check_route_pairs.py fails if EITHER
        // set ever names fewer pairs than it should.
        (gvram_cpu_line_resp_valid && map_cpu_line_resp_valid)) begin
      // Name the contending owners rather than only the fact of contention: which
      // two routes answered says which route is at fault.
      $display("RSP word: win=%b open=%b gvram=%b map=%b  | line: win=%b open=%b gvram=%b map=%b",
               win_cpu_resp_valid, open_cpu_resp_valid,
               gvram_cpu_resp_valid, map_cpu_resp_valid,
               win_cpu_line_resp_valid, open_cpu_line_resp_valid,
               gvram_cpu_line_resp_valid, map_cpu_line_resp_valid);
      $display("RSP backend: mem_valid=%b map_valid=%b load_valid=%b loader_owns=%b mem_resp_valid=%b | cpu=%08x cpu_valid=%b selects tram%bcg%bgvram%bopen%b",
               mem_valid, map_valid, load_valid, loader_owns,
               mem_resp_valid, cpu_addr, cpu_valid, tram_select, cg_win_select,
               gvram_select, open_select);
      $fatal(1, "PC9821 multiple memory routes answered one request");
    end
    if (mem_valid && owner_is_load && !load_valid)
      $fatal(1, "PC9821 backend request without active loader request");
    if (mem_valid && owner_is_dma && !dma_valid)
      $fatal(1, "PC9821 backend request without active DMA request");
    if (mem_valid && owner_is_map && !buf_mem_valid)
      $fatal(1, "PC9821 backend request without active CPU request");
  end
`endif

  // Avoid unused-signal warnings while retaining diagnostics and assertions.
  wire _unused_ok = saw_download;

endmodule

`default_nettype wire

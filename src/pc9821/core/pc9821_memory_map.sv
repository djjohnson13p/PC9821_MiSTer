// Native z486 PC-9821 memory-address translator: it translates only the physical backend address,
// preserving z486's valid/ready and response protocols. Firmware-pack
// storage hides in the 1 MiB reserve above guest RAM. NOT MODELLED: writable firmware storage.

`default_nettype none

module pc9821_memory_map (
    // 32 KiB ROM-window state: the pack offset is chosen by bank_offset().
    input wire [3:0] top_bank,
    input wire ide_rom_enable,
      // 0x063C bits 1-0 (pc9821_iobus d8_bank): which ROM the 0xD8000 window shows.
    input wire [1:0] d8_bank,
      // The IDE option ROM's 8 KiB work-RAM visibility gate (port 0x1E8E bit 0,
      // latched in pc9821_iobus). With it clear, 0xDA000-0xDBFFF is the absent
      // area's own shape (see ide_workram below); with it set the window is
      // ordinary identity RAM.
    input wire ide_ram_gate,
      // 0x053D bit 1: with it clear the machine shows ROM and discards stores to the firmware windows.
    input wire bios_ram_gate,
      // 0x043F's 0x8 nibble (pc9821_iobus top_shadow_en): the writable shadow over
      // 0xF8000-0xFFFFF is enabled. See the fw_shadow_read use below.
    input wire top_shadow_en,
      // Set once a gated top-window store has landed in the shadow this power-on/OSD reset.
      // Until then the shadow's content is the pack's, so a read serves the pack -- which is
      // what keeps the ITF's SECOND ROM-sum pass (run after it enables the shadow) pristine.
    input wire fw_shadow_dirty,
      // The 32 KiB shadow store's base in the SDRAM reserve above the pack
      // (pc9821_memory_subsystem computes pack_base + PACK_BYTES + 0x58000).
    input wire [31:0] fw_shadow_base,
    // The EMS page window at 0xB0000-0xBFFFF (0x043F's 0x2 nibble). The machine has three
    // measured states: 0x20 = the identity (the ordinary VRAM planes), 0x22 =
    // the 64 KiB memory window (64 KiB of writable RAM - the ITF fills and verifies all
    // 0x4000 dwords of it, BANK4@0xF82C7-0xF8317), and any other 0x2x = unmapped. pc9821_iobus
    // encodes that as ems_state 0/1/2: only state 1 leaves the planes and takes the page
    // (see ems_page_base), and state 2 is routed to the open-bus responder by the subsystem.
    input wire [1:0]  ems_state,
    // Where the 0x22 state's 64 KiB page lives in the backend (see pc9821_memory_subsystem).
    input wire [31:0] ems_page_base,
      // 0x0461: the base of the movable 128 KiB window at 0x80000-0x9FFFF, as a PAGE NUMBER.
    input wire [7:0] win0_sel,

      // Runtime memory sizing: the 1 MiB firmware reserve sits directly above the guest RAM.
    input wire [31:0] pack_base,
    input wire [31:0] guest_ram_bytes,

      // The PEGC extended-VRAM window: 0xF00000-0xF7FFFF when 0x043B's 15-16 MiB hole is on, and
      // the SDRAM base it lives at. Decoded in pc9821_memory_subsystem because that is
      // where sys16m_en lives; served here so the access takes the ordinary backend route.
    input wire        peg_window,
    input wire [31:0] peg_base,

    // THE PEGC 256-COLOUR WINDOW ARMS. `pegc_256` is
    // the 0x6A dat 0x21 select (pc9821_crtc's mode2_256col), and while it is set the
    // four first-MiB graphics windows are NOT the planar planes - NP2kai installs its
    // memvga handlers over 0xA8000/0xB0000/0xB8000/0xE0000 whenever VOPBIT_VGA is set
    // (i386c/cpumem.c), shadowing the planar windows AND the EMS overlay entirely:
    //   0xA8000-0xAFFFF -> the packed store at {bank_a, offset[14:0]}
    //   0xB0000-0xB7FFF -> the packed store at {bank_b, offset[14:0]}
    //   0xB8000-0xBFFFF -> not connected (NP2kai memnc_*; the open-bus responder)
    //   0xE0000-0xE7FFF -> the PEGC register file (NP2kai memvgaio_*; pc9821_pegc)
    // With `pegc_plane` set (0xE0100 bit 0) the two packed windows belong to the
    // plane engine instead - ladder rung L3, deliberately NOT built, so they read
    // open bus here rather than silently corrupting the packed store. The bank
    // registers and the mode come from the register file (pc9821_pegc).
    input wire        pegc_256,
    input wire        pegc_plane,
    input wire [3:0]  pegc_bank_a,
    input wire [3:0]  pegc_bank_b,
    // The map's decode of those three arms, for the subsystem's route selects:
    // pegc_packed takes the ordinary backend route below, pegc_reg_win routes to
    // the register file's responder, pegc_nc to the registered open-bus one.
    output wire        pegc_packed,
    output wire        pegc_reg_win,
    output wire        pegc_nc,

            // Graphics VRAM sits directly above the 1 MiB firmware reserve; 0xA6 selects the page.

                // The plane-window decode, exported for the EGC route: which window the address hit and its
                // in-plane offset, so a consumer may gate this block's cpu_valid without a loop.
    output wire        gvram_window,
    output wire [1:0]  gvram_win_plane,
    output wire [14:0] gvram_win_offset,

    // z486/native requester
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_din,
    output wire [31:0] cpu_dout,
    output wire [127:0] cpu_line_dout,
    input  wire [3:0]  cpu_be,
    input  wire [7:0]  cpu_burstcount,
    input  wire        cpu_line_read,
    input  wire        cpu_valid,
    input  wire        cpu_write,
    output wire        cpu_ready,
    output wire        cpu_resp_valid,
    output wire        cpu_line_resp_valid,

                // Asserted for the absent ROM area so the subsystem routes it away; this block does not serve it.
    output wire        absent_area,
    // Asserted for the EMS window's measured unmapped state (0x2x other than 0x20/0x22) so
    // the subsystem routes it to the registered open-bus responder, exactly as absent_area
    // is. Decoded here, on the same post-window-0 address every other region uses, so the
    // two cannot disagree about which addresses the window covers.
    output wire        ems_open_bus,
    // A store to the 0xF8000-0xFFFFF shadow is in flight this cycle. The subsystem sets
    // fw_shadow_dirty on its accept, which is what turns the shadow into the window's read
    // source from then on (see pc9821_memory_subsystem).
    output wire        fw_shadow_store,

    // Guest-memory backend
    output wire [31:0] mem_addr,
    output wire [31:0] mem_din,
    input  wire [31:0] mem_dout,
    output wire [3:0]  mem_be,
    output wire [7:0]  mem_burstcount,
    output wire        mem_valid,
    output wire        mem_write,
    input  wire        mem_ready,
    input  wire        mem_resp_valid
);

            // Window 0: 0x80000-0x9FFFF is a 128 KiB alias of the RAM page (value & 0xFE) * 0x10000. 0x08 is
            // the identity, 0x0E points at 0xE0000-0xFFFFF, 0x0C at 0xC0000-0xDFFFF, bit 0 is ignored, and
            // read-back is value|1. BIAS IS APPLIED PRE-DECODE so each region below keeps one comparison:
            // the ITF's 0x9800<-0xF800 copy after 0x461=0x0E needs 0x80000+x == 0xE0000+x.
  // The membership test is a BIT SLICE, not the 32-bit range compare it reads as: [0x80000,0x9FFFF]
  // is exactly "the address is in the first MiB (bits [31:20] all zero) and bits [19:17] are 100",
  // because bit 16 is free inside the window. Bit-equal for every 32-bit input, so the standalone
  // bench's boundaries and its win0 0x00/0x0E/0x10 cases are unchanged. This is the same slice
  // identity the plane windows below already use, and it is on the design's worst 50 MHz cone:
  // the two magnitude compares left a LessThan chain between the CPU address and win0_moved.
  wire        win0_in_window = !(|cpu_addr[31:20]) && (cpu_addr[19:17] == 3'b100);
  wire        win0_moved = win0_in_window && (win0_sel != 8'h08);
  // The bias add is a bit splice, not a carry chain: inside the window cpu_addr - 0x80000 is
  // exactly cpu_addr[16:0], and win0_sel << 16 lands the page in [23:16], so the 32-bit
  // `cpu_addr + {8'd0,win0_sel,16'd0} - 0x80000` is a 9-bit add over a wired-through low half.
  // win0_sel[0] is always 0 (pc9821_iobus masks 0xFE); the cpu_addr[16] carry term keeps the
  // odd-value arithmetic identical anyway. The carry chain it replaces was 2.3 ns of
  wire [8:0] win0_hi = {1'b0, win0_sel} + {8'd0, cpu_addr[16]};
  wire [31:0] d_addr = win0_moved ? {7'd0, win0_hi, cpu_addr[15:0]} : cpu_addr;

        // Only the 8 KiB option ROM is a window; 0xDA000-0xDBFFF stays identity RAM because the authentic
        // IDE BIOS keeps its private 8 KiB work RAM there, gated by 0x1E8E -- and that gate is decoded
        // below (ide_workram): the work RAM is RAM only while it is connected. 0xDC000-0xDFFFF is
        // the FF-always tail decoded below (ide_worktail).
  // EVERY FIRST-MiB WINDOW HERE IS A BIT SLICE, NOT THE 32-BIT RANGE COMPARE IT READS AS, for the
  // same reason the plane windows below are: a window inside the first MiB is "the 64 KiB block
  // d_addr[19:16] is one of the window's blocks and d_addr[31:20] is zero", with bit 15 choosing
  // the half where the window is half a block. Each identity below is bit-equal for EVERY 32-bit
  // input, not only the first-MiB ones the guest can present (checked exhaustively below 2^20 and
  // over every high prefix), so the standalone bench's boundary and out-of-range cases are
  // unchanged. The magnitude compares left a carry chain feeding the d_addr mux, which is the
  // shape the plane-window slices below already replaced.
  //   0xD8000-0xD9FFF = block D with bit 15 set (the 8 KiB option-ROM window)
  //   0xE8000-0xF7FFF = block E with bit 15 set, or block F with it clear
  //   0xF8000-0xFFFFF = block F with bit 15 set
  // THE 0x063C BANK SELECT. Bits 1-0 = 1 or 3 replace the IDE option ROM and its work RAM
  // across 0xD8000-0xDBFFF with one 16 KiB half of BANK0.BIN (the pack's extended ROM bank 0
  // at +0x31000): select 1 shows 0x0000-0x3FFF, select 3 shows 0x4000-0x7FFF; selects 0 and 2
  // are the IDE option ROM. Measured: docs/probes/D8BANK-XE10.TXT (each select's 32 KiB
  // dumped on the Xe10 and matched byte for byte against the owner's BANK0/BANK3; the
  // 0xDC000 half reads 0xFF for every select). The Xe10 BIOS's INT 1Fh AH=CEh path selects 1
  // and far-returns into D800:0018, which EMM386 reaches during its initialisation; showing
  // the IDE ROM there instead hung MS-DOS 6.2 EMM386's boot. ASSUMPTION: the alternate banks
  // share the IDE ROM's 0x053D gate (ide_rom_enable); the capture was taken with it open.
  wire d8_alt = ide_rom_enable && d8_bank[0];
  wire d8_alt_window = d8_alt && !(|d_addr[31:20]) &&
                       (d_addr[19:16] == 4'hD) && (d_addr[15:14] == 2'b10);
  wire ide_rom_window = ide_rom_enable && !d8_bank[0] && !(|d_addr[31:20]) &&
                        (d_addr[19:16] == 4'hD) && (d_addr[15:13] == 3'b100);
  wire bios_lower = !(|d_addr[31:20]) &&
                    (&d_addr[19:17]) && (d_addr[15] != d_addr[16]);
  wire fw_low = !(|d_addr[31:20]) && (&d_addr[19:16]) && d_addr[15];
  // 0xFFFF8000-0xFFFFFFFF is "every bit from 15 upward": the top-of-4G ROM alias.
  wire fw_high = &d_addr[31:15];
  wire fw_window = fw_low || fw_high;
        // Out-of-range completion lives here as well as in the subsystem's pc9821_open_bus responder:
        // tb_pc9821_memory_map expects 0xFFFF_FFFF here, and the two cannot both accept.
        // The bound is tested on the BIASSED address (aliases.md A6): d_addr is the address
        // the backend would serve, so a window-0 target past guest RAM (or past where its
        // direct encoding is RAM) is open bus here exactly as its direct encoding is. Testing
        // cpu_addr let the overlay's 0x80000-0x9FFFF reach ordinary SDRAM at a target where
        // the direct encoding serves open bus (or PEGC EVRAM). The fw_high guard moves with
        // it because fw_high is decoded on d_addr too; for every access the two agree except
        // through the window-0 bias, which can never land on fw_high.
  wire out_of_range = (d_addr >= guest_ram_bytes) &&
                      !(d_addr >= 32'hFFFF_8000) && !peg_window;
  wire local_open_bus = out_of_range && cpu_valid;   // the EMS window's unmapped state is answered by the registered
                                                      // open-bus responder, not here (see pc9821_memory_subsystem)


  wire [14:0] fw_offset = d_addr[14:0];

            // ================= ABSENT ROM AREA: 0xC0000-0xD7FFF ======================
            // Owner: 0xFF throughout, and stores discarded. Decoded on d_addr and left
            // UNCLAIMED, not identity RAM: the BIOS's option-ROM scan walks this range and absent != 0xAA55.
            // ONE 16 KiB OF IT IS NOT ABSENT ON THE MACHINE: the fitted PC-9801-86 banks its 16 KiB
            // SOUND.ROM at 0xCC000-0xCFFFF, and the machine answers real code there - the +C000..+F800
            // rows of docs/probes/SHADOW.TXT:150-199 hold it and every other 2 KiB block of the area
            // reads 0xFF (ffblocks=0028 of blocks=0030). That window is decoded below
            // (sound_rom_window, the PC-9801-86 SOUND.ROM) and carved out of this area; the rest stays absent.
  // 0xC0000-0xD7FFF is block C anywhere, or block D with bit 15 clear (see the slice note above).
            // ================= THE PC-9801-86 SOUND.ROM WINDOW: 0xCC000-0xCFFFF =================
            // The fitted -86 card banks its 16 KiB option ROM here and the machine answers real
            // code: docs/probes/SHADOW.TXT:150-199 samples all eight 2 KiB blocks of the window and
            // every sampled byte matches the owner's bios/xe10/SOUND.ROM dump (sha256 f05b508d...;
            // the +C000 row's 06 1E 56 57 55 53 16 1F is SOUND.ROM[0x0000]), so the dump IS the
            // window's content. Read-only like every ROM window: a store is dropped. Served from
            // the pack's SOUND.ROM region (tools/pack_layout.py SOUND_OFFSET); a pack built
            // without the image is 0xFF there, i.e. the "no card fitted" answer. This is item
            // 96, implemented once the owner's dump made the window modelable (2026-09-28).
  wire sound_rom_window = !(|d_addr[31:20]) && (d_addr[19:16] == 4'hC) &&
                          d_addr[15] && d_addr[14];
            // ================= THE 0x1E8E-GATED IDE WORK RAM: 0xDA000-0xDBFFF ======================
            // The IDE option ROM keeps its private 8 KiB work RAM at D800:2000+ (BANK3@0x0B40
            // sets ES=0xD800 and its state tables land at 0xDA066-0xDA2xx), and the machine can
            // DISCONNECT it: with port 0x1E8E bit 0 clear the window reads 0xFF and drops stores,
            // with it set the same address is the work RAM again -- measured end to end by
            // docs/probes/SHADOWW.TXT:226-231 (the 1E8E read-back runs FE FF FE through the
            // probe's 0x80/0x81/restore writes; its DA000 marker reads back FFFF under 0x80 and
            // 5AA5 under 0x81; the IDE ROM's own work bytes reappear under 0x81, so the RAM
            // SURVIVES the disconnect and only its visibility is gated). Gate-off is exactly the
            // absent area's shape (all ones, stores discarded), so it takes the same route: this
            // is what an EMM386 C0000-DFFFF region scan sees on the machine, and why the scan can
            // never claim the IDE ROM's work area as UMB (the failing-boot mechanism this fixes;
            // its causal link to the freeze is PLAUSIBLE, not proven -- the owner's hardware
            // boot-test is the proof). The 8 KiB extent follows QEMU's non-PCI machine class
            // (hw/i386/pc98-mem.c:1427-1433 "its work RAM is paged in at 0xda000"); NP2kai's
            // comment says the same although its page mask 0x1c00 would also cover DC000
            // (cbus/ideio.c:1478-1495). DC000-DFFFF is NOT gated RAM at all: it is the
            // FF-always tail decoded below (ide_worktail).
            // Block D with bit 15 set is the D8000-DFFFF window; bit 14 splits its RAM half
            // (DA000-DBFFF, bit 13 set) from the option-ROM window (D8000-D9FFF) and from
            // the FF-always tail (DC000-DFFFF).
  wire ide_workram = !d8_alt && !(|d_addr[31:20]) && d_addr[19] && d_addr[18] && !d_addr[17] &&
                     d_addr[16] && d_addr[15] && !d_addr[14] && d_addr[13];
            // ================ end the 0x1E8E-gated IDE work RAM ================================

            // ================= THE FF-ALWAYS TAIL: 0xDC000-0xDFFFF ==========================
            // The 16 KiB above the work RAM answers all ones and swallows stores in BOTH
            // gate states. Measured: docs/probes/SHADOW.TXT:201-213 reads 0xFF over all 12 x
            // 2 KiB blocks of the DA000..DFFFF region with the gate clear (`summary:
            // blocks=000C bytes=00006000 ... ffblocks=000C`), and QEMU models the rest of the
            // 0xD8000 window as rom_empty - a 0xFF fill with only the 8 KiB ide_ram overlaid
            // at 0xDA000 (hw/i386/pc98-mem.c d8000_rom; NP2kai's 12 KiB gate mask 0x1c00 is
            // the outlier). The tail's gate-ON state is capture-pending: one marker write at
            // 0xDC000 under 0x1E8E=0x81 settles it (probe2 /IDEGATE, item 34); the QEMU shape
            // is what is modelled until that capture lands.
  wire ide_worktail = !(|d_addr[31:20]) && d_addr[19] && d_addr[18] && !d_addr[17] &&
                      d_addr[16] && d_addr[15] && d_addr[14];
            // ================ end the FF-always tail ====================================
  assign absent_area = (!(|d_addr[31:20]) && d_addr[19] && d_addr[18] && !d_addr[17] &&
                        (!d_addr[16] || !d_addr[15]) && !sound_rom_window) ||
                       (ide_workram && !ide_ram_gate) || ide_worktail;
  // ================ end absent ROM area ===================================

                  // Graphics VRAM: 0xA8000-0xBFFFF holds planes B/R/G as three contiguous 32 KiB windows; the
                  // intensity window at 0xE0000 is separate (0xD0000 is the option ROM's). This file only DECODES
                  // them - pc9821_gvram owns the planes and takes {page, plane_offset}.
  wire [19:0] gvram_low    = d_addr[19:0];
  // The PEGC window arms' membership tests are the same nibble slices the plane
  // decodes use: A8000-AFFFF is nibble A with bit 15 set, B0000-B7FFF nibble B with
  // bit 15 clear, B8000-BFFFF nibble B with bit 15 set, E0000-E7FFF nibble E with
  // bit 15 clear - each inside the first MiB (`peg_first`). The packed bank splice is
  // NP2kai's VGARD8: physical offset = {bank, window offset[14:0]} (mem/memvga.c
  // `(mio1[p*2] & 15) << 15`, and MAME pegc_mmio_map's `bank * 0x4000` words).
  wire        peg_first = !(|d_addr[31:20]);
  wire        peg_a8    = (gvram_low[19:16] == 4'hA) && gvram_low[15];
  wire        peg_b0    = (gvram_low[19:16] == 4'hB) && !gvram_low[15];
  wire        peg_b8    = (gvram_low[19:16] == 4'hB) && gvram_low[15];
  wire        peg_e0    = (gvram_low[19:16] == 4'hE) && !gvram_low[15];
  assign      pegc_packed  = peg_first && pegc_256 && !pegc_plane && (peg_a8 || peg_b0);
  assign      pegc_reg_win = peg_first && pegc_256 && peg_e0;
  assign      pegc_nc      = peg_first && pegc_256 &&
                             (peg_b8 || ((peg_a8 || peg_b0) && pegc_plane));
  // The EMS window is a first-MiB aperture exactly as the plane windows are, so it carries
  // the same `!|d_addr[31:20]` guard: without it a guest store to e.g. 0x2B0000 would be
  // swallowed by the window whenever the guest left the 0x22 state selected.
  // The three window decodes are NIBBLE EQUALITIES, written out of the 20-bit range
  // compares they are: [B0000,BFFFF] is exactly gvram_low[19:16]==B (a 64 KiB aligned
  // block); [A8000,BFFFF] is nibble B plus the half-block nibble A with bit 15 set
  // (A8000-AFFFF); [E0000,E7FFF] is nibble E with bit 15 clear. Each identity holds for
  // every 20-bit value, and taking them as one-LUT slice functions lets the d_addr/win0 mux
  // feed the decode directly instead of through the wide comparators (the lightoc fit's
  // worst path carried LessThan8/ems_in_window here). tb_pc9821_gvram_porta_equiv pins the
  // stream through the aliases and the EMS-shaded silence.
  // In 256-colour mode the packed arms above shadow the EMS overlay entirely
  // (NP2kai's memvga handlers take every slot when VOPBIT_VGA is set - cpumem.c),
  // so `ems_in_window` is gated on !pegc_256 and cannot claim 0xB0000-0xBFFFF.
  wire        ems_in_window = (gvram_low[19:16] == 4'hB) &&
                              !(|d_addr[31:20]) && !pegc_256;
  wire        ems_page    = ems_in_window && (ems_state == 2'd1);
  wire        ems_unmapped = ems_in_window && (ems_state == 2'd2);
  wire        ems_shadow  = ems_in_window && (ems_state != 2'd0);
  assign ems_open_bus = ems_unmapped;
  wire        gvram_contig = ((gvram_low[19:16] == 4'hB) ||
                              ((gvram_low[19:16] == 4'hA) && gvram_low[15])) &&
                             !ems_shadow;
  wire        gvram_inten  = (gvram_low[19:16] == 4'hE) && !gvram_low[15];
              // The plane windows exist only in the first MiB, and the guard is on d_addr - the address the
              // decoders see: with window 0 moved, a guest address can translate to a page whose low 20 bits
              // look like a plane window (0x461 = 0x7F lands on RAM at 0x7E0000). In 256-colour mode the
              // whole plane set is shadowed by the PEGC arms above (NP2kai's memvga handlers), so
              // gvram_window is gated on !pegc_256; the GRCG/EGC see no window access there, which is
              // exactly the references' dispatch (qemu pc98-vga.c's MODE2_256COLOR arm comes before
              // grcg_mem_readb/egc_mem_readb).
  assign      gvram_window = (gvram_contig || gvram_inten) &&
                             !(|d_addr[31:20]) && !pegc_256;

              // The plane index is the window number: 0xA8000 >> 15 is 21, low two bits 1, hence the -1. The
              // in-plane offset is the address's low 15 bits - each window is one 32 KiB plane.
  assign gvram_win_plane  = gvram_contig ? (gvram_low[16:15] - 2'd1) : 2'd3;
  assign gvram_win_offset = gvram_low[14:0];

                      // Pack offset of the 32 KiB window at 0xF8000-0xFFFFF. Bank roles follow qemu-pc98's enum - 0 PCI,
                      // 1 APIC, 2 BASIC, 3 IDE option ROM, 4 ITF, 5..7 the 96 KiB main BIOS - which is the layout the
                      // firmware assumes; bank 4 is the reset-vector ITF, so banking away and back reaches the rest.
  function automatic [31:0] bank_offset(input [3:0] state);
    case (state)
      4'd0: bank_offset = 32'h0003_1000;
      4'd1: bank_offset = 32'h0003_9000;
      4'd2: bank_offset = 32'h0004_1000;
      4'd3: bank_offset = 32'h0007_0000;   // IDE option ROM slot
      4'd4: bank_offset = 32'h0000_0000;   // ITF slot, bank 4 of the ROM set
      4'd5: bank_offset = 32'h0001_0000;   // main BIOS, first half
      4'd6: bank_offset = 32'h0001_8000;   // main BIOS, second half
      4'd7: bank_offset = 32'h0002_0000;   // main BIOS top: the default window
      4'd8: bank_offset = 32'h0000_0000;   // BANK_ITF (0x043D)
      4'd9: bank_offset = 32'h0002_0000;   // BANK_BIOS_TOP (0x043D)
      default: bank_offset = 32'h0000_0000;
    endcase
  endfunction

                                  // The 8 KiB option-ROM window offset is cpu_addr[12:0], mapping to pack 0x70000.
                                  // THE WRITABLE TOP-WINDOW SHADOW.
                                  // 0xF8000-0xFFFFF has two layers: the selected pack bank and a writable shadow in
                                  // the SDRAM reserve above the pack. The ITF STORES its candidate-drive bitmap at
                                  // 0xF8E90 while the shadow is enabled and the IDE option ROM READS it back under
                                  // the BIOS-top bank, so both must meet in one byte or the BIOS falls to ROM BASIC.
                                  // The gated STORE goes to the SHADOW, never the pack: a store into the pack is what
                                  // an OSD reset carried into the next boot's ROM sum. The READ serves
                                  // the shadow only while it is both enabled and already written since reset; before
                                  // the first store the shadow's content IS the pack's, so the map reads the pack --
                                  // which is what keeps the sum's second pass (run after 0x043F=0x80, BANK4@0x1D2) on
                                  // pristine ROM instead of the previous boot's stored byte.
  assign fw_shadow_store  = fw_window && cpu_write && bios_ram_gate;
  // The writable shadow backs the BIOS-TOP bank ONLY. QEMU's mem_apply_top_bank
  // (qemu-pc98 hw/i386/pc98-mem.c) enables f8000_ram exactly when
  // `top_bank == BANK_BIOS_TOP && bios_ram_gate`, and only then does the window
  // read RAM instead of ROM. This core reaches that same content as top_bank 7
  // (0x043F's 0xE nibble, bank_offset 0x20000) or 9 (BANK_BIOS_TOP, 0x043D), so
  // the read is gated on those. Reading the shadow for EVERY bank is a defect:
  // the ITF executes its OWN bank (bank 8) out of 0xF8000, so the instant its
  // drive-bitmap store set fw_shadow_dirty the window started serving the
  // BIOS-top bank's bytes where the ITF's own code belongs. The fetch at
  // physical 0xF9A10 then decoded as a memory-operand transfer to 0000:0000 and
  // the CPU ran away in low RAM (s5; the site is NOT the jmp 0:0).
  wire   fw_bios_top_visible = (top_bank == 4'd7) || (top_bank == 4'd9);
  wire   fw_shadow_read   = fw_window && !cpu_write && top_shadow_en &&
                            fw_shadow_dirty && fw_bios_top_visible;
  wire   fw_shadow_access = fw_shadow_store || fw_shadow_read;
  wire [31:0] peg_bank_off = {13'd0,
                              (peg_b0 ? pegc_bank_b : pegc_bank_a), gvram_low[14:0]};
  assign mem_addr = peg_window ? peg_base + (d_addr - 32'h00F0_0000) :
                    pegc_packed ? peg_base + peg_bank_off :
                    ide_rom_window ? pack_base + 32'h0007_0000 +
                                {19'd0, d_addr[12:0]} :
                    d8_alt_window ? pack_base + 32'h0003_1000 +
                                {17'd0, d8_bank[1], d_addr[13:0]} :
                    sound_rom_window ? pack_base + 32'h000C_6800 +
                                {18'd0, d_addr[13:0]} :
                    ems_page   ? ems_page_base + {16'd0, gvram_low[15:0]} :
                    bios_lower ? pack_base + 32'h0001_0000 +
                                (d_addr - 32'h000E_8000) :
                    fw_window  ? (fw_shadow_access ? fw_shadow_base
                                                   : pack_base + bank_offset(top_bank)) +
                                {17'd0, fw_offset} :
                                 d_addr;

  assign mem_din = cpu_din;
  assign mem_be = cpu_be;
  assign mem_burstcount = cpu_burstcount;
                              // Firmware-window stores are shadow-RAM writes and exist only while 0x053D bit 1 is set; with it
                              // clear the machine shows ROM and discards the store, so accepting every store let a guest
                              // overwrite the ITF bank - including the reset vector the warm boot re-enters.
                              //
                              // THE ROM PACK IS READ-ONLY, and only the 0xF8000-0xFFFFF window has a writable layer here to
                              // absorb a store: the shadow (fw_shadow_store above), whose store stays gated by
                              // 0x053D bit 1 the way the machine's bios_ram_gate is. The 0xE8000-0xF7FFF main BIOS, the
                              // 0xD8000-0xD9FFF option-ROM window and the 0xCC000-0xCFFFF SOUND.ROM window have NO writable layer - their only backing is the pack -
                              // so a store into either is REJECTED whatever the gate says. NP2kai discards exactly those
                              // stores (cpumem.c:135 memnc_wr8 is `(void)address; (void)value`, and it is the write handler
                              // on both windows: cpumem.c:225 memfn0.wr8[0xe8000>>15]/[0xf8000>>15], :269 mmaptbl bwr8),
                              // and qemu-pc98's 0xd8000 ide_rom is a plain ROM alias.
  wire rom_pack_write = (bios_lower || ide_rom_window || d8_alt_window || sound_rom_window) && cpu_write;
  // The store into the window that DOES have a writable layer: the shadow absorbs it, and only 0x053D bit 1
  // opens that gate. With the gate clear the machine shows ROM and discards the store, which is what stops a
  // guest from overwriting the ITF bank the warm boot re-enters with.
  wire fw_shadow_write  = fw_window && cpu_write;
  wire fw_write_blocked = rom_pack_write || (fw_shadow_write && !bios_ram_gate);
              // No backend request is issued for the absent ROM area, so mem_addr is a don't-care there.
  assign mem_valid = cpu_valid && !out_of_range && !fw_write_blocked &&
                     !absent_area && !ems_unmapped;
  assign mem_write = cpu_write;

                              // z486's direct/uncached window covers the first absent 32 MiB range, so sizing writes cannot
                              // survive only in L1 and masquerade as physical RAM. mem_resp_valid is the SHARED backend's
                              // completion and arrives AFTER the accept, several cycles later, by which time the CPU has
                              // dropped cpu_valid - so gating it on cpu_valid discards a legitimate response and hangs the
                              // guest. It is gated by `map_accepted`, and that record must OUTLIVE the accept (p0-reset-fix).
  wire local_accept = local_open_bus || fw_write_blocked;
  assign cpu_ready = (local_accept ? 1'b1 : mem_ready);
  assign cpu_dout = local_open_bus ? 32'hFFFF_FFFF : mem_dout;
  assign cpu_line_dout = local_open_bus ? {4{32'hFFFF_FFFF}} : 128'd0;
  assign cpu_resp_valid = mem_resp_valid ||
                          (cpu_valid && local_accept && !cpu_write && !cpu_line_read);
  assign cpu_line_resp_valid = cpu_valid && local_accept && !cpu_write && cpu_line_read;

endmodule

`default_nettype wire

// PC-9821 GRCG (Graphic Charger): the four-plane GVRAM fill/compare engine.
// 0x7C = mode, 0x7E = the next of four tile bytes B,R,G,E (a 0x7C write resets the
// pointer). Mode bits 3:0 are the active-LOW plane enable (0=B,1=R,2=G,3=E); bit 7
// makes the GRCG own GVRAM. bit 7 set + bit 6 clear = TDW (stores, the CPU datum is
// ignored, every enabled plane gets its tile byte) and TCR (reads: per byte
// ~(OR over enabled planes of (plane_byte ^ tile_byte)), window-independent - NP2kai
// vacctbl sends mode 0x80 reads to memtcr0/1_rd*). bit 7 set + bit 6 set = RMW
// (stores, (old & ~data)|(tile & data)); reads in 0xC0 are plain. bits 5:4 ("GDC
// with GRCG") are STORED BUT NOT IMPLEMENTED: there is no GDC2 engine to affect.
//
// The four plane windows are 0x8000 apart and an access through ANY of them aliases to
// ALL FOUR planes at the same 15-bit offset, so a store or a TCR read is
// window-independent (master.lib's graph_clear arms TDW and rep stosw's through BLUE).
//
// EVERY CPU word is ONE client visit: the client resolves every enabled lane.

`default_nettype none

module pc9821_grcg (
    input wire clk,
    input wire reset,

    // Register write port, driven from the pc9821_iobus device bus. 0x7C is the
    // mode and resets the tile pointer; 0x7E is the next of four tile bytes
    // B,R,G,E. The 0x7C READ is NOT answered from `mode_r` any more: the port is
    // WRITE-ONLY on the machine and its byte read is open bus 0xFF (probe2
    // /RDBACK wrote 0x5A and read FF anyway, docs/probes/RDBACK.TXT:152).
    // NP2kai's crtc_i7c returns grcg.modereg (io/crtc.c:46-50, the behaviour the
    // iobus-tram review adjudicated as F2) and is the weaker source; the earlier
    // reading of one as-found 0xFF byte as "the write-only model also produces it
    // when modereg holds 0xFF" is refuted by that post-write read.
    // A WORD read at 0x7C answers 0x00FF - NP2kai's TERM_MINUS zero-extends the
    // 16-bit IN and never fetches 0x7D (io/iocore16.tbl:23-26, io/iocore.c:781-782),
    // so lane 1 is 0x00, and lane 0 is the 0xFF byte read above (the word form was
    // never machine-measured - TODO item 42). 0x7E is NOT in that table, so a word read at 0x7E
    // byte-splits and its high byte is 0x7F's open bus (review-grcg F1's
    // zero-extend claim covers 0x7C only). pc9821_iobus assembles both
    // (tb_pc9821_iobus pins them).
    input wire       port_we,
    input wire [7:0] port_addr,
    input wire [7:0] port_din,

    // The live mode register. NOT a guest read-back: 0x7C is write-only and its
    // byte read is open bus 0xFF (docs/probes/RDBACK.TXT:152), so this output's
    // only consumer is pc9821_crtc's now-unconsumed grcg_mode_r input.
    output wire [7:0] mode_r,

    // The GRCG's store gate (mode bit 7), exported so pc9821_gvram's dispatch can
    // ask before it hands over a store. This is the single definition of mode bit 7.
    output wire expand_gate,

    // The tile-compare read gate (mode bit 7 set, bit 6 clear), exported for the same
    // dispatch: NP2kai sends a read in exactly this mode to memtcr0/1_rd*, and a read
    // in 0xC0 (RMW) to the plain path.
    output wire tcr_gate,

    // The CPU's store, already known to be inside a graphics plane window. The
    // address is {page, plane_offset[14:0]} -- a plane offset, and the GRCG
    // deliberately ignores the window it came through.
    input  wire        cpu_valid,
    input  wire        cpu_write,
    input  wire [15:0] cpu_addr,
    input  wire [31:0] cpu_din,
    input  wire [3:0]  cpu_be,
    output wire [31:0] cpu_dout,
    output wire        cpu_ready,
    output wire        cpu_resp_valid,

    // The D1 client port (pc9821_gvram.sv). One access carries the whole CPU word's work:
    // the store's base column plus cpu_be and cl_tile/cl_rmw for the client's walk, or a
    // multi-column request marked by cl_burst (a two-word write carries both words on
    // cl_wdata2, a read returns one word per cl_done).
    output reg         cl_valid,
    input  wire        cl_ready,
    output reg         cl_write,
    output reg  [15:0] cl_addr,
    // The CPU byte enables the GRCG LATCHED at the capture (`be_q`). The GVRAM walk reads
    // them for its lane selection; with the store's ready decoupled the live
    // `cpu_be` is gone by the cycle the walk starts, so the latch is the only stable source.
    output wire [3:0]  cl_be,
    output reg  [31:0] cl_wdata,
    // The byte-zero and merge-eligible lane-skip flags of cl_wdata are precomputed HERE,
    // beside the data register (cap_din0/cap_dinmid and their cl_datum0_r/cl_mergeable_r
    // latches below), and leave on the raw arm taps: pc9821_gvram_arb muxes 4-bit results
    // instead of comparing the 32-bit muxed write data inside its port-A WE cone.
    output reg  [3:0]  cl_wbe,
    output reg         cl_burst,
    output reg  [63:0] cl_wdata2,
    output wire [31:0] cl_tile,
    output wire        cl_rmw,
    // The capture-cycle presentation is the LIVE arm of the client mux (cl_* above read the
    // capture's own operands when it is high and the latched image when it is low), exported
    // so pc9821_gvram_arb can mux its lane-enable cases on the RESULT instead of operand-
    // muxing under the store_accept cone (cap_store carries the device-alias decode).
    output wire        cl_cap,
    // RAW arm taps for both sides of the presentation mux above (cl_cap_* = the capture's
    // own operands, cl_hold_* = the latched image). pc9821_gvram_arb forms its lane/we
    // cone from these instead of the muxed cl_* ports: those carry their select chain
    // (cap_store -> cap_tdw -> the flag overrides) in series with the lane logic even in
    // capture cycles - the post-step-3 fit's worst path ran exactly
    // flags -> cl_datum0/cl_mergeable muxes -> tdw_burst -> lane_skip -> lane_live that
    // way. With the taps, cl_cap is the only deep signal and it lands on the final mux
    // selects alone.
    output wire        cl_cap_rmw,          // mode[6], the capture's RMW class
    output wire  [3:0] cl_hold_be,          // be_q
    output wire        cl_hold_rmw,         // rmw_q
    output wire  [3:0] cl_hold_datum0,      // cl_datum0_r
    output wire  [3:0] cl_hold_mergeable,   // cl_mergeable_r
    input  wire [31:0] cl_rdata,
    input  wire        cl_done,

    // Telemetry: the walk's own activity, so pc9821_gvram can count the cycles the CPU
    // is held for a GRCG store and split RMW from TDW. `dbg_busy` is the FSM away from G_IDLE
    // (the whole walk including its response tail, which is exactly the time the CPU is held);
    // `dbg_write`/`dbg_rmw` are the captured operation's class, so a TCR read counts in neither.
    output wire        dbg_busy,
    output wire        dbg_rmw,
    output wire        dbg_write,
    // Operation telemetry: one pulse per STORE the GRCG accepts, so pc9821_perf_msg's
    // GS field beside GR+GT gives (GR+GT)/GS - the mean cycles a GRCG store holds the CPU.
    output wire        dbg_grcg_store
);

  // ---------------------------------------------------------------------------
  // Register file (ports 0x7C / 0x7E) - the single definition of mode and tiles.
  // ---------------------------------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */  // only bits 7, 6 and 3:0 drive anything; 5:4 unused
  reg [7:0] mode;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [7:0] tile [0:3];
  reg [1:0] tile_cnt;

  assign expand_gate = mode[7];
  assign tcr_gate    = mode[7] & ~mode[6];
  assign mode_r      = mode;

  // ---------------------------------------------------------------------------
  // Sequencer. The register file is written by 0x7C/0x7E and read at the walk's ACCEPT and
  // CAPTURE, not held for the whole walk. The capture cycle reads `mode`/`tile` (the TDW burst
  // classification, `cl_wbe = ~mode[3:0]`, `cl_wdata2`), and pc9821_gvram LATCHES what the walk
  // needs there - the tile word (`m_tile`), the lane enables (`m_lane_be`/`cl_be`) and the
  // direction (`m_write`). The RMW class (`cl_rmw`) and the merge payload (`cl_wbe`/`cl_wdata`)
  // are NOT latched there: the walk reads them live deep into its merge (G_RMWC), and they stay
  // put only because THIS module holds `rmw_q`/`cl_wbe_r`/`cl_wdata_r`/`be_q` until its next
  // capture and cannot capture again before its own `cl_done` (G_STW: `if (cl_done)`). That is
  // an invariant, not a latch - pc9821_gvram_arb's assertion pins it (its check (7), gvram-arb
  // review F6.3): if this module ever posts (advances on accept like the EGC's S_WR_B_ACC), the
  // merge inputs move mid-walk and G_RMWC corrupts the word. So a guest `out 0x7C`/`out 0x7E`
  // that lands while a store drains (the accept-and-decouple does not hold the CPU off for the
  // walk) cannot move the walk in flight. The TCR READ still holds the CPU (its `cpu_ready` is in
  // G_RESP), so the LIVE `mode`/`tile` reads in `tcr_byte` are safe too. Nothing else writes
  // these ports.
  // ---------------------------------------------------------------------------
  // A STORE is presented in the G_IDLE cycle that captures it and completed in the cycle its walk
  // ends. A READ keeps the two tail states, because its accept and its response
  // strobe MUST be separate cycles (the contract); a write has no strobe, so its ready is
  // its completion, exactly as the GVRAM's own plain store's ready.
  localparam [3:0] G_IDLE  = 4'd0,
                   G_STW   = 4'd2,   // wait for the store walk's completion
                   G_TDW   = 4'd4,   // wait for a TDW two-word request (and present the second pair)
                   G_TB    = 4'd5,   // the TCR read as ONE burst
                   G_TBW   = 4'd13,
                   G_RESP  = 4'd6,   // assert cpu_ready (the ACCEPT), then G_RESP2
                   G_RESP2 = 4'd11,  // assert cpu_resp_valid on the LATER cycle
                   G_HOLD  = 4'd7;

  reg [3:0]  gstate;
  reg [2:0]  tcr_i;     // the TCR read's returned word index
  reg        tdw_p1;    // the TDW burst is on its second column pair
  reg        p_both_q;  // the captured TDW burst covers BOTH column pairs (latched)
  reg [3:0]  be_q;
  /* verilator lint_off UNUSEDSIGNAL */  // the client adds the enabled lane; the access's
  // own low two address bits are always zero (a dword-aligned CPU address), so addr_q[1:0]
  // only carry the plane-fold bit and the lane is cpu_be's.
  reg [15:0] addr_q;
  /* verilator lint_on UNUSEDSIGNAL */
  reg        rmw_q;
  reg        wr_q;      // the in-flight transaction is a store (drives cpu_resp_valid)
  reg [31:0] dout_q;    // the TCR read's accumulated datum

  // The client port's REGISTERED payload, for the cycles after a capture. The port
  // itself presents the CAPTURE cycle's own store combinationally (see `cap_store` below), so
  // these are the `_r` image the walk keeps reading once that cycle is past.
  reg        cl_valid_r;
  reg        cl_write_r;
  reg        cl_burst_r;
  reg [15:0] cl_addr_r;
  reg [31:0] cl_wdata_r;
  reg  [3:0] cl_datum0_r;   // the _r image of cl_datum0, latched where cl_wdata_r is
  reg  [3:0] cl_mergeable_r; // the merge-eligible image, latched beside cl_datum0_r
  reg  [3:0] cl_wbe_r;
  reg [63:0] cl_wdata2_r;

  integer i;

  // The four tile bytes are per plane -- blue gets the blue tile, red the red
  // tile -- so the column word is {E,G,R,B} = {tile[3],tile[2],tile[1],tile[0]}.
  wire [31:0] tile_w = {tile[3], tile[2], tile[1], tile[0]};
  assign cl_tile = tile_w;

  // The TCR read's burst: the enabled lanes' run [first_lane, last_lane] is ONE request, and
  // the i-th returned word is the column first_lane + i.
  wire [1:0] tcr_first = be_q[0] ? 2'd0 : be_q[1] ? 2'd1 : be_q[2] ? 2'd2 : 2'd3;
  wire [1:0] tcr_last  = be_q[3] ? 2'd3 : be_q[2] ? 2'd2 : be_q[1] ? 2'd1 : 2'd0;
  wire [2:0] tcr_n     = {1'b0, tcr_last} - {1'b0, tcr_first} + 3'd1;
  wire [1:0] tcr_lane  = tcr_first + tcr_i[1:0];   // the column of the word just returned

  // A column PAIR can go as ONE two-word request when both its columns' merged word is the
  // tile alone -- TDW always, and RMW when the pair's CPU data bytes are 0xFF (the read-skip),
  // because then (old & ~0xFF) | (tile & 0xFF) = tile whatever old
  // was. Any other RMW needs the old bytes and takes the client walk.
  // The pair test is made in the CAPTURE cycle, which is the only cycle it is read: it
  // classifies the store the G_IDLE branch is about to present, so it reads the LIVE access and
  // needs no latch of its own.
  wire [3:0]  be_seen  = cpu_be;
  wire [31:0] din_seen = cpu_din;
  wire pair0_ok = (be_seen[1:0] == 2'b11) &&
                  (!mode[6] || ((din_seen[7:0] == 8'hFF) && (din_seen[15:8] == 8'hFF)));
  wire pair1_ok = (be_seen[3:2] == 2'b11) &&
                  (!mode[6] || ((din_seen[23:16] == 8'hFF) && (din_seen[31:24] == 8'hFF)));
  // Only an access whose enables are EXACTLY whole pairs (0011 / 1100 / 1111) may take the
  // burst; any other set (a byte, or lanes spanning a pair) has no two-word request that
  // covers it and takes the client walk instead.
  wire pair_low  = pair0_ok && (be_seen[3:2] == 2'b00);
  wire pair_high = pair1_ok && (be_seen[1:0] == 2'b00);
  wire pair_both = (be_seen == 4'b1111) && pair0_ok && pair1_ok;
  wire tdw_burst = cpu_write && (mode[3:0] == 4'h0) && (pair_low || pair_high || pair_both);

  // TCR: the column read returns all four planes' byte at this lane; a disabled plane
  // contributes NOTHING to the OR (NP2kai TCRRD's `if (!(modereg & bit))`), and the
  // result is inverted, so an all-disabled plane set reads 0xFF like the reference.
  wire [7:0]  tcr_byte = ~( (mode[0] ? 8'h00 : (cl_rdata[7:0]   ^ tile[0]))
                          | (mode[1] ? 8'h00 : (cl_rdata[15:8]  ^ tile[1]))
                          | (mode[2] ? 8'h00 : (cl_rdata[23:16] ^ tile[2]))
                          | (mode[3] ? 8'h00 : (cl_rdata[31:24] ^ tile[3])) );

  // THE ACCEPT AND THE RESPONSE ARE SEPARATE CYCLES. pc9821_memory_subsystem's
  // responder contract requires it ("assert cpu_ready, then cpu_resp_valid ... on a
  // LATER cycle, never the same one, or z486 never clears its in-flight flag"), and
  // the EGC beside this module already does it (S_EVAL asserts cpu_ready, S_RESP2
  // asserts cpu_resp_valid). This module asserted both in G_RESP, and z486's paging
  // unit sets its fast_path_pending on the accept edge, so a same-cycle completion
  // was seen with fast_path_pending still low and then never again: the CPU wedged
  // on the ITF's GRCG tile-compare read at 0xFA63E.
  assign cpu_dout       = dout_q;
  assign cpu_resp_valid = (gstate == G_RESP2) && !wr_q;
  // ACCEPT-AND-DECOUPLE. A STORE's ready pulses in the G_IDLE cycle that ACCEPTS it, and
  // the walk (or the two-word TDW burst) completes BEHIND the CPU. This is the GRCG's half of the
  // same change made on the GVRAM's plain path and completes: a store's ready is
  // its ACCEPT, not its completion, because the walk's cycles are the one thing the firmware does
  // not time. Coherency is the GVRAM's stall - the client's request is not accepted off the array
  // until the walk drains, so no later CPU access can observe a half-merged word. A READ and the
  // all-planes-disabled no-op store keep G_RESP (their accept/response MUST be separate cycles,
  // the contract), and the no-op store is excluded from the capture term so it pulses
  // ready once. There is no second ready at the walk's end: a ready z486 has already consumed
  // would be taken for the NEXT request's accept.
  //
  // The guest's `out 0x7C`/`out 0x7E` can now run while the walk drains (it could not while the
  // walk held the CPU), so the walk must not read the register file live: `cl_rmw`/`cl_wbe`/
  // `cl_wdata` are already latched at the capture, and pc9821_gvram latches the tile word at its
  // accept (`m_tile`).
  wire store_accept = (gstate == G_IDLE) && cpu_valid && expand_gate && cpu_write &&
                      (mode[3:0] != 4'hF);
  // The ready is a one-cycle REGISTERED level the cycle after the accept, so it is presented for
  // a whole clk_sys (the responder handshake z486 samples) rather than only in the accept cycle.
  reg  store_ready_q;
  assign cpu_ready      = store_ready_q || (gstate == G_RESP);

  // ---------------------------------------------------------------------------
  // THE PRESENTATION BUBBLE
  // ---------------------------------------------------------------------------
  // The store the G_IDLE cycle captures is presented ON THAT CYCLE, not the next one. Before
  // this, the capture latched `be_q`/`addr_q`/`rmw_q` and set the registered `cl_*` outputs, so
  // the GVRAM saw the request one clk_sys later and resolved the walk's FIRST lane there: one
  // clk_sys with the array idle in EVERY store, on exactly the shapes the sprite pass is made of
  // (the GRCG RMW erase/draw). It is the same class of dead cycle removed on the GVRAM's
  // own accept cycle, one level up in the client: there, the accepted access's accept cycle issued
  // nothing; here, the captured store's capture cycle presented nothing.
  //
  // The registered payload stays, and the walk still reads it for the cycles after the capture:
  // with the store's ready decoupled the guest's `out 0x7C`/`out 0x7E` can land while
  // the walk drains, so those fields MUST NOT be live. Only the CAPTURE cycle's own presentation
  // is live, and the GVRAM latches every field it needs (m_base/m_lane_be/m_tile) at its accept.
  wire cap_store = store_accept;
  wire cap_tdw   = cap_store && tdw_burst;
  wire [15:0] cap_addr = {cpu_addr[15], cpu_addr[14:2], cap_tdw && pair_high ? 2'b10 : 2'b00};
  assign cl_valid  = cap_store | cl_valid_r;
  // The registered presentation's next value, folded into ONE expression (R2): set by the
  // capture cycle above or by one of the FSM's later arms (the TDW second pair, the TCR
  // read's first column), cleared by the accept. The clear used to sit after the case with
  // a comment saying it wins "because it is LAST" - the position was the mechanism. As a
  // boolean, the accept wins by construction: a presentation accepted in the cycle it is
  // latched must not be re-presented after the walk.
  wire cl_valid_set = cap_store |
                      ((gstate == G_TDW) && cl_done && !tdw_p1 && p_both_q) |
                      (gstate == G_TB);
  wire cl_valid_clear = cl_valid && cl_ready;
  assign cl_write  = cap_store ? 1'b1 : cl_write_r;
  assign cl_burst  = cap_store ? cap_tdw : cl_burst_r;
  assign cl_addr   = cap_store ? cap_addr : cl_addr_r;
  assign cl_wbe    = cap_store ? (cap_tdw ? 4'hF : ~mode[3:0]) : cl_wbe_r;
  assign cl_wdata  = cap_store ? (cap_tdw ? 32'hFFFF_FFFF : cpu_din) : cl_wdata_r;
  // The byte-zero image of cl_wdata (latched beside it as cl_datum0_r and exported on the
  // raw taps; the arbiter takes the capture cycle's own image as its cpu_din_datum0, the
  // same function of the same datum). The TDW presentation's 4'b0000 override of the old
  // muxed export was unobservable downstream (a TDW capture takes the burst arm, which
  // never consults the flags) and is gone with it.
  wire [3:0] cap_din0 = {(cpu_din[31:24] == 8'h00), (cpu_din[23:16] == 8'h00),
                         (cpu_din[15:8]  == 8'h00), (cpu_din[7:0]   == 8'h00)};
  // The merge-eligible image (byte != 0x00 && != 0xFF): cl_mergeable_r is its latched form
  wire [3:0] cap_dinmid = {(cpu_din[31:24] != 8'h00) && (cpu_din[31:24] != 8'hFF),
                           (cpu_din[23:16] != 8'h00) && (cpu_din[23:16] != 8'hFF),
                           (cpu_din[15:8]  != 8'h00) && (cpu_din[15:8]  != 8'hFF),
                           (cpu_din[7:0]   != 8'h00) && (cpu_din[7:0]   != 8'hFF)};
  assign cl_wdata2 = cap_store ? {tile_w, tile_w} : cl_wdata2_r;
  // The walk's lane enables and its RMW class: live in the capture cycle (`cpu_be`/`mode[6]`, the
  // values the capture is about to latch), the latch after.
  assign cl_be  = cap_store ? cpu_be : be_q;
  assign cl_rmw = cap_store ? mode[6] : rmw_q;
  assign cl_cap = cap_store;
  assign cl_cap_rmw = mode[6];
  assign cl_hold_be = be_q;
  assign cl_hold_rmw = rmw_q;
  assign cl_hold_datum0 = cl_datum0_r;
  assign cl_hold_mergeable = cl_mergeable_r;

  // Telemetry. `rmw_q`/`wr_q` hold the captured access's class for the whole walk and
  // are only read while `dbg_busy`, so their value in G_IDLE cannot mis-attribute a cycle.
  assign dbg_busy  = (gstate != G_IDLE);
  assign dbg_rmw   = rmw_q;
  assign dbg_write = wr_q;
  // One pulse per accepted STORE: the G_IDLE branch into the walk/TDW arms, which is the cycle the
  // CPU's store command latches (be_q/din_q/wr_q) and `expand_gate` owns it. A TCR read
  // (cpu_write low) is not a store, and a store with the GRCG gate clear never reaches this module
  // (pc9821_gvram's cc_owns_grcg requires expand_gate for a write), so the two exclusions are
  // stated rather than assumed. `gstate == G_IDLE` makes it a one-cycle pulse however long the
  // walk runs.
  assign dbg_grcg_store = (gstate == G_IDLE) && cpu_valid && expand_gate && cpu_write;

  always @(posedge clk) begin
    if (reset) begin
      mode     <= 8'h00;
      tile_cnt <= 2'd0;
      for (i = 0; i < 4; i = i + 1) tile[i] <= 8'h00;
      gstate   <= G_IDLE;
      tcr_i    <= 3'd0;
      tdw_p1   <= 1'b0;
      p_both_q <= 1'b0;
      store_ready_q <= 1'b0;
      be_q     <= 4'd0;
      addr_q   <= 16'd0;
      rmw_q    <= 1'b0;
      wr_q     <= 1'b0;
      dout_q   <= 32'hFFFF_FFFF;
      cl_valid_r <= 1'b0;
      cl_write_r <= 1'b0;
      cl_addr_r  <= 16'd0;
      cl_wdata_r <= 32'd0;
      cl_datum0_r <= 4'b1111;
      cl_mergeable_r <= 4'b0000;
      cl_wbe_r   <= 4'hF;
      cl_burst_r <= 1'b0;
      cl_wdata2_r <= 64'd0;
    end else begin
      if (port_we) begin
        case (port_addr)
          8'h7C: begin
            mode     <= port_din;
            tile_cnt <= 2'd0;   // a mode write restarts the tile write pointer
          end
          8'h7E: begin
            tile[tile_cnt] <= port_din;
            tile_cnt <= tile_cnt + 2'd1;
          end
          default: ;
        endcase
      end

      // The decoupled store's ready: one cycle after the G_IDLE accept.
      store_ready_q <= store_accept;

      case (gstate)
        G_IDLE: if (cpu_valid && expand_gate && (cpu_write || tcr_gate)) begin
          be_q   <= cpu_be;
          addr_q <= cpu_addr;
          rmw_q  <= mode[6];
          wr_q   <= cpu_write;
          dout_q <= cpu_write ? 32'hFFFF_FFFF : 32'd0;
          tcr_i  <= 3'd0;
          if (!cpu_write) gstate <= (cpu_be == 4'd0) ? G_RESP : G_TB;
          // Every plane disabled is a no-op, not a plain store and not a backend
          // access at all (mode 0x8F; bench pins the same case).
          else if (mode[3:0] == 4'hF) gstate <= G_RESP;
          // A store PRESENTS IN ITS CAPTURE CYCLE. The port drives the walk's
          // own presentation combinationally (the `cap_*` block above) and the LATCHED image is
          // written here for the cycles after it; the client's own walk resolves every enabled CPU
          // byte lane from this base column, cpu_be and cl_tile/cl_rmw, so a 16-bit store and a
          // 32-bit store are each one round trip with no presentation state.
          else if (tdw_burst) begin
            tdw_p1     <= pair_high ? 1'b1 : 1'b0;
            // `pair_both` is read again in G_TDW, so it MUST be latched here: with the store's
            // ready decoupled the CPU drops `cpu_be`/`cpu_din` the cycle the walk
            // starts, and the LIVE pair test then reads be=4'hF and presents a spurious second
            // pair (writing the tile over the next two columns - the `tdw16 neighbour` failure).
            p_both_q   <= pair_both;
            cl_write_r  <= 1'b1;
            cl_burst_r  <= 1'b1;
            cl_addr_r   <= {cpu_addr[15], cpu_addr[14:2], pair_high ? 2'b10 : 2'b00};
            cl_wbe_r    <= 4'hF;
            cl_wdata_r  <= 32'hFFFF_FFFF;
            cl_datum0_r <= 4'b0000;
            cl_mergeable_r <= 4'b0000;
            cl_wdata2_r <= {tile_w, tile_w};
            gstate    <= G_TDW;
          end else begin
            cl_write_r <= 1'b1;
            cl_burst_r <= 1'b0;
            cl_addr_r  <= {cpu_addr[15], cpu_addr[14:2], 2'b00};
            cl_wdata_r <= cpu_din;
            cl_datum0_r <= cap_din0;
            cl_mergeable_r <= cap_dinmid;
            cl_wbe_r   <= ~mode[3:0];
            gstate   <= G_STW;
          end
        end

        G_STW: if (cl_done) gstate <= G_IDLE;

        // An all-plane TDW store, or an RMW one whose pair data bytes are 0xFF: one two-word
        // request per enabled column pair, both columns carrying the identical tile word. The
        // datum rides as all-ones so that if the client must fall back to its per-word path (a
        // dirty held word, burst_dirty_hold) the walk's merge still reduces to the tile. The
        // SECOND pair is presented HERE and stays: the first pair is presented by the
        // capture cycle above, so only the pair boundary needs a request, not a state.
        G_TDW: if (cl_done) begin
          if (!tdw_p1 && p_both_q) begin
            tdw_p1    <= 1'b1;
            cl_addr_r  <= {addr_q[15], addr_q[14:2], 2'b10};
          end else begin
            cl_burst_r <= 1'b0;
            gstate   <= G_IDLE;
          end
        end

        // The TCR read as ONE burst: the enabled lanes' run leaves as a single request and
        // the client returns one column word per cl_done, in column order.
        G_TB: begin
          cl_write_r <= 1'b0;
          cl_burst_r <= 1'b1;
          cl_addr_r  <= {addr_q[15], addr_q[14:2], tcr_first};
          cl_wbe_r   <= be_q;
          cl_wdata_r <= 32'd0;
          cl_datum0_r <= 4'b1111;
          cl_mergeable_r <= 4'b0000;
          gstate   <= G_TBW;
        end
        G_TBW: if (cl_done) begin
          if (be_q[tcr_lane]) dout_q[{tcr_lane, 3'b000} +: 8] <= tcr_byte;
          if (tcr_i == tcr_n - 3'd1) begin
            cl_burst_r <= 1'b0;
            gstate   <= G_RESP;
          end else tcr_i <= tcr_i + 3'd1;
        end

        // A WRITE has no response strobe (`cpu_resp_valid` is gated on `!wr_q`), so the two tail
        // states after the accept are dead cycles that only held the next store off. A READ keeps
        // both, because its accept and its response must be SEPARATE cycles (the contract
        // quoted above). Measured on the RMW erase: 31.3 -> 29.4 clk_sys/store.
        G_RESP:  gstate <= wr_q ? G_IDLE : G_RESP2;
        G_RESP2: gstate <= G_HOLD;
        // ONE unconditional bubble for the READ arm. It must NOT wait
        // for cpu_valid to drop: z486 clears its external valid for exactly ONE cycle after
        // an accept and may re-present on the next, so a hold this deep overruns that
        // window and the guest wedges (tb_pc9821_gfx_scene's GRCG erase phase).
        G_HOLD:  gstate <= G_IDLE;
        default: gstate <= G_IDLE;
      endcase

      // The presentation latch's single NBA site (the fold declared beside cl_valid above):
      // hold, or set on the capture / the FSM's later arms, and the accept clears it.
      cl_valid_r <= (cl_valid_set | cl_valid_r) & ~cl_valid_clear;
    end
  end

endmodule

`default_nettype wire

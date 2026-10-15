// The CPU byte-window responder for the two 0xA0000-range windows: text RAM
// (0xA0000-0xA3FFF, a 16 KiB byte-wide dual-port RAM the GDC also scans) and the
// memory-mapped CG byte window (0xA4000-0xA4FFF, a 32-byte repeating view of the glyph
// the CG registers select).
//
// ONE SEQUENCER, TWO ROUTES. The two windows used to be two modules -- pc9821_tram_bridge
// and pc9821_cg_window -- that were the SAME eight-state byte-walk machine written twice:
// S_IDLE/S_READ_ISSUE/S_READ_WAIT/S_READ_CAPTURE/S_WRITE/S_WRITE_COMMIT/S_RESP/S_HOLD,
// the same base/write_data/write_be/byte_index/byte_count/read_data[127:0]/line_request
// register set, the same byte_count = 16 on a cache-line read and 4 on a DWORD, and the
// same accept-then-respond split (the responder contract in pc9821_memory_subsystem.sv:
// assert ready, then resp_valid a cycle LATER, or z486's direct path never clears its
// in-flight flag). They differ only in the backend (a 14-bit TRAM byte port vs the GDC's
// 5-bit byte position) and in the TRAM attribute half's read gate.
//
// WHY SHARING THEM IS LEGAL, AND IT IS A PLATFORM ARGUMENT RATHER THAN A FIDELITY ONE.
// Both NP2kai (mem/memtram.c) and qemu-pc98 (hw/display/pc98-vga.c) treat the two windows
// as independent paths, so nothing in the references says they share hardware. What makes
// the share safe is that THIS MACHINE'S routing never has them in flight together: the
// memory map's route selects are one-hot (`route_cg` is the CG window's select, and
// pc9821_memory_subsystem's route-overlap check fatal-errors on tram_select && cg_win_select),
// each route's cpu_valid is its own select, and the z486 memory bus carries one request at a
// time. This is the argument that landed pc9821_block_share's one adapter for the disk and the
// floppy (T9) and one engine for the two floppy drives (T17b), with the easier corollary that
// NOTHING here is per-device state that must survive a request: base_addr, write_data,
// byte_index and the 128-bit accumulator are all just the request in flight. If either window
// ever needs state of its own, this module is the wrong shape and the two must split again.
//
// The merge was PRICED module-alone (-123 ALMs / -110 ALUTs / -217 registers over the pair)
// and PROVED equivalent when it landed: a co-simulation of this module against both original
// responders over 6000 requests (281303 cycle-by-cycle comparisons) with the CG's own
// registered byte path modelled, which detected 8/8 planted defects.
//
// WHAT EACH ROUTE'S BEHAVIOUR COMES FROM (the two originals' own citations, kept here because
// this file now carries them):
//   * The TRAM attribute half (0xA2000-0xA3FFF) is EVEN-ONLY: NP2kai memtram_wr8/wr16 gate on
//     `!(address & 1)` (mem/memtram.c:82-99, 130-161), and the machine's own poke/read agrees --
//     the VRAM probe (docs/probes/VRAM.TXT, row `A2000`) wrote
//     `00 FF 55 AA` and read back `00 FF 55 FF`. So an odd attribute byte takes no store AND
//     reads back 0xFF. The machine's read-back outranks NP2kai here, whose memtram_rd8
//     (mem/memtram.c:13-17) models only the store half.
//   * The CG window's byte position is {page = offset[0], row = offset[4:1]}, so the view
//     repeats every 32 bytes (qemu cgwindow_set_addr/readb/writeb; NP2kai memtram.c:23-29).
//     The machine corroborates the page bit: docs/probes/VRAM.TXT reads A4000..A400F as
//     8F 00 8F 00 ... -- a different PAGE at bit 0, not a neighbouring byte.
//   * `byte_sel` stays COMBINATIONAL, exactly as pc9821_cg_window had it: the position is a
//     function of the request's own base and byte index, so registering it would only widen the
//     port's waveform in cycles where the consumer does not act on it (pc9821_cg uses
//     cg_win_byte_sel only behind cg_rd_win/cg_wr_win). It also removes one level from the
//     cpu_dout/cpu_line_dout route mux in pc9821_memory_subsystem.

`default_nettype none

module pc9821_window_responder (
    input wire clk,
    input wire reset,

    // 0 = the TRAM route (0xA0000-0xA3FFF), 1 = the CG byte-window route (0xA4000-0xA4FFF).
    // In the design this is the memory map's one-hot route select, held for the life of the
    // request (see the exclusivity note above).
    input  wire        route_cg,

    // CPU-side memory request (already decoded to one of the two windows).
    /* verilator lint_off UNUSEDSIGNAL */   // the D1 port is 4-byte aligned, so cpu_addr[1:0] are don't-care
    input  wire [13:0] cpu_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0] cpu_din,
    input  wire [3:0]  cpu_be,
    input  wire        cpu_line_read,
    input  wire        cpu_valid,
    input  wire        cpu_write,
    output reg  [31:0] cpu_dout,
    output wire [127:0] cpu_line_dout,
    output reg         cpu_ready,
    output reg         cpu_resp_valid,
    output reg         cpu_line_resp_valid,

    // TRAM backend: the byte-wide port the GDC's dual-port RAM owns.
    output reg  [13:0] tram_addr,
    output reg   [7:0] tram_din,
    output reg         tram_we,
    input  wire  [7:0] tram_dout,

    // CG-window byte port. byte_sel is COMBINATIONAL (see the header): it is the byte
    // POSITION -- {page, row} of the 32-byte repeating view -- and the GDC's class table owns
    // which store and address that position names, because that table also serves port 0xA9
    // and one definition of it is what keeps the two views agreeing.
    output wire  [4:0] byte_sel,
    output reg         byte_rd,    // read strobe: the answer is one cycle later
    input  wire  [7:0] byte_dout,
    // The byte is not valid while this is set: the GDC holds it high while the code's SDRAM
    // glyph burst is in flight, so a JIS read waits for ITS code rather than returning the
    // previous one. Every other class answers immediately, and an undriven input is 0 (no hold).
    input  wire        byte_hold,
    output reg   [7:0] byte_din,
    output reg         byte_we
);

  localparam S_IDLE = 3'd0, S_READ_ISSUE = 3'd1, S_READ_WAIT = 3'd2,
             S_READ_CAPTURE = 3'd3, S_WRITE = 3'd4,
             S_WRITE_COMMIT = 3'd5, S_HOLD = 3'd6, S_RESP = 3'd7;

  reg [2:0] state;
  reg [13:0] base_addr;
  reg [31:0] write_data;
  reg [3:0]  write_be;
  reg [4:0]  byte_index;
  reg [4:0]  byte_count;
  reg [127:0] read_data;
  // read_data IS the assembled line. Its top byte is written on the same edge that enters
  // S_RESP, so a second 128-bit cpu_line_dout register would be a pure duplicate.
  assign cpu_line_dout = read_data;
  reg line_request;

  // base_addr is lane-aligned on the transfer's base and byte_index walks lanes from it, so
  // this is the byte the backend is asked for. For the CG route cpu_addr[13:12] are zero
  // (the window is 0xA4000-0xA4FFF, a 0x4000 offset into the 0xA0000 page), so the 14-bit sum
  // equals pc9821_cg_window's 13-bit off_sum and its {off_sum[0], off_sum[4:1]} position
  // exactly.
  wire [13:0] indexed_addr = base_addr + {9'd0, byte_index};

  // The attribute half of the text plane (0xA2000-0xA3FFF) is EVEN-ONLY (header's reference
  // note). The code plane (0xA0000-0xA1FFF) is full-width; the memory-switch cell's write gate
  // is the CRTC's, beside the BRAM. base_addr is 16-byte aligned, so neither a DWORD nor a
  // cache line can straddle 0x2000/0x3FFF in a way that would make the plane ambiguous
  // mid-transfer.
  wire attr_half_byte = (indexed_addr >= 14'h2000) && indexed_addr[0];
  // The CG window's byte position: a permutation of the offset's low five bits, not the bits
  // themselves (header's reference note).
  assign byte_sel = {indexed_addr[0], indexed_addr[4:1]};

  // Every enabled lane is offered to the backend. The TRAM route drops an odd attribute byte
  // (it reads back 0xFF regardless); the CG route offers every enabled lane and the GDC
  // discards the reference's dummy page.
  wire current_write_enabled = write_be[byte_index[1:0]] &&
                               (route_cg ? 1'b1 : !attr_half_byte);
  // The lane a read returns: 0xFF for an odd TRAM attribute byte, the backend's byte otherwise.
  // The lane's own address is available while the answer is captured (byte_index is held across
  // S_READ_ISSUE/S_READ_WAIT/S_READ_CAPTURE), so the test is per byte of the transfer.
  wire [7:0] read_lane = route_cg ? byte_dout
                                  : (attr_half_byte ? 8'hFF : tram_dout);
  wire last_byte = (byte_index + 5'd1) == byte_count;

  always @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      base_addr <= 14'd0;
      write_data <= 32'd0;
      write_be <= 4'd0;
      byte_index <= 5'd0;
      byte_count <= 5'd0;
      read_data <= 128'd0;
      line_request <= 1'b0;
      cpu_dout <= 32'hFFFF_FFFF;
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      cpu_line_resp_valid <= 1'b0;
      tram_addr <= 14'd0;
      tram_din <= 8'd0;
      tram_we <= 1'b0;
      byte_rd <= 1'b0;
      byte_din <= 8'd0;
      byte_we <= 1'b0;
    end else begin
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      cpu_line_resp_valid <= 1'b0;
      tram_we <= 1'b0;
      byte_rd <= 1'b0;
      byte_we <= 1'b0;

      case (state)
        S_IDLE: if (cpu_valid) begin
          base_addr <= cpu_line_read ? {cpu_addr[13:4], 4'b0000}
                                     : {cpu_addr[13:2], 2'b00};
          write_data <= cpu_din;
          write_be <= cpu_be;
          byte_index <= 5'd0;
          byte_count <= cpu_line_read ? 5'd16 : 5'd4;
          // read_data is NOT cleared here: a read writes every byte it answers with (a word
          // read bytes 0..3, cpu_dout's three low ones from here; a line all 16) before its
          // response, and a write does not touch it. pc9821_memory_subsystem's line-to-beat
          // converter relies on that: it reads the line's words from here during the beats,
          // when a store to this window may already have been accepted.
          line_request <= cpu_line_read;
          state <= cpu_write ? S_WRITE : S_READ_ISSUE;
        end

        S_READ_ISSUE: begin
          if (route_cg) byte_rd <= 1'b1;
          else          tram_addr <= indexed_addr;
          state <= S_READ_WAIT;
        end

        // The TRAM answers in one cycle (tram_dout changes after the edge which samples
        // tram_addr). A JIS glyph burst holds the CG byte: the class table has already held the
        // position and the GDC's own registered read answers in the same two-cycle cadence the
        // strobe set up, unless byte_hold says its code is still in flight.
        S_READ_WAIT: if (route_cg ? !byte_hold : 1'b1) state <= S_READ_CAPTURE;

        S_READ_CAPTURE: begin
          /* verilator lint_off WIDTHTRUNC */   // byte_count is 4 or 16, so byte_index<16 and this index is 0..120 of 128
          read_data[{byte_index, 3'b000} +: 8] <= read_lane;
          /* verilator lint_on WIDTHTRUNC */
          if (last_byte) begin
            // Accept (cpu_ready) and deliver (cpu_resp_valid) in SEPARATE cycles: z486's
            // direct read path registers the accept and clears its in-flight flag on the
            // response, so a same-cycle response wedges the CPU. Matches the open-bus responder.
            if (!line_request) cpu_dout <= {read_lane, read_data[23:0]};
            cpu_ready <= 1'b1;
            state <= S_RESP;
          end else begin
            byte_index <= byte_index + 5'd1;
            state <= S_READ_ISSUE;
          end
        end

        S_RESP: begin
          if (line_request) cpu_line_resp_valid <= 1'b1;
          else              cpu_resp_valid <= 1'b1;
          state <= S_HOLD;
        end

        S_WRITE: begin
          if (current_write_enabled) begin
            if (route_cg) begin
              byte_din <= write_data[{byte_index[1:0], 3'b000} +: 8];
              byte_we  <= 1'b1;
            end else begin
              tram_addr <= indexed_addr;
              tram_din  <= write_data[{byte_index[1:0], 3'b000} +: 8];
              tram_we   <= 1'b1;
            end
            state <= S_WRITE_COMMIT;
          end else if (last_byte) begin
            cpu_ready <= 1'b1;
            state <= S_HOLD;
          end else begin
            byte_index <= byte_index + 5'd1;
          end
        end

        // The backend samples the registered strobe/address/data on this edge.
        S_WRITE_COMMIT: begin
          if (last_byte) begin
            cpu_ready <= 1'b1;
            state <= S_HOLD;
          end else begin
            byte_index <= byte_index + 5'd1;
            state <= S_WRITE;
          end
        end

        // One cycle only: the accept (a store) or the response (a read) was delivered in the
        // previous cycle. It must NOT wait for cpu_valid to deassert -- a pipelined CPU need
        // not present one request per valid, and two back-to-back accesses to this route with
        // valid held would deadlock here. See pc9821_memory_subsystem.sv's responder contract.
        S_HOLD: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire

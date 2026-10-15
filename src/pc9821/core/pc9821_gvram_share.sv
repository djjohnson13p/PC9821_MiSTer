// PC-9821 GVRAM CPU-side port share: the CPU's plane-window access and the graphics
// GDC's draw-engine visit, one at a time (item 63, slice 1).
//
// The GVRAM cluster (pc9821_gvram_arb + the GRCG and EGC store paths) has ONE CPU-side
// port - the dispatch it runs is the CPU transaction's, not a bus arbiter's ("there is
// no arbitration between them", pc9821_gvram_arb's client-0 note). The GDC draw engine
// is a second master of the same port, and on the machine its writes travel the SAME
// GRCG/EGC tile path a CPU store of the same shape takes (NP2kai io/gdc_pset.c's
// dispatch: withegc -> egc_writeword, withtdw/withrmw -> the tile words, else the
// plain ROP - and the ITF's own GVRAM test at BANK4@0xFA70F passes on the Xe10 only
// because a GDC store there is served by the GRCG's TDW tile write). So a visit is
// presented as a CPU plane-window access of the same operands, and this module picks
// which master owns the port and routes the answers back.
//
// THE GRANT AND THE RESPONSE TAG ARE TWO DIFFERENT THINGS, and the second one is why
// this is not a plain mux. The cluster's read data strobe NEVER shares the accept's
// cycle (the responder contract in pc9821_memory_subsystem) and can come LATER - so a
// response owed to a transaction accepted before the switch must still reach the side
// that issued it. `resp_gdc_q` tags each response with the owner of the transaction
// whose ready produced it; the mux select (`gdc_own_q`) only decides whose OPERANDS the
// cluster sees. The grant itself waits for the CPU side to be quiet (no request
// presented), because a request already presented must not have its operands pulled
// out from under its own accept.
`default_nettype none

module pc9821_gvram_share (
    input wire clk,
    input wire reset,

    // The CPU's plane-window request (already decoded as "this access is GVRAM").
    input  wire        cpu_req,
    input  wire        cpu_write,
    input  wire        cpu_line_read,
    input  wire        cpu_page,
    input  wire  [1:0] cpu_plane,
    input  wire [14:0] cpu_offset,
    input  wire [31:0] cpu_din,
    input  wire  [3:0] cpu_be,

    // The engine gates the dispatch reads (the GRCG's mode bits, the EGC's gate).
    input  wire        gate_egc,
    input  wire        gate_grcg,
    input  wire        gate_tcr,

    // The cluster's answers toward the CPU. The LINE form is never a visit's (a GDC
    // draw is a word stream) and is passed through ungated.
    output wire        cpu_ready,
    output wire        cpu_resp_valid,
    output wire [31:0] cpu_dout,
    output wire        cpu_line_resp_valid,
    output wire [127:0] cpu_line_dout,

    // The GDC draw engine's visit (pc9821_gdc2's WRITE engine). `gdc_valid` holds
    // until `gdc_ready`; a read's datum answers on `gdc_resp`/`gdc_rdata` later.
    input  wire        gdc_valid,
    input  wire        gdc_write,
    input  wire        gdc_route_egc,
    input  wire        gdc_route_grcg,
    input  wire        gdc_page,
    input  wire  [1:0] gdc_plane,
    input  wire [14:0] gdc_offset,
    input  wire [31:0] gdc_din,
    input  wire  [3:0] gdc_be,
    output wire        gdc_ready,
    output wire        gdc_resp_valid,
    output wire [31:0] gdc_rdata,

    // The cluster side (pc9821_gvram_arb's CPU route and the two engines' store ports).
    output wire        gvr_valid,
    output wire        gvr_write,
    output wire        gvr_line_read,
    output wire        gvr_page,
    output wire  [1:0] gvr_plane,
    output wire [14:0] gvr_offset,
    output wire [31:0] gvr_din,
    output wire  [3:0] gvr_be,
    output wire        gvr_gate_egc,
    output wire        gvr_gate_grcg,
    output wire        gvr_gate_tcr,
    input  wire        gvr_ready,
    input  wire        gvr_resp_valid,
    input  wire [31:0] gvr_dout,
    input  wire        gvr_line_resp_valid,
    input  wire [127:0] gvr_line_dout
);

  // The mux select: a visit owns the port from its grant until its own completion -
  // a store's ready, a read's response strobe. It is a REGISTER, so the operands
  // cannot move under a cycle where the cluster is accepting.
  reg gdc_own_q;
  // Whose transaction the cluster's next word response belongs to. Set at every
  // accept-side ready from the owner of that transaction; a store's ready sets it and
  // no strobe follows, which is harmless - the next read's ready re-sets it.
  reg resp_gdc_q;
  // The visit's request has been accepted; its completion may still be pending (a
  // read's response comes later), so this is what the hold-until-accept assertion
  // below keys on rather than the mux select alone.
  reg visit_taken_q;

  wire grant = gdc_valid && !cpu_req && !gdc_own_q;
  // A store completes on its ready; a read completes on its (later) response strobe.
  wire visit_done = gdc_own_q && (gdc_write ? gvr_ready : (gvr_resp_valid && resp_gdc_q));

  always @(posedge clk) begin
    if (reset) begin
      gdc_own_q  <= 1'b0;
      resp_gdc_q <= 1'b0;
      visit_taken_q <= 1'b0;
    end else begin
      if (grant)      gdc_own_q <= 1'b1;
      else if (visit_done) gdc_own_q <= 1'b0;
      if (gvr_ready)  resp_gdc_q <= gdc_own_q;
      if (grant)      visit_taken_q <= 1'b0;
      else if (gvr_ready && gdc_own_q) visit_taken_q <= 1'b1;
    end
  end

  // The operands. The engine's route is latched per draw (pc9821_gdc2's
  // gdcpset_prepare analog), so a mid-draw mode change cannot re-route a draw: while a
  // visit owns the port the gates presented to the cluster are the visit's own, and a
  // read visit is always the plain path (its merge read is the engine's own, never a
  // GRCG TCR or an EGC read).
  assign gvr_valid      = gdc_own_q ? gdc_valid : cpu_req;
  assign gvr_write      = gdc_own_q ? gdc_write : cpu_write;
  assign gvr_line_read  = gdc_own_q ? 1'b0 : cpu_line_read;
  assign gvr_page       = gdc_own_q ? gdc_page : cpu_page;
  assign gvr_plane      = gdc_own_q ? gdc_plane : cpu_plane;
  assign gvr_offset     = gdc_own_q ? gdc_offset : cpu_offset;
  assign gvr_din        = gdc_own_q ? gdc_din : cpu_din;
  assign gvr_be         = gdc_own_q ? gdc_be : cpu_be;
  assign gvr_gate_egc   = gdc_own_q ? gdc_route_egc : gate_egc;
  assign gvr_gate_grcg  = gdc_own_q ? gdc_route_grcg : gate_grcg;
  assign gvr_gate_tcr   = gdc_own_q ? 1'b0 : gate_tcr;

  // The answers. The ready's owner is the mux select of its own cycle; the response's
  // owner is the tag (it can outlive the switch).
  assign cpu_ready      = gvr_ready && !gdc_own_q;
  assign gdc_ready      = gvr_ready && gdc_own_q;
  assign cpu_resp_valid = gvr_resp_valid && !resp_gdc_q;
  assign gdc_resp_valid = gvr_resp_valid && resp_gdc_q;
  assign cpu_dout       = gvr_dout;
  assign gdc_rdata      = gvr_dout;
  assign cpu_line_resp_valid = gvr_line_resp_valid;
  assign cpu_line_dout  = gvr_line_dout;

`ifdef VERILATOR
  // The engine's contract on this boundary: a visit is presented until it is accepted
  // (docs/single-cycle-event-discipline.md R7 - deferred consumption, never a dropped
  // request). A request that falls before its ready would strand the cluster's accept.
  always @(posedge clk) begin
    if (!reset && gdc_own_q && !visit_taken_q && !gdc_valid)
      $error("pc9821_gvram_share: the GDC visit dropped mem_valid before its ready - the request must hold until accepted (R7)");
  end
`endif

endmodule

`default_nettype wire

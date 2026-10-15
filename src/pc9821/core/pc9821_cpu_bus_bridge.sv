// The CPU-throttle bus bridge between the gated z486 and the clk_sys platform. The contract it
// meets is stated in pc9821_cpu_clk.sv's header (src/z486/docs/throttle.md).

// The bus bridge. `c_*` is the CPU side (gated domain), `p_*` the platform side (clk_sys).
module pc9821_cpu_bus_bridge (
    input  wire        clk,
    input  wire        reset_n,         // the CPU's reset (cpu_reset_n): empties the response FIFO
    input  wire        cpu_ce,          // the CPU gets the edge ending this cycle

    // request: the CPU's valid/inta levels and the platform's view of them
    input  wire        c_valid,
    input  wire        c_inta,
    output wire        p_valid,         // low while an accept waits for the CPU's edge
    output wire        p_inta,
    // accept: the platform's ready, held for the CPU
    input  wire        p_ready,
    output wire        c_ready,
    // response: one beat per CPU edge, buffered when the CPU is not clocked
    input  wire        p_resp_valid,
    input  wire [31:0] p_din,
    output wire        c_resp_valid,
    output wire [31:0] c_din,

    // the whole-L1 flush: a one-cycle platform pulse held for the CPU; the platform's busy
    // view covers the waiting pulse, and the CPU's one-CPU-cycle done is sampled once
    input  wire        p_flush_req,
    output wire        c_flush_req,
    input  wire        c_flush_busy,
    output wire        p_flush_busy,
    input  wire        c_flush_done,
    output wire        p_flush_done,

    // one-CPU-cycle output pulses, sampled once (under cpu_ce)
    input  wire        c_triple_fault,
    output wire        p_triple_fault,
    input  wire [2:0]  c_dbg_pulse,     // dbg_issue, dbg_gate_read, dbg_page_fault
    output wire [2:0]  p_dbg_pulse
);

// ---- the accept ----
// A responder's ready in a non-enabled cycle completes the transfer on the platform side; the
// CPU takes it at its next enabled edge. Until then the platform must not see the request
// again (it would serve it twice), so p_valid/p_inta drop and the CPU's ready is held.
// NOT cleared by the CPU's reset: an accept can be the CPU's own reset request (`out 0xF0`,
// a triple fault's re-entry), and the reset reaches the CPU only at its next edge
// (cpu_throttle forces cpu_ce one cycle after reset_n falls), so clearing the hold on the
// reset would show the platform the CPU's still-raised valid again - the request served
// twice (pc9821_iobus's R6/R8 assertion caught exactly that at 1 MHz). The edge clears it.
reg acc_pend;
always @(posedge clk) begin
    if (cpu_ce)                  acc_pend <= 1'b0;
    else if (p_valid && p_ready) acc_pend <= 1'b1;
end
assign p_valid = c_valid && !acc_pend;
assign p_inta  = c_inta  && !acc_pend;
assign c_ready = p_ready || acc_pend;

// ---- the response ----
// z486 holds one read outstanding (src/z486/z486.sv's bus contract) and counts its beats at
// its own edges, so it does not present the next read before it has taken every beat of this
// one: at most `burstcount` (4, a line fill; line_read is unused here) beats can wait. A beat
// is buffered only when the CPU cannot take it this cycle or older beats are waiting, so with
// cpu_ce constant 1 the FIFO stays empty and c_resp_valid/c_din are p_resp_valid/p_din.
//
// A beat may reach the CPU on the same edge as a held accept: from the CPU's side that is a
// zero-wait accept with its data in the accept cycle, which z486's bus contract allows. The
// fork's 5227777 (re-vendored at 1b01c8f) fixed the paging unit for it - before that fix a
// demand read completed in its PG_MEM_TLB accept cycle left fast_path_pending set and wedged
// the CPU, and this bridge held such a beat back one edge (RESP_HOLD, removed with the fix).
reg [31:0] fifo_q [0:3];
reg [1:0]  rd_ptr, wr_ptr;
reg [2:0]  count;
wire       fifo_empty = (count == 3'd0);
wire       push = p_resp_valid && (!cpu_ce || !fifo_empty);
wire       pop  = cpu_ce && !fifo_empty;
always @(posedge clk) begin
    if (push) fifo_q[wr_ptr] <= p_din;
end
always @(posedge clk) begin
    if (!reset_n) begin
        rd_ptr <= 2'd0;
        wr_ptr <= 2'd0;
        count  <= 3'd0;
    end else begin
        if (push) wr_ptr <= wr_ptr + 2'd1;
        if (pop)  rd_ptr <= rd_ptr + 2'd1;
        count <= count + {2'd0, push} - {2'd0, pop};
    end
end
assign c_resp_valid = fifo_empty ? p_resp_valid : 1'b1;
assign c_din        = fifo_empty ? p_din : fifo_q[rd_ptr];

// ---- the flush request ----
// The fork's cpu_pulse_hold, inlined so the platform can see the waiting pulse: pc9821_iobus
// launches a flush only while none is committed (flush_start || cache_flush_busy), and the
// CPU's busy rises only at the edge that takes the request, so the pulse waiting for that edge
// must count as busy or a second launch could slip in between.
// Like the accept, it is cleared by the CPU's edge, not by its reset: a CPU in reset at that
// edge ignores the request exactly as the ungated CPU does.
reg flush_pend;
always @(posedge clk) flush_pend <= c_flush_req & ~cpu_ce;
assign c_flush_req  = p_flush_req | flush_pend;
assign p_flush_busy = c_flush_busy | flush_pend;
assign p_flush_done = c_flush_done & cpu_ce;

// ---- the one-CPU-cycle output pulses ----
assign p_triple_fault = c_triple_fault & cpu_ce;
assign p_dbg_pulse    = c_dbg_pulse & {3{cpu_ce}};

// synthesis translate_off
always @(posedge clk) begin
    if (reset_n && push && !pop && count == 3'd4)
        $fatal(1, "pc9821_cpu_bus_bridge: a fifth response beat while four wait for the CPU (more than one read's beats outstanding)");
    if (p_flush_req && flush_pend)
        $fatal(1, "pc9821_cpu_bus_bridge: a flush request while the previous one still waits for the CPU");
end
// synthesis translate_on

endmodule

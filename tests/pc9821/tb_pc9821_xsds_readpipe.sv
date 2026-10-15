`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_XSDS_READPIPE: the strict XSDS SDRAM model PIPELINES its READs the way a real SDR SDRAM does - two back-to-back BL=1 READs return BOTH words, each exactly CAS-latency clocks after its own command (CL=2 and CL=3), a READ issued while an earlier BL=4 burst is outputting truncates that burst only from its own CL slot on, and the bus is Hi-Z outside the data slots - with no protocol or timing violation recorded by the model.
//
// WHY. The community model restarted one CAS-latency counter per READ command, so of two
// back-to-back BL=1 READs the first word was discarded; tb_pc9821_sdram_strict could not pass
// against it. The fix is a
// LOCAL FIX in the model; this bench pins the model's READ pipeline on its own, with no
// controller in the loop.
//
// ---- where each expectation comes from ----
// NOT from our RTL (there is none in this bench) and not from the model's own code: the rule is
// the SDR SDRAM datasheet's (JEDEC SDR SDRAM / AS4C32M16SB-6TIN READ operation): "the first data
// is available CL clocks after the READ command" - the controller's register captures it on the
// CL-th clock edge after the edge that sampled the READ (the chip launches it a clock earlier,
// tAC after edge CL-1) - and every READ command starts its own burst CL clocks later; a READ
// interrupting a burst in progress cuts that burst when the new burst's first data would appear;
// DQM has a 2-clock read latency counted to the capture edge. With READs sampled on edges k and
// k+1, word 0 is capturable on edge k+CL and word 1 on k+CL+1. The same capture-at-CL rule is
// what tests/pc9821/sdram_chip_model.sv and src/memory/sdram.v (which reads on real silicon)
// both implement; the unmodified community model launched one clock late.
//
// Data written once per CL: 1111,2222,3333,4444 at columns 0..3 (BL=1 writes, via MRS).
//  1. CL=2 and CL=3, BL=1: READ col0 at k, READ col1 at k+1 -> 1111 at k+CL, 2222 at k+CL+1.
//  2. CL=2 and CL=3, BL=1: READ col2 at k, READ col3 at k+2 (one NOP between) -> 3333 at k+CL,
//     Hi-Z at k+CL+1, 4444 at k+CL+2.
//  3. CL=2 and CL=3, BL=4: READ col0 at k, READ col2 at k+1 -> 1111 at k+CL (the first burst's
//     beat 0), then the second burst replaces it: 3333 at k+CL+1, 4444 at k+CL+2, and the
//     first burst's remaining beats never appear.
//  4. CL=2 and CL=3, BL=1: DQM (A11 = low byte) high on edge k+CL-2 masks the low byte of the
//     word capturable on edge k+CL (the high byte still arrives); one clock earlier or later it
//     does not.
//  "k" is the edge on which the chip samples the READ; a word "at k+n" is the bus value the
//  controller captures on edge k+n (seen half a clock after launch edge k+n-1).

`default_nettype none

module tb_pc9821_xsds_readpipe;
  localparam real TCK = 12.5;
  reg clk = 1'b0;
  always #(TCK / 2.0) clk = ~clk;

  reg        cs_n = 1'b0, ras_n = 1'b1, cas_n = 1'b1, we_n = 1'b1;
  reg  [1:0] ba   = 2'b00;
  reg [12:0] addr = 13'd0;
  reg [15:0] dq_drv = 16'h0000;
  reg        dq_en  = 1'b0;
  wire [15:0] dq = dq_en ? dq_drv : 16'hzzzz;

  // ==== DUT ====
  xsds_128mbyte_sdram_model #(
      .DEBUG(1'b0), .STRICT_TIMING(1'b1), .WARN_TREFI(1'b0), .INIT_UNWRITTEN_TO_X(1'b0)
  ) model (.Clk(clk), .Cs1_n(cs_n), .Ras_n(ras_n), .Cas_n(cas_n), .We_n(we_n),
           .Ba(ba), .Addr(addr), .Dq(dq));

  integer errors = 0;
  integer checks = 0;

  // The bus as seen at each negedge after the command-issuing negedge, index = clocks later.
  reg [15:0] seen [0:15];

  // Drive one command at the next negedge (the chip samples it on the following posedge).
  task automatic cmd(input r, input c, input w, input [1:0] b, input [12:0] a);
    begin
      @(negedge clk);
      ras_n = r; cas_n = c; we_n = w; ba = b; addr = a; dq_en = 1'b0;
    end
  endtask
  task automatic nop(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) cmd(1'b1, 1'b1, 1'b1, 2'b00, 13'd0);
    end
  endtask
  task automatic wr(input [9:0] col, input [15:0] d);
    begin
      cmd(1'b1, 1'b0, 1'b0, 2'b00, {3'b000, col});
      dq_drv = d; dq_en = 1'b1;
    end
  endtask

  // Record the bus at every negedge from the one that follows `start` on.
  integer clkn = 0;
  always @(negedge clk) begin
    #1;                                  // after the command-driving code of this negedge
    clkn = clkn + 1;
    if (clkn >= 0 && clkn < 16) seen[clkn] = dq;
  end

  task automatic expect_bus(input integer slot, input [15:0] want, input [8*48-1:0] tag);
    begin
      checks = checks + 1;
      if (seen[slot] !== want) begin
        $display("FAIL %0s: clock +%0d bus %04h, want %04h", tag, slot, seen[slot], want);
        errors = errors + 1;
      end
    end
  endtask

  // READ driven at negedge 0; the chip samples it on the posedge half a clock later, so the
  // datum for CL clocks after that edge is on the bus at negedge CL+1 (index = slot below).
  // A READ whose slot-j command cycle (j = 0 is the READ itself) carries A11 = 1, the DQML pin.
  task automatic rd_dqm(input [9:0] col, input integer j);
    integer n;
    begin
      cmd(1'b1, 1'b0, 1'b1, 2'b00, {1'b0, (j == 0), 1'b0, col});
      clkn = -1;
      for (n = 1; n <= j; n = n + 1)
        cmd(1'b1, 1'b1, 1'b1, 2'b00, (n == j) ? 13'h0800 : 13'h0000);
    end
  endtask

  task automatic rd_start(input [9:0] col);
    begin
      cmd(1'b1, 1'b0, 1'b1, 2'b00, {3'b000, col});
      clkn = -1;                         // this negedge samples as index 0 (1 ns later)
    end
  endtask

  task automatic mrs(input integer cl, input integer bl_code);
    begin
      cmd(1'b0, 1'b0, 1'b0, 2'b00, 13'(cl * 16 + bl_code));  // A[6:4]=CL, A[2:0]=BL code
      nop(2);
    end
  endtask

  task automatic scenario(input integer cl);
    integer i;
    begin
      // The model's init: a 200 us hold, PRE ALL, two AUTO REFRESH, MRS (BL=1), then ACT.
      mrs(cl, 0);                      // BL=1, sequential; A9=0 so writes are BL=1 too
      cmd(1'b0, 1'b1, 1'b1, 2'b00, 13'd0); nop(3);                // ACT bank 0 row 0
      wr(10'd0, 16'h1111); wr(10'd1, 16'h2222); wr(10'd2, 16'h3333); wr(10'd3, 16'h4444);
      nop(4);

      // 1. back-to-back BL=1 reads
      rd_start(10'd0); cmd(1'b1, 1'b0, 1'b1, 2'b00, 13'd1); nop(8);
      expect_bus(cl, 16'h1111, "b2b read word 0 at k+CL");
      expect_bus(cl + 1, 16'h2222, "b2b read word 1 at k+CL+1");
      expect_bus(cl + 2, 16'hzzzz, "bus Hi-Z after the last word");
      nop(4);

      // 2. reads one NOP apart
      rd_start(10'd2); nop(1); cmd(1'b1, 1'b0, 1'b1, 2'b00, 13'd3); nop(8);
      expect_bus(cl, 16'h3333, "gapped read word 0 at k+CL");
      expect_bus(cl + 1, 16'hzzzz, "gapped read: Hi-Z in the gap slot");
      expect_bus(cl + 2, 16'h4444, "gapped read word 1 at k+CL+2");
      nop(4);
      cmd(1'b0, 1'b1, 1'b0, 2'b00, 13'h0400); nop(4);   // PRECHARGE ALL

      // 3. BL=4 burst truncated by a READ one clock later
      mrs(cl, 2);                      // BL=4
      cmd(1'b0, 1'b1, 1'b1, 2'b00, 13'd0); nop(3);
      rd_start(10'd0); cmd(1'b1, 1'b0, 1'b1, 2'b00, 13'd2); nop(10);
      expect_bus(cl, 16'h1111, "BL4 beat 0 survives the next READ");
      expect_bus(cl + 1, 16'h3333, "second burst replaces the first");
      expect_bus(cl + 2, 16'h4444, "second burst beat 1");
      nop(6);
      cmd(1'b0, 1'b1, 1'b0, 2'b00, 13'h0400);   // PRECHARGE ALL
      nop(4);
      mrs(cl, 0);
      cmd(1'b0, 1'b1, 1'b1, 2'b00, 13'd0); nop(3);

      // 4. DQM two clocks before the capture edge masks the low byte of that word
      //    (command slot 0 is the READ's own edge: the masking slot is CL-2)
      rd_dqm(10'd0, cl - 2); nop(8);
      expect_bus(cl, 16'h11zz, "DQM at k+CL-2 masks the low byte");
      nop(2);
      rd_dqm(10'd1, cl - 1); nop(8);
      expect_bus(cl, 16'h2222, "DQM one clock late masks nothing");
      nop(2);
      cmd(1'b0, 1'b1, 1'b0, 2'b00, 13'h0400); nop(4);   // PRECHARGE ALL
      mrs(cl, 0);                      // leave BL=1 for the next scenario (idle banks required)
    end
  endtask

  initial begin
    #2_000_000;                            // a watchdog, not a budget (the run is ~0.5 ms)
    $fatal(1, "TB_PC9821_XSDS_READPIPE: FAIL (watchdog)");
  end

  // ==== CHECKS ====
  initial begin
    #1;
    // power-up: hold NOP for 230 us, then PRECHARGE ALL, two AUTO REFRESH
    cs_n = 1'b0; ras_n = 1'b1; cas_n = 1'b1; we_n = 1'b1;
    #230_000;
    cmd(1'b0, 1'b1, 1'b0, 2'b00, 13'h0400); nop(3);          // PRECHARGE ALL
    cmd(1'b0, 1'b0, 1'b1, 2'b00, 13'd0); nop(6);             // AUTO REFRESH
    cmd(1'b0, 1'b0, 1'b1, 2'b00, 13'd0); nop(6);
    scenario(2);
    scenario(3);

    checks = checks + 1;
    if (model.module_error_count() != 0) begin
      $display("FAIL: the model recorded %0d protocol/timing violation(s)", model.module_error_count());
      errors = errors + 1;
    end
    // ==== VERDICT ====
    $display("TB_PC9821_XSDS_READPIPE: %0d check(s), %0d mismatch(es)", checks, errors);
    if (errors == 0) begin
      $display("TB_PC9821_XSDS_READPIPE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_XSDS_READPIPE: FAIL (%0d errors)", errors);
    end
  end
endmodule

`default_nettype wire

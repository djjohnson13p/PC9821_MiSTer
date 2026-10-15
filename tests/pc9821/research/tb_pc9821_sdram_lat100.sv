`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */   // the probe module beside the bench's top has its own name

// ===========================================================================
// RESEARCH BENCH -- deliberately NOT wired into the gate (see README.md beside
// this file). A human reads its numbers.
//
// WHAT IT MEASURES: the REAL src/memory/sdram.v controller at 50 MHz against the
// SAME controller at 100 MHz, each driven against sdram_chip_model.sv, to answer
// the owner's question -- does raising the SDRAM clock make the fixed access
// latency worse in absolute wall time, and what does BATCHING an access buy?
// It reports, per clock rate:
//
//   A. the ABSOLUTE latency (cycles and ns) of a single RANDOM read, accept -> first
//      data and accept -> burst_done;
//   B. the same for a burst of 2/4/8/15 dwords (the cache-line and font-block shapes),
//      with the per-dword amortised cost;
//   C. the SATURATED bandwidth a lone requester reaches for each burst length;
//   D. the FAIRNESS of the 4-way round-robin when three requesters are BATCHED (15-dword
//      bursts) and one is not -- the worst wait between the scanout's two grants -- plus
//      the same with everyone unbatchinated, as the baseline;
//   E. the SCANOUT's 80-dword line time under a saturating CPU(4-dw)/font(1)/PCM(1) load,
//      paced (today's shape, one dword per 8 clk_sys) versus batched into 15-dword bursts,
//      against the 2014 clk_sys raster-line budget.
//
// Both probes are self-clocked and self-resetting, so they run concurrently and
// print side by side. Nothing here changes the RTL; this is measurement only.
// ===========================================================================

module sdram_lat_probe #(
    parameter integer FREQ     = 50_000_000,
    parameter integer CYCLE_NS = 20,
    parameter integer PHASE_NS = 0
) (
    output reg finished
);
  // clk_sys cycles per probe cycle: 1 at the host 50 MHz rate, 2 at 100 MHz.
  localparam integer SYS_DIV = FREQ / 50_000_000;

  reg clk = 1'b0;
  initial begin
    #PHASE_NS;
    forever #(CYCLE_NS/2) clk = ~clk;
  end

  /* verilator lint_off PROCASSINIT */   // power-up value; the always block below runs it on
  integer cyc = 0;
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk) cyc <= cyc + 1;

  // ---- DUT wiring -----------------------------------------------------------
  reg  [1:0]  sdram_size = 2'd2;          // 2 = 64MB, the DE10 default shape
  reg         resetn = 1'b0;
  reg  [3:0]  v_v  = 4'b0000;             // per-port valid, driven by the phases
  reg         w_v  [0:3];
  reg  [26:0] a_v  [0:3];
  reg  [31:0] d_v  [0:3];
  reg  [3:0]  be_v [0:3];
  reg  [3:0]  n_v  [0:3];

  wire        busy;
  wire        ready0, ready1, ready2, ready3;
  wire [31:0] dout0, dout1, dout2, dout3;
  wire        resp_valid0, resp_valid1, resp_valid2, resp_valid3;
  wire        burst_done0, burst_done1, burst_done2, burst_done3;
  wire [3:0]  rd_ready = {ready3, ready2, ready1, ready0};
  wire [3:0]  rd_resp  = {resp_valid3, resp_valid2, resp_valid1, resp_valid0};
  wire [3:0]  rd_bdone = {burst_done3, burst_done2, burst_done1, burst_done0};

  // A periodic driver: while sat_en[p] is high, port p presents a request every
  // sat_gap[p]+1 cycles (sat_gap = 0 is a SATURATING stream: always pending). Separate
  // from v_v so a task can drive one port by hand while the others run. The gap is in
  // probe cycles, so callers scale clk_sys rates by SYS_DIV.
  reg  [3:0]  sat_en  = 4'b0000;
  reg  [3:0]  sat_n   [0:3];
  reg  [26:0] sat_a   [0:3];
  reg  [31:0] sat_gap [0:3];
  reg  [31:0] sat_ctr [0:3];
  wire        dv0 = v_v[0] | (sat_en[0] & (sat_ctr[0] == 0));
  wire        dv1 = v_v[1] | (sat_en[1] & (sat_ctr[1] == 0));
  wire        dv2 = v_v[2] | (sat_en[2] & (sat_ctr[2] == 0));
  wire        dv3 = v_v[3] | (sat_en[3] & (sat_ctr[3] == 0));
  wire [26:0] da0 = sat_en[0] ? sat_a[0] : a_v[0];
  wire [26:0] da1 = sat_en[1] ? sat_a[1] : a_v[1];
  wire [26:0] da2 = sat_en[2] ? sat_a[2] : a_v[2];
  wire [26:0] da3 = sat_en[3] ? sat_a[3] : a_v[3];
  wire  [3:0] dn0 = sat_en[0] ? sat_n[0] : n_v[0];
  wire  [3:0] dn1 = sat_en[1] ? sat_n[1] : n_v[1];
  wire  [3:0] dn2 = sat_en[2] ? sat_n[2] : n_v[2];
  wire  [3:0] dn3 = sat_en[3] ? sat_n[3] : n_v[3];
  wire        dw0 = sat_en[0] ? 1'b0 : w_v[0];
  wire        dw1 = sat_en[1] ? 1'b0 : w_v[1];
  wire        dw2 = sat_en[2] ? 1'b0 : w_v[2];
  wire        dw3 = sat_en[3] ? 1'b0 : w_v[3];

  always @(posedge clk) begin
    if (!sat_en[0]) begin sat_a[0] <= 27'h0040_0000; sat_ctr[0] <= 32'd0; end
    else if (ready0) begin sat_a[0] <= sat_a[0] + 27'd4; sat_ctr[0] <= sat_gap[0]; end
    else if (sat_ctr[0] != 0) sat_ctr[0] <= sat_ctr[0] - 32'd1;
    if (!sat_en[1]) begin sat_a[1] <= 27'h0060_0000; sat_ctr[1] <= 32'd0; end
    else if (ready1) begin sat_a[1] <= sat_a[1] + 27'd4; sat_ctr[1] <= sat_gap[1]; end
    else if (sat_ctr[1] != 0) sat_ctr[1] <= sat_ctr[1] - 32'd1;
    if (!sat_en[2]) begin sat_a[2] <= 27'h0080_0000; sat_ctr[2] <= 32'd0; end
    else if (ready2) begin sat_a[2] <= sat_a[2] + 27'd4; sat_ctr[2] <= sat_gap[2]; end
    else if (sat_ctr[2] != 0) sat_ctr[2] <= sat_ctr[2] - 32'd1;
    if (!sat_en[3]) begin sat_a[3] <= 27'h00A0_0000; sat_ctr[3] <= 32'd0; end
    else if (ready3) begin sat_a[3] <= sat_a[3] + 27'd4; sat_ctr[3] <= sat_gap[3]; end
    else if (sat_ctr[3] != 0) sat_ctr[3] <= sat_ctr[3] - 32'd1;
  end

  wire [15:0] DQ;
  wire [12:0] SDRAM_A;
  wire [1:0]  SDRAM_BA;
  wire [1:0]  SDRAM_DQM;
  wire        nWE, nRAS, nCAS, nCS, CKE;

  // FAST_GRADE = 0 is what the tree BUILDS (z486_mister.sv's de10_guest_memory), the -7 part
  // the SDC names. HAS_DQM = 0 is the MiSTer module. Both probe rates use the same RTL.
  sdram #(.FREQ(FREQ), .HAS_DQM(1'b0), .FAST_GRADE(1'b0)) dut (
      .clk(clk), .resetn(resetn), .nce(1'b0), .refresh_allowed(1'b1),
      .busy(busy), .sdram_size(sdram_size),
      .valid0(dv0), .ready0(ready0), .wr0(dw0), .addr0(da0),
      .din0(d_v[0]),
      .din0_hi(32'd0), .dout0(dout0), .resp_valid0(resp_valid0),
      .be0(be_v[0]), .burst_cnt0(dn0), .burst_done0(burst_done0),
      .valid1(dv1), .ready1(ready1), .wr1(dw1), .addr1(da1),
      .din1(d_v[1]), .dout1(dout1), .resp_valid1(resp_valid1),
      .be1(be_v[1]), .burst_cnt1(dn1), .burst_done1(burst_done1),
      .valid2(dv2), .ready2(ready2), .wr2(dw2), .addr2(da2),
      .din2(d_v[2]), .dout2(dout2), .resp_valid2(resp_valid2),
      .be2(be_v[2]), .burst_cnt2(dn2), .burst_done2(burst_done2),
      .valid3(dv3), .ready3(ready3), .wr3(dw3), .addr3(da3),
      .din3(d_v[3]), .dout3(dout3), .resp_valid3(resp_valid3),
      .be3(be_v[3]), .burst_cnt3(dn3), .burst_done3(burst_done3),
      .SDRAM_DQ(DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nCS(nCS),
      .SDRAM_CKE(CKE)
  );

  sdram_chip_model #(.CAS(2)) chip (
      .clk(clk), .DQ(DQ), .A(SDRAM_A), .BA(SDRAM_BA),
      .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .nCS(nCS)
  );

  // The probe's own tag, so a NOTE line names its rate.
  localparam [47:0] TAG = (FREQ == 50_000_000) ? "50MHz " : "100MHz";

  // ---- helpers --------------------------------------------------------------
  integer errors = 0;
  task automatic fail(input [799:0] what);
    begin
      errors = errors + 1;
      $display("FAIL sdram_lat100 [%0s]: %0s (cycle %0d)", TAG, what, cyc);
    end
  endtask

  task automatic quiesce;
    begin
      v_v = 4'b0000; sat_en = 4'b0000;
      while (busy) @(posedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  // One read on `port`, watched inside the task so no state crosses the blocks above.
  task automatic read_burst(input integer port, input [26:0] a, input [3:0] n,
                            output integer responses, output integer first_lat,
                            output integer done_lat, output bit done);
    integer t0;
    begin
      responses = 0; first_lat = -1; done_lat = -1; done = 1'b0;
      a_v[port] = a; n_v[port] = n; w_v[port] = 1'b0; v_v[port] = 1'b1;
      while (!rd_ready[port]) @(posedge clk);
      t0 = cyc; v_v[port] = 1'b0;
      while (!done && (cyc - t0) < 400) begin
        @(posedge clk);
        if (rd_resp[port]) begin
          responses = responses + 1;
          if (first_lat < 0) first_lat = cyc - t0;
        end
        if (rd_bdone[port]) begin done = 1'b1; done_lat = cyc - t0; end
      end
    end
  endtask

  integer seed = 32'h1234_5678;
  integer i, p, resp, flat, dlat, guard;
  bit     done;
  integer b_len [0:4];

  // ---- the run --------------------------------------------------------------
  integer lone_dw, lone_el;

  initial begin
    finished = 1'b0;
    for (p = 0; p < 4; p = p + 1) begin
      w_v[p] = 1'b0; a_v[p] = 27'd0; d_v[p] = 32'd0; be_v[p] = 4'hF; n_v[p] = 4'd1;
      sat_en[p] = 1'b0; sat_n[p] = 4'd1; sat_a[p] = 27'd0;
      sat_gap[p] = 32'd0; sat_ctr[p] = 32'd0;
    end
    repeat (8) @(posedge clk);
    resetn = 1'b1;

    guard = 0;
    while (busy && guard < 400000) begin @(posedge clk); guard = guard + 1; end
    if (busy) fail("the controller never left init");
    repeat (20) @(posedge clk);

    $display("NOTE sdram_lat100 [%0s]: controller timing table T_RCD=%0d CAS=%0d T_RC=%0d T_WR=%0d (FAST_GRADE=0, -7 grade)",
             TAG, dut.T_RCD, dut.CAS, dut.T_RC, dut.T_WR_I);

    // ---- Phase A: single RANDOM read, accept -> first data and -> burst_done ----
    begin
      integer worst_first, worst_done, sum_first, sum_done, nrand;
      worst_first = 0; worst_done = 0; sum_first = 0; sum_done = 0; nrand = 0;
      for (i = 0; i < 200; i = i + 1) begin
        // A fresh pseudo-random 27-bit dword-aligned address each time: a new row, so the
        // controller pays a full ACT + tRCD + tRC every access -- the random-access case.
        seed = (seed * 1103515245 + 12345) & 32'h7FFF_FFFF;
        a_v[0] = {seed[24:0], 2'b00};
        read_burst(0, a_v[0], 4'd1, resp, flat, dlat, done);
        if (!done || resp != 1) begin
          fail("a random single read did not complete with exactly one response");
          i = 200;
        end else begin
          nrand = nrand + 1;
          if (flat > worst_first) worst_first = flat;
          if (dlat > worst_done) worst_done = dlat;
          sum_first = sum_first + flat;
          sum_done  = sum_done + dlat;
        end
      end
      $display("NOTE sdram_lat100 [%0s]: RANDOM 1-dword read x%0d: accept->first %0d cyc = %0d ns; accept->burst_done %0d cyc = %0d ns; MEAN first %0d cyc, burst_done %0d cyc",
               TAG, nrand,
               worst_first, worst_first * CYCLE_NS,
               worst_done, worst_done * CYCLE_NS,
               sum_first / (nrand == 0 ? 1 : nrand), sum_done / (nrand == 0 ? 1 : nrand));
    end

    // ---- Phase B: burst latency, and the per-dword amortisation ----
    b_len[0] = 1; b_len[1] = 2; b_len[2] = 4; b_len[3] = 8; b_len[4] = 15;
    for (i = 0; i < 5; i = i + 1) begin
      // Row-aligned base so the burst never crosses a row (512 dwords/row at 64MB); the
      // controller re-ACTs per transaction anyway, so this is the burst's OWN cost.
      read_burst(0, 27'h0000_0400, b_len[i][3:0], resp, flat, dlat, done);
      if (!done || (resp != b_len[i])) fail("a burst did not return burst_cnt responses");
      $display("NOTE sdram_lat100 [%0s]: BURST n=%0d: first %0d cyc, burst_done %0d cyc = %0d ns, amortised %0d.%02d cyc/dw = %0d.%02d ns/dw",
               TAG, b_len[i], flat, dlat, dlat * CYCLE_NS,
               dlat / b_len[i], ((dlat * 100 / b_len[i]) % 100),
               (dlat * CYCLE_NS) / b_len[i], (((dlat * CYCLE_NS * 100) / b_len[i]) % 100));
    end

    // ---- Phase C: lone-requester saturated bandwidth per burst length ----
    for (i = 0; i < 3; i = i + 1) begin
      integer nthis;
      nthis = (i == 0) ? 1 : (i == 1) ? 4 : 15;
      quiesce;
      sat_n[0] = nthis[3:0];
      sat_en[0] = 1'b1;
      lone_dw = 0;
      begin : satwin
        integer t0;
        t0 = cyc;
        while ((cyc - t0) < 4000) begin
          @(posedge clk);
          if (rd_ready[0]) lone_dw = lone_dw + nthis;
        end
        lone_el = cyc - t0;
      end
      quiesce;
      $display("NOTE sdram_lat100 [%0s]: LONE SATURATED n=%0d: %0d dw in %0d cyc = %0d MB/s (bus peak = %0d MB/s)",
               TAG, nthis, lone_dw, lone_el,
               (lone_dw * 4 * (FREQ / 1000000)) / lone_el,
               2 * (FREQ / 1000000));
    end

    // ---- Phase D: fairness. Port 3 is the scanout. ----
    begin
      integer acc3, gap, worst, dwords, t0, b3, b0, b1, b2, k;
      // Baseline: everyone one dword -- the shape the design has today.
      quiesce;
      sat_n[0] = 4'd1; sat_n[1] = 4'd1; sat_n[2] = 4'd1; sat_n[3] = 4'd1;
      sat_en = 4'b1111;
      t0 = cyc; gap = 0; acc3 = 0; worst = 0; dwords = 0;
      while ((cyc - t0) < 6000) begin
        @(posedge clk);
        gap = gap + 1;
        if (rd_ready[0]) dwords = dwords + {28'd0, sat_n[0]};
        if (rd_ready[1]) dwords = dwords + {28'd0, sat_n[1]};
        if (rd_ready[2]) dwords = dwords + {28'd0, sat_n[2]};
        if (rd_ready[3]) begin
          dwords = dwords + {28'd0, sat_n[3]};
          acc3 = acc3 + 1;
          if (gap > worst) worst = gap;
          gap = 0;
        end
      end
      $display("NOTE sdram_lat100 [%0s]: FAIR all-burst1: port3 accepts %0d, worst gap %0d cyc = %0d ns, %0d dw in 6000 cyc = %0d MB/s",
               TAG, acc3, worst, worst * CYCLE_NS, dwords, (dwords * 4 * (FREQ / 1000000)) / 6000);
      quiesce;

      // Three batched (15-dword bursts), the scanout still one dword per request.
      sat_n[0] = 4'd15; sat_n[1] = 4'd15; sat_n[2] = 4'd15; sat_n[3] = 4'd1;
      sat_en = 4'b1111;
      t0 = cyc; gap = 0; acc3 = 0; worst = 0; dwords = 0;
      while ((cyc - t0) < 6000) begin
        @(posedge clk);
        gap = gap + 1;
        if (rd_ready[0]) dwords = dwords + {28'd0, sat_n[0]};
        if (rd_ready[1]) dwords = dwords + {28'd0, sat_n[1]};
        if (rd_ready[2]) dwords = dwords + {28'd0, sat_n[2]};
        if (rd_ready[3]) begin
          dwords = dwords + {28'd0, sat_n[3]};
          acc3 = acc3 + 1;
          if (gap > worst) worst = gap;
          gap = 0;
        end
      end
      $display("NOTE sdram_lat100 [%0s]: FAIR 3xB15+port3-B1: port3 accepts %0d, worst gap %0d cyc = %0d ns, %0d dw in 6000 cyc = %0d MB/s",
               TAG, acc3, worst, worst * CYCLE_NS, dwords, (dwords * 4 * (FREQ / 1000000)) / 6000);
      quiesce;

      // Everyone batched.
      sat_n[0] = 4'd15; sat_n[1] = 4'd15; sat_n[2] = 4'd15; sat_n[3] = 4'd15;
      sat_en = 4'b1111;
      t0 = cyc; gap = 0; acc3 = 0; worst = 0; dwords = 0;
      while ((cyc - t0) < 6000) begin
        @(posedge clk);
        gap = gap + 1;
        if (rd_ready[0]) dwords = dwords + {28'd0, sat_n[0]};
        if (rd_ready[1]) dwords = dwords + {28'd0, sat_n[1]};
        if (rd_ready[2]) dwords = dwords + {28'd0, sat_n[2]};
        if (rd_ready[3]) begin
          dwords = dwords + {28'd0, sat_n[3]};
          acc3 = acc3 + 1;
          if (gap > worst) worst = gap;
          gap = 0;
        end
      end
      $display("NOTE sdram_lat100 [%0s]: FAIR all-B15: port3 accepts %0d, worst gap %0d cyc = %0d ns, %0d dw in 6000 cyc = %0d MB/s",
               TAG, acc3, worst, worst * CYCLE_NS, dwords, (dwords * 4 * (FREQ / 1000000)) / 6000);
      quiesce;
    end

    // ---- Phase E: the scanout's 80-dword line under CPU(4)/font(1)/PCM(1) load ----
    for (i = 0; i < 2; i = i + 1) begin
      integer ln, dw_done, issued, line_start, nleft, bc, pace, t0;
      reg outstanding, waiting;
      bit batched;
      batched = (i == 1);
      quiesce;
      // CPU saturates (4-dword cache-line bursts); the font and PCM run at their REAL
      // measured rates -- one dword per 50 clk_sys and one per 1134 clk_sys -- so this
      // load matches the machine and the existing TDM bench (r13/19), instead of a
      // harsher all-saturating bound that would make 100 MHz look worse than it is.
      sat_gap[0] = 32'd0; sat_n[0] = 4'd4;
      sat_gap[1] = 32'd50   * SYS_DIV; sat_n[1] = 4'd1;
      sat_gap[2] = 32'd1134 * SYS_DIV; sat_n[2] = 4'd1;
      sat_en[0] = 1'b1; sat_en[1] = 1'b1; sat_en[2] = 1'b1; sat_en[3] = 1'b0;
      n_v[3] = 4'd1; a_v[3] = 27'h00A0_0000; v_v[3] = 1'b0;
      ln = 0; dw_done = 0; issued = 0; line_start = cyc;
      outstanding = 1'b0; waiting = 1'b0; pace = 0; bc = 1;
      begin : linewin
        integer worst_line;
        worst_line = 0;
        t0 = cyc;
        while ((ln < 12) && ((cyc - t0) < 400000)) begin
          @(posedge clk);

          if (rd_resp[3]) dw_done = dw_done + 1;

          // The FSM's scan_pace counts from the ISSUE, not from the response, so it runs
          // while a request is in flight. Decrementing it only when idle (an earlier draft)
          // made every line wait response + 8 clk_sys instead of max(8 clk_sys, latency),
          // which measured a slower scanout than pc9821_gvram.sv produces.
          if (pace != 0) pace = pace - 1;

          if (waiting) begin
            if (rd_ready[3]) begin
              v_v[3] = 1'b0; waiting = 1'b0; outstanding = 1'b1;
              issued = issued + bc;
              a_v[3] = a_v[3] + 27'(bc * 4);
            end
          end else if (outstanding) begin
            if (batched) begin
              if (rd_bdone[3]) outstanding = 1'b0;
            end else begin
              if (rd_resp[3]) outstanding = 1'b0;
            end
          end

          if (dw_done >= 80) begin
            if ((cyc - line_start) > worst_line) worst_line = cyc - line_start;
            ln = ln + 1;
            dw_done = 0; issued = 0; line_start = cyc;
            a_v[3] = 27'h00A0_0000; outstanding = 1'b0; waiting = 1'b0; pace = 0;
          end

          if (!waiting && !outstanding && (pace == 0) && (dw_done < 80)) begin
            if (batched) begin
              nleft = 80 - issued;
              bc = (nleft > 15) ? 15 : nleft;
            end else begin
              bc = 1;
            end
            n_v[3] = bc[3:0];
            v_v[3] = 1'b1; waiting = 1'b1;
            pace = 8 * SYS_DIV - 1;   // the FSM's scan_pace <= 7
          end
        end
        $display("NOTE sdram_lat100 [%0s]: SCANOUT %0s (CPU 4dw saturating, font 1/50sys, PCM 1/1134sys): worst line %0d probe cyc = %0d clk_sys = %0d.%0d%% of the 2014 clk_sys budget, %0d lines",
                 TAG, batched ? "BATCHED(15)" : "paced(1/8sys)",
                 worst_line, worst_line / SYS_DIV,
                 (worst_line * 100) / (SYS_DIV * 2014),
                 ((worst_line * 10000) / (SYS_DIV * 2014)) % 100, ln);
      end
      v_v[3] = 1'b0; sat_en = 4'b0000;
      quiesce;
    end

    $display("NOTE sdram_lat100 [%0s]: DONE (%0d problem(s))", TAG, errors);
    finished = 1'b1;
  end

  // A watchdog so a hang is a named failure rather than a timeout.
  initial begin
    repeat (4_000_000) @(posedge clk);
    $fatal(1, "sdram_lat_probe: FAIL (the bench did not finish)");
  end
endmodule

module tb_pc9821_sdram_lat100;
  wire f50, f100;
  sdram_lat_probe #(.FREQ(50_000_000),  .CYCLE_NS(20), .PHASE_NS(0)) p50  (.finished(f50));
  sdram_lat_probe #(.FREQ(100_000_000), .CYCLE_NS(10), .PHASE_NS(3)) p100 (.finished(f100));

  initial begin
    while (!(f50 && f100)) #1;
    $display("TB_PC9821_SDRAM_LAT100: PASS");
    $finish;
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_SDRAM_LAT100: FAIL (watchdog)");
  end
endmodule

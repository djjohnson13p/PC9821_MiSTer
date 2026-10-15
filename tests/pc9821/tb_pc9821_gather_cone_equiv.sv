`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GATHER_CONE_EQUIV: the gather-RMW write-data cone (gk_n/gk_be/gk_wc -> gk_wmap -> gk_wdat -> dq_out) is value-identical between the pre-cut byte-merge tail (the reference) and the shipped per-entry merged-word tail over a representative sweep of the session-entry count, every per-entry byte-enable class, the write-phase slot counter and four distinct store/read-back word shapes, so a wrong merge rewrite diverges and fails by name while the value-identical rewrite passes.
//
// The reference is the PRE-CHANGE expression (gk_ws_nd/gk_ws_od/gk_ws_be muxed then
// per-byte selected), transcribed verbatim from the pre-cut src/memory/sdram.v (the
// verbatim-ness was checked by script when it was extracted). The DUT is the shipped
// per-entry merged word (gk_mword) + single half select (the sdram-hunt Class-1 depth cut,
// 14 -> 12 ABC 4-LUT levels on the cone). The FULL input space was proven separately by
// SAT over all 280 free input bits (with an old-vs-old control); this bench is the simulation leg over the reachable cone.
//
// FAIL-FIRST: a planted wrong merge (one byte's new/old select inverted) diverges and
// fails by name at once; the value-identical rewrite passes (see the report's plant run).
//
// Warrant: src/memory/sdram.v's gk_slot_maps + the write stream's merge, and the
// sdram-hunt depth cut.

module tb_pc9821_gather_cone_equiv;

  // ==== DUT ====
  reg  [3:0]       gk_n   = 4'd1;
  reg  [3:0][3:0]  gk_be  = 16'h0;
  reg  [3:0]       gk_wc  = 4'd0;
  reg  [3:0][31:0] gk_din = 128'h0;
  reg  [3:0][31:0] gk_old = 128'h0;

  wire [15:0] ref_wdat, dut_wdat;
  wire  [3:0] ref_wmap5, dut_wmap5;
  wire  [5:0] ref_rtot, dut_rtot, ref_wtot, dut_wtot;

  gath_cone_old   u_ref (.gk_n(gk_n), .gk_be(gk_be), .gk_wc(gk_wc),
                       .gk_din(gk_din), .gk_old(gk_old),
                       .gk_wdat(ref_wdat), .gk_wmap5(ref_wmap5),
                       .gk_rtot(ref_rtot), .gk_wtot(ref_wtot));
  gath_cone_merge u_dut (.gk_n(gk_n), .gk_be(gk_be), .gk_wc(gk_wc),
                       .gk_din(gk_din), .gk_old(gk_old),
                       .gk_wdat(dut_wdat), .gk_wmap5(dut_wmap5),
                       .gk_rtot(dut_rtot), .gk_wtot(dut_wtot));

  // ==== CHECKS ====
  integer errors = 0;
  integer checks = 0;
  task automatic fail(input [1023:0] what);
    begin
      errors = errors + 1;
      $display("FAIL gather_cone_equiv: %0s (gk_n=%0d gk_wc=%0d be=%08h)",
               what, gk_n, gk_wc, gk_be);
    end
  endtask

  task automatic compare;
    begin
      checks = checks + 1;
      if (dut_wdat  !== ref_wdat)  fail("gk_wdat diverged");
      if (dut_wmap5 !== ref_wmap5) fail("gk_wmap5 diverged");
      if (dut_rtot  !== ref_rtot)  fail("gk_rtot diverged");
      if (dut_wtot  !== ref_wtot)  fail("gk_wtot diverged");
    end
  endtask

  // A watchdog: the sweep is finite and must finish well before this fires.
  initial begin
    #10_000_000;
    $fatal(1, "TB_PC9821_GATHER_CONE_EQUIV: watchdog (the sweep did not finish)");
  end

  // ==== STIMULUS ====
  // Per-entry byte-enable classes: 0 (skip), singles, whole halves (3, C, F), partial
  // halves (1, 2, 4, 8), and the remaining mixed codes so every new/old + half split is
  // reached. A few multi-entry combinations close the session-shape cover.
  reg [3:0] be_class [0:15];
  initial begin
    be_class[0]  = 4'h0; be_class[1]  = 4'h1; be_class[2]  = 4'h2;
    be_class[3]  = 4'h3; be_class[4]  = 4'h4; be_class[5]  = 4'h5;
    be_class[6]  = 4'h6; be_class[7]  = 4'h7; be_class[8]  = 4'h8;
    be_class[9]  = 4'h9; be_class[10] = 4'hA; be_class[11] = 4'hB;
    be_class[12] = 4'hC; be_class[13] = 4'hD; be_class[14] = 4'hE;
    be_class[15] = 4'hF;
  end

  integer n, c, wc, dp;
  reg [15:0] be_vec [0:31];
  integer n_be_vec = 0;
  reg [31:0] din_vec [0:3];
  reg [31:0] old_vec [0:3];

  initial begin
    // Distinct, bit-exercising words per entry so any byte/bit merge error shows in gk_wdat.
    din_vec[0] = 32'hDEAD_BEEF; old_vec[0] = 32'h1234_5678;
    din_vec[1] = 32'h89AB_CDEF; old_vec[1] = 32'hA5A5_5A5A;
    din_vec[2] = 32'hF0E1_D2C3; old_vec[2] = 32'h0F1E_2D3C;
    din_vec[3] = 32'hCAFE_0001; old_vec[3] = 32'h0000_FFFF;

    // Uniform classes repeated across all four entries (each active entry sees the class).
    for (c = 0; c < 16; c = c + 1) begin
      be_vec[n_be_vec] = {be_class[c], be_class[c], be_class[c], be_class[c]};
      n_be_vec = n_be_vec + 1;
    end
    // Mixed multi-entry shapes (whole/partial/skip interleavings).
    be_vec[n_be_vec] = 16'hFC31; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h1248; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h5A69; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h0FF0; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h7BDE; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'hF0F0; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h0F0F; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h3333; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'hCCCC; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'hFFFF; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h0000; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'hAAAA; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h5555; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'hA5C3; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h3C5A; n_be_vec = n_be_vec + 1;
    be_vec[n_be_vec] = 16'h0001; n_be_vec = n_be_vec + 1;

    for (n = 1; n <= 4; n = n + 1) begin
      gk_n = n[3:0];
      for (c = 0; c < n_be_vec; c = c + 1) begin
        gk_be = be_vec[c];
        for (wc = 0; wc < 8; wc = wc + 1) begin
          gk_wc = wc[3:0];
          for (dp = 0; dp < 4; dp = dp + 1) begin
            case (dp)
              0: gk_din = {din_vec[3], din_vec[2], din_vec[1], din_vec[0]};
              1: gk_din = {din_vec[0], din_vec[3], din_vec[2], din_vec[1]};
              2: gk_din = {din_vec[1], din_vec[0], din_vec[3], din_vec[2]};
              3: gk_din = {din_vec[2], din_vec[1], din_vec[0], din_vec[3]};
            endcase
            gk_old = {old_vec[3], old_vec[2], old_vec[1], old_vec[0]};
            #1;
            compare;
          end
        end
      end
    end

    // ==== VERDICT ====
    if (errors != 0)
      $fatal(1, "TB_PC9821_GATHER_CONE_EQUIV: %0d cone mismatches over %0d checks", errors, checks);
    $display("TB_PC9821_GATHER_CONE_EQUIV: PASS");
    $display("NOTE gather_cone_equiv: cone matched the reference on %0d input vectors", checks);
    $finish;
  end
endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SDRAM_STRICT:
// The platform's SDRAM controller, at the platform's OWN settings (FREQ 80 MHz - clk_sys, which the controller runs on - HAS_DQM=0 with ADQM=1 so the byte mask rides A11/A12, FAST_GRADE=0, a 128 MB module, GATHER_K=4 and PRE_ACT on), is driven against the MiSTer community's STRICT XSDS module model - the two-chip AS4C32M16SB-6TIN board, with CHE indact to VCC and DQML/DQMH strapped to A11/A12 - and the MODULE ITSELF is the judge: every command it sees is decoded against the CONTROLLER_GUIDE's protocol and AC-timing rules, every AUTO REFRESH is recorded per chip, and a single violation anywhere in the run fails this bench through the model's own error count rather than through anything this bench believes. The traffic is a real one: the power-up hold the model requires, a dword write/read-back walk across BOTH chips and across rows and banks, byte-masked writes (the mask-on-address path the XSDS board forces), a burst read spanning a row boundary, and a port-0 gather session. The module is clocked the MiSTer way - by the forwarded SDRAM_CLK, lagging the controller clock by the pin-clock lead the configuration's STA I/O model implies, with read data returning through the FPGA's I/O path - so the controller's DQ capture register samples the module where the fit's STA places that capture, about 1 ns before the module's CAS-latency edge.
//
// WHY. Three benches already check THIS controller, and all three check it against our own
// understanding of it (tb_pc9821_sdram_act, _preact, _gather_map). The community model is an
// independent authority derived from the official schematic and the AS4C32M16SB datasheet, and
// its CONTROLLER_GUIDE states the rules a controller must follow - including two this platform
// has never been able to test: that BOTH chips must be refreshed independently (8192 AUTO
// REFRESH per chip per 64 ms) and that CS1_n selects a chip rather than deselecting the module.
// The strict model flags a violation as $error and counts it, so "we pass it" is evidence and
// not an opinion.
//
// SCOPE: this is the CONTROLLER's contract, not the core's. Nothing here says the platform
// drives the controller correctly - only that what the controller puts on the pins is legal.
//
// FAIL-FIRST BY CONSTRUCTION: the model is instantiated with STRICT_TIMING=1, so a protocol or
// timing violation during the walk sets its error count and the verdict below fails.

`default_nettype none

module tb_pc9821_sdram_strict;
  // The platform's deployed settings (z486_mister.sv): the controller on clk_sys, 80 MHz in the
  // shipped build (build_profile.py base), and the XSDS board's wiring. FREQ is a PARAMETER so
  // the same walk can be judged at every clock a build configuration can give it
  // (`-GFREQ=...`: 100/120 MHz for mediumoc/heavyoc, 50 MHz for a custom build).
  //
  // HISTORY: this bench
  // was red at every clock because the community model mis-modelled READs, not because the
  // controller was wrong - it restarted its CAS-latency count on every READ (dropping the first of
  // the controller's two back-to-back BL=1 READs per dword), launched read data one clock late,
  // and forced the bus Hi-Z at the edge the previous beat is captured on. Those are LOCAL FIXes in
  // tests/pc9821/xsds_128mbyte_sdram_model.sv, pinned by tb_pc9821_xsds_readpipe. The gather
  // check's own stimulus also had a typo (0x1100 for "byte 0 = 0x11"): fixed to 0x0011.
  parameter  integer FREQ   = 80_000_000;
  localparam real    TCK_NS = 1e9 / FREQ;        // 12.5 ns at 80 MHz
  localparam integer POWERUP_CYCLES = (FREQ / 1_000_000) * 230;   // 230 us > the model's 200 us

  reg clk = 1'b0;
  always #(TCK_NS / 2.0) clk = ~clk;

  // ==== THE BOARD: the MiSTer pin clock and the FPGA's I/O path ====
  // On MiSTer the module is NOT clocked by the controller's clock: SDRAM_CLK is a forwarded,
  // phase-shifted copy (here a PLL output at tools/profile_gen.py's derived phase; Template
  // cores use an altddio_out at 180 degrees, Genesis_MiSTer's
  // rtl/sdram.sv:248-249), and the read data comes back to the controller's IOE input register
  // (dq_r, FAST_INPUT_REGISTER, sys/sys.tcl:97) through the pad and input path. So this bench
  // gives the module its own clock and a read-return delay, with the controller unchanged:
  //   * PIN_LEAD  - the module's clock edge lags the controller edge that launched the command
  //     or write data by this much (the FPGA's output path folded in: only the lead between
  //     the pin change and the module's edge is visible to the module's tIS/tIH/tDS/tDH);
  //   * DQ_RETURN - the module's DQ reaches dq_r this much later.
  // Both come from the configuration's STA I/O model (tools/profile_gen.py IO_MODEL at the
  // derived phase, all four corners), NOT from the controller: PIN_LEAD is the centre of the
  // command window [tIS + min out_setup, T - tIH - min out_hold], and DQ_RETURN places the
  // dq_r sample at the centre of the read window [tAC - T + min in_setup, tOH - min in_hold]
  // relative to the module's CAS-latency edge (-0.961 ns; the window is -4.18..+2.25 ns below
  // ~95 MHz). Below ~95 MHz
  // the lead is T - 3.743 ns and the return a constant 4.704 ns. A negative PIN_LEAD_PS means "derive".
  // The board's own trace delay is not characterised (z486_mister.sdc's "Board skew is not yet
  // characterized"), exactly as in the STA model the values come from.
  parameter  integer PIN_LEAD_PS  = -1;
  parameter  integer DQ_RETURN_PS = 4704;
  localparam real    PIN_LEAD_NS  = (PIN_LEAD_PS >= 0)      ? PIN_LEAD_PS / 1000.0
                                  : (FREQ == 120_000_000)   ? 3.546
                                  : (FREQ == 100_000_000)   ? 6.046
                                  :                           TCK_NS - 3.743;
  localparam real    DQ_RETURN_NS = DQ_RETURN_PS / 1000.0;

  // The module's clock: SDRAM_CLK at the module, clk shifted by PIN_LEAD. Generated, not
  // delayed, because Verilator evaluates an intra-assignment delay's right-hand side when the
  // delay EXPIRES (measured: `b <= #11.7 a` lands the later value of a), so `<= #lead clk`
  // with a lead over half a period would not be a delayed clock at all.
  reg sdram_clk = 1'b0;
  initial begin
    #(PIN_LEAD_NS);
    forever #(TCK_NS / 2.0) sdram_clk = ~sdram_clk;
  end

  reg resetn          = 1'b0;
  reg nce             = 1'b0;
  reg refresh_allowed = 1'b1;
  wire busy;

  wire [15:0] SDRAM_DQ;      // the controller's pins
  wire [15:0] MODULE_DQ;     // the module's pins (THE BOARD, below)
  wire [12:0] SDRAM_A;
  wire  [1:0] SDRAM_DQM;
  wire  [1:0] SDRAM_BA;
  wire        SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;
  wire        SDRAM_nCS;

  integer errors = 0;
  integer checks = 0;

  // ==== DUT ====
  reg         valid0 = 1'b0;
  wire        ready0;
  reg         wr0    = 1'b0;
  reg  [26:0] addr0  = 27'd0;
  reg  [31:0] din0   = 32'd0;
  reg  [31:0] din0_hi = 32'd0;
  reg         gath0  = 1'b0;
  reg [440:0] gath0_extra = 441'd0;
  wire [31:0] dout0;
  wire        resp_valid0, burst_done0;
  reg   [3:0] be0 = 4'hF;
  reg   [3:0] burst_cnt0 = 4'd1;

  // Ports 1..3: mem1 the font/glyph reader, mem2 the 86-PCM buffer, mem3 idle in this machine
  // (the GVRAM scanout moved to M10K). They exist here so CONTENTION can be generated: every
  // claim this controller makes about fairness, about the refresh margin ("an accepted burst
  // cannot be interrupted") and about the pre-ACT reservation is a claim about what happens
  // when four requesters fight, and a single-requester bench cannot reach any of them.
  reg         valid1 = 1'b0, valid2 = 1'b0, valid3 = 1'b0;
  wire        ready1, ready2, ready3;
  reg         wr1 = 1'b0, wr2 = 1'b0, wr3 = 1'b0;
  reg  [26:0] addr1 = 27'd0, addr2 = 27'd0, addr3 = 27'd0;
  reg  [31:0] din1 = 32'd0, din2 = 32'd0, din3 = 32'd0;
  wire [31:0] dout1, dout2, dout3;
  reg   [3:0] be1 = 4'hF, be2 = 4'hF, be3 = 4'hF;
  wire        resp_valid1, resp_valid2, resp_valid3;
  reg   [3:0] burst_cnt1 = 4'd1, burst_cnt2 = 4'd1, burst_cnt3 = 4'd1;
  wire        burst_done1, burst_done2, burst_done3;

  sdram #(
      // The platform's parameters, verbatim from z486_mister.sv.
      .FREQ(FREQ), .HAS_DQM(1'b0), .ADQM(1'b1), .FAST_GRADE(1'b0),
      .PRE_ACT(1'b1), .GATHER_K(4)
  ) dut (
      .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM), .SDRAM_BA(SDRAM_BA),
      .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
      .SDRAM_nCS(SDRAM_nCS), .SDRAM_CKE(SDRAM_CKE),
      .clk(clk), .resetn(resetn), .nce(nce), .refresh_allowed(refresh_allowed), .busy(busy),
      .sdram_size(2'd3),                    // 128 MB
      .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0), .din0(din0),
      .din0_hi(din0_hi), .gath0(gath0), .gath0_extra(gath0_extra),
      .dout0(dout0), .be0(be0), .resp_valid0(resp_valid0),
      .burst_cnt0(burst_cnt0), .burst_done0(burst_done0),
      .valid1(valid1), .ready1(ready1), .wr1(wr1), .addr1(addr1), .din1(din1), .dout1(dout1),
      .be1(be1), .resp_valid1(resp_valid1), .burst_cnt1(burst_cnt1), .burst_done1(burst_done1),
      .valid2(valid2), .ready2(ready2), .wr2(wr2), .addr2(addr2), .din2(din2), .dout2(dout2),
      .be2(be2), .resp_valid2(resp_valid2), .burst_cnt2(burst_cnt2), .burst_done2(burst_done2),
      .valid3(valid3), .ready3(ready3), .wr3(wr3), .addr3(addr3), .din3(din3), .dout3(dout3),
      .be3(be3), .resp_valid3(resp_valid3), .burst_cnt3(burst_cnt3), .burst_done3(burst_done3)
  );

  // ==== THE JUDGE: the community's strict XSDS model ====
  // Its ports are the connector's: there is no DQM port because the board straps DQML/DQMH to
  // A11/A12, which the model extracts itself -- so our SDRAM_DQM output is deliberately unused.
  xsds_128mbyte_sdram_model #(
      .DEBUG(1'b0), .STRICT_TIMING(1'b1), .WARN_TREFI(1'b1), .INIT_UNWRITTEN_TO_X(1'b0)
  ) model (
      .Clk(sdram_clk), .Cs1_n(SDRAM_nCS), .Ras_n(SDRAM_nRAS), .Cas_n(SDRAM_nCAS), .We_n(SDRAM_nWE),
      .Ba(SDRAM_BA), .Addr(SDRAM_A), .Dq(MODULE_DQ)
  );

  // The DQ bus, split at the board: MODULE_DQ is the module's pins, SDRAM_DQ the controller's.
  // Write data goes out undelayed (its output path is inside PIN_LEAD, like the commands');
  // what the module drives comes back DQ_RETURN later. The return is gated by the controller's
  // own output enable only so the two sides never resolve two drivers on one Verilator net.
  assign MODULE_DQ = dut.dq_oen ? 16'hzzzz : dut.dq_out;
  // The return is a TRANSPORT delay (every change, in order, DQ_RETURN later): a queue of
  // timestamped samples, for the same Verilator reason as the clock above.
  wire        module_oe = model.u_chip0.dq_oe | model.u_chip1.dq_oe;
  reg  [15:0] ret_dq = 16'h0000;
  reg         ret_oe = 1'b0;
  typedef struct { realtime t; logic [15:0] v; logic oe; } dq_ev_t;
  dq_ev_t dq_line [$];
  always @(MODULE_DQ or module_oe) dq_line.push_back('{$realtime + DQ_RETURN_NS, MODULE_DQ, module_oe});
  initial forever begin
    wait (dq_line.size() != 0);
    if (dq_line[0].t > $realtime) #(dq_line[0].t - $realtime);
    ret_dq = dq_line[0].v;
    ret_oe = dq_line[0].oe;
    void'(dq_line.pop_front());
  end
  assign SDRAM_DQ = (ret_oe && dut.dq_oen) ? ret_dq : 16'hzzzz;

  initial begin
    #200_000_000;                          // 200 ms of sim time: a watchdog, not a budget
    $fatal(1, "TB_PC9821_SDRAM_STRICT: FAIL (watchdog)");
  end

  // ==== STIMULUS ====
  task automatic settle(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(negedge clk);
    end
  endtask

  // One port-0 transaction. A write is accepted and done; a read waits for its words.
  task automatic wr_dword(input [26:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      @(negedge clk);
      addr0 = a; din0 = d; be0 = be; wr0 = 1'b1; burst_cnt0 = 4'd1; gath0 = 1'b0;
      valid0 = 1'b1;
      g = 0;
      while (!ready0 && g < 5000) begin @(negedge clk); g = g + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_STRICT: no accept for the write at %07x", a);
      @(negedge clk);
      valid0 = 1'b0; wr0 = 1'b0;
      settle(8);
    end
  endtask

  task automatic rd_dwords(input [26:0] a, input [3:0] n, output [31:0] w0, output [31:0] w1);
    integer g;
    integer got;
    begin
      @(negedge clk);
      addr0 = a; be0 = 4'hF; wr0 = 1'b0; burst_cnt0 = n; gath0 = 1'b0;
      valid0 = 1'b1;
      g = 0;
      while (!ready0 && g < 5000) begin @(negedge clk); g = g + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_STRICT: no accept for the read at %07x", a);
      @(negedge clk);
      valid0 = 1'b0;
      got = 0; w0 = 32'h0; w1 = 32'h0;
      g = 0;
      while ((got < n) && (g < 8000)) begin
        @(negedge clk);
        if (resp_valid0) begin
          if (got == 0) w0 = dout0; else if (got == 1) w1 = dout0;
          got = got + 1;
        end
        g = g + 1;
      end
      if (got < n)
        $fatal(1, "TB_PC9821_SDRAM_STRICT: read of %0d word(s) at %07x returned only %0d", n, a, got);
      g = 0;
      while (!burst_done0 && g < 8000) begin @(negedge clk); g = g + 1; end
      settle(4);
    end
  endtask

  task automatic chk32(input [31:0] got, input [31:0] want, input [8*100-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: got %08x, want %08x", tag, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // A port-0 gather session: up to GATHER_K same-row partial stores under one ACT. Entry 0
  // rides addr0/din0/be0 and entries 1.. ride gath0_extra as {addr[26:0], din[31:0], be[3:0]}.
  localparam integer GENT_W = 27 + 32 + 4;
  task automatic gather_write(input [26:0] a, input [31:0] d0, input [3:0] be_a,
                              input [31:0] d1, input [3:0] be_b);
    integer g;
    begin
      @(negedge clk);
      addr0 = a; din0 = d0; be0 = be_a;
      gath0_extra = 441'd0;
      gath0_extra[0 +: GENT_W] = {a + 27'd4, d1, be_b};    // one entry up, same row
      wr0 = 1'b1; burst_cnt0 = 4'd2; gath0 = 1'b1;
      valid0 = 1'b1;
      g = 0;
      while (!ready0 && g < 5000) begin @(negedge clk); g = g + 1; end
      if (!ready0) $fatal(1, "TB_PC9821_SDRAM_STRICT: no accept for the gather at %07x", a);
      @(negedge clk);
      valid0 = 1'b0; wr0 = 1'b0; gath0 = 1'b0;
      settle(40);                                            // the session drains
    end
  endtask

  reg [31:0] r0, r1;
  integer i;
  integer g;

  // ==== CHECKS ====
  initial begin
    // The model's own power-up rule: hold everything in NOP for > 200 us before letting the
    // controller start its init sequence.
    settle(POWERUP_CYCLES);
    resetn = 1'b1;
    // The controller's OWN power-up hold is 200 us counted AFTER resetn rises (rst_cnt), on top
    // of the 200 us this bench already held it in reset, so the first command reaches the model
    // well past its 200 us requirement.
    settle(POWERUP_CYCLES + 4000);

    // ---- a dword write/read-back walk: both chips, several banks, a row-crossing burst ----
    // chip 0: 16 addresses across banks; chip 1: the same offsets above the 64 MB boundary
    // (cs1_n is the high chip bit, so an address with bit 26 set is a different chip).
    for (i = 0; i < 16; i = i + 1) begin
      wr_dword(27'(27'h000_1000 + (i * 27'h0100)), 32'hA5A5_0000 + i, 4'hF);
      rd_dwords(27'(27'h000_1000 + (i * 27'h0100)), 4'd1, r0, r1);
      chk32(r0, 32'hA5A5_0000 + i, "chip 0 dword walk");
    end
    for (i = 0; i < 16; i = i + 1) begin
      wr_dword(27'(27'h400_1000 + (i * 27'h0100)), 32'h5A5A_0000 + i, 4'hF);
      rd_dwords(27'(27'h400_1000 + (i * 27'h0100)), 4'd1, r0, r1);
      chk32(r0, 32'h5A5A_0000 + i, "chip 1 dword walk");
    end

    // ---- byte-masked writes: the mask rides A11/A12 on this board, so a masked write is the
    //      path with the most to get wrong. Write a full dword, then overwrite ONE byte of it
    //      and require the other three intact.
    wr_dword(27'h000_8000, 32'h1122_3344, 4'hF);
    wr_dword(27'h000_8000, 32'h0000_AA00, 4'b0010);          // byte lane 1 only
    rd_dwords(27'h000_8000, 4'd1, r0, r1);
    chk32(r0, 32'h1122_AA44, "byte-masked write keeps its neighbours");

    // ---- a 2-dword burst read (port 0's pair path) ----
    wr_dword(27'h000_9000, 32'hDEAD_BEEF, 4'hF);
    wr_dword(27'h000_9004, 32'hFEED_FACE, 4'hF);
    rd_dwords(27'h000_9000, 4'd2, r0, r1);
    chk32(r0, 32'hDEAD_BEEF, "burst read word 0");
    chk32(r1, 32'hFEED_FACE, "burst read word 1");

    // ---- the gather session (our own extension: two partial stores, one ACT) ----
    wr_dword(27'h000_A000, 32'hFFFF_FFFF, 4'hF);
    wr_dword(27'h000_A004, 32'hFFFF_FFFF, 4'hF);
    gather_write(27'h000_A000, 32'h0000_0011, 4'b0001, 32'h0022_0000, 4'b0100);
    rd_dwords(27'h000_A000, 4'd2, r0, r1);
    chk32(r0, 32'hFFFF_FF11, "gather entry 0 (byte 0 only)");
    chk32(r1, 32'hFF22_FFFF, "gather entry 1 (byte 2 only)");

    // ------------------------------------------------------------------
    // THE CONTENTION PHASE. Every port asserts at once, continuously, with different shapes:
    // port 0 the longest legal read burst, port 1 byte-masked writes (the mask-on-address
    // path), port 2 a gather session per iteration (the OTHER long transaction), port 3 short
    // reads. Nothing here checks the data - the point is the SHAPE of what reaches the pins,
    // and the model is the judge. This is the only phase in which the round-robin arbiter, the
    // pre-ACT reservation and the refresh-versus-burst margin are exercised at all.
    // ------------------------------------------------------------------
    $display("NOTE sdram_strict: --- contention: four requesters at once ---");
    for (i = 0; i < 400; i = i + 1) begin
      // All four presented on the same cycle, deliberately.
      @(negedge clk);
      valid0 = 1'b1; wr0 = 1'b0; addr0 = 27'(27'h000_2000 + (i & 27'h3F) * 27'h40);
      burst_cnt0 = 4'd15; be0 = 4'hF; gath0 = 1'b0;               // the longest legal burst
      valid1 = 1'b1; wr1 = 1'b1; addr1 = 27'(27'h000_C000 + (i & 27'h3F) * 27'h40);
      din1 = 32'hC0DE_0000 + i; be1 = 4'b0101; burst_cnt1 = 4'd1;
      valid2 = 1'b1; wr2 = 1'b1; addr2 = 27'(27'h000_E000 + (i & 27'h1F) * 27'h40);
      din2 = 32'h0000_5A00; be2 = 4'b0010; burst_cnt2 = 4'd1; gath0 = 1'b0;
      gath0_extra = 441'd0;
      gath0_extra[0 +: GENT_W] = {27'(27'h000_E000 + (i & 27'h1F) * 27'h40 + 27'h4), 32'h0000_00A5, 4'b1000};
      valid3 = 1'b1; wr3 = 1'b0; addr3 = 27'(27'h400_3000 + (i & 27'h3F) * 27'h20);
      burst_cnt3 = 4'd2; be3 = 4'hF;
      // Drop each as its own accept arrives; the round-robin decides the order.
      for (g = 0; g < 400; g = g + 1) begin
        @(negedge clk);
        if (ready0) valid0 = 1'b0;
        if (ready1) valid1 = 1'b0;
        if (ready2) valid2 = 1'b0;
        if (ready3) valid3 = 1'b0;
        if (!valid0 && !valid1 && !valid2 && !valid3) g = 400;
      end
      valid0 = 1'b0; valid1 = 1'b0; valid2 = 1'b0; valid3 = 1'b0;
      wr1 = 1'b0; wr2 = 1'b0;
      settle(60);                                                 // let every response drain
    end
    checks = checks + 1;
    if (busy) begin
      $display("FAIL contention: the controller is still busy after the load drained");
      errors = errors + 1;
    end

    // ---- THE VERDICT IS THE MODEL'S ----
    // module_error_count() is the strict model's own tally of protocol and AC-timing
    // violations; nothing this bench believes can excuse one.
    checks = checks + 1;
    if (model.module_error_count() != 0) begin
      $display("FAIL: the strict XSDS model recorded %0d protocol/timing violation(s)", model.module_error_count());
      errors = errors + 1;
    end

    $display("TB_PC9821_SDRAM_STRICT: %0d check(s), %0d mismatch(es), model violations %0d",
             checks, errors, model.module_error_count());
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SDRAM_STRICT: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_SDRAM_STRICT: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

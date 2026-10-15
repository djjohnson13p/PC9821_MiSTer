// tb_pc9821_audio_out_rate - the 48 kHz output stage's presentation cadence.
//
// ==== WHAT THIS PROVES ====
// The 48 kHz output stage presents one new AUDIO_L/R sample per 512 CLK_AUDIO cycles - the framework's own DAC rate (24 576 000/48 000 = 512) with a bare 512-cycle cadence and no 511-cycle drift (sys/audio_out.sv's own sample_ce runs at 24 576 000/511, which is the framework's, not this core's), and it holds that cadence for a worst-case changing input: the register changes on every presentation, never 10 cycles apart as the pre-fix code did (measured 10 before the fix and re-measured here), with the value stable in between for the framework's two-consecutive-edges-agree latch (sys/audio_out.sv:170 (cl2 == cl1)).
//
// ==== DUT ====
// pc9821_audio_out (src/pc9821/audio/pc9821_audio_out.sv): the CIC decimator, the two FIR
// MAC engines and the free-running 512-clk presentation counter, instantiated exactly as
// z486_mister.sv instantiates it (CLK_AUDIO, the mixer's valid strobe, mix_pre in,
// core_audio out).
//
// ==== CHECKS ====
// CHK-1 AUDIO_L changes on every presentation: over N presentations the number of changes
//       equals N-1 (the first sample is not a change), so no presentation is a stale read.
// CHK-2 every gap between changes is exactly 512 CLK_AUDIO cycles (min = max = 512).
// CHK-3 the gap is not 10 (the pre-fix cadence) and not 511 (sys/audio_out.sv's own
//       sample_ce period), stated explicitly so a drift to either fails by name.
// CHK-4 between presentations the value is STABLE for at least 500 cycles - the property
//       the framework's latch needs (sys/audio_out.sv:170 (cl2 == cl1) only accepts a value that two
//       consecutive clk edges agree on).
//
// The stimulus is a worst case on purpose: the input changes on every mixer service (a
// 2.4576 MHz ramp), so every presentation has a new value to carry and a dropped or
// duplicated presentation cannot hide.
//
// ==== VERDICT ====
// PASS when the presentation is exactly one new sample per 512 CLK_AUDIO cycles with the
// value stable in between; FAIL naming which check moved and by how much.
//
`timescale 1ns/1ps
module tb_pc9821_audio_out_rate;

  localparam integer PRESENTATIONS = 200;

  reg clk = 0;
  always #5 clk = ~clk;

  reg                valid = 0;
  reg  signed [15:0] in_l = 0, in_r = 0;
  wire signed [15:0] out_l, out_r;

  pc9821_audio_out dut (
      .clk(clk), .valid(valid), .in_l(in_l), .in_r(in_r),
      .out_l(out_l), .out_r(out_r)
  );

  integer errors = 0;
  task fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The mixer's service strobe: one pulse per 10 clk (pc9821_audio_volume's 10-channel
  // rotation), carrying a fresh value every time.
  integer vcnt = 0;
  integer seq  = 0;
  always @(posedge clk) begin
    vcnt <= (vcnt == 9) ? 0 : vcnt + 1;
    valid <= (vcnt == 9);
    if (vcnt == 9) begin
      seq <= seq + 1;
      in_l <= (seq * 37) % 20000 - 10000;
      in_r <= (seq * 53) % 20000 - 10000;
    end
  end

  // Cadence measurement on the presented register.
  integer cyc = 0;
  integer changes = 0;
  integer last_change = -1;
  integer min_gap = 1 << 20;
  integer max_gap = -1;
  integer stable_run = 0;
  integer min_stable = 1 << 20;
  reg signed [15:0] prev = 0;

  always @(posedge clk) begin
    cyc = cyc + 1;
    if (out_l !== prev) begin
      prev = out_l;
      if (last_change >= 0) begin
        if (cyc - last_change < min_gap) min_gap = cyc - last_change;
        if (cyc - last_change > max_gap) max_gap = cyc - last_change;
      end
      last_change = cyc;
      changes = changes + 1;
      if (stable_run < min_stable) min_stable = stable_run;
      stable_run = 0;
    end
    else begin
      stable_run = stable_run + 1;
    end
  end

  integer cycle_at_start = 0;
  initial begin
    // run for PRESENTATIONS presentation slots (512 clk each) plus slack
    #(5 * 2 * (512 * PRESENTATIONS + 2048));
    $display("measured: %0d changes, gap min %0d max %0d, min stable run %0d",
             changes, min_gap, max_gap, min_stable);
    if (changes < PRESENTATIONS - 2)
      fail("CHK-1 fewer changes than presentations: a presentation did not carry a new sample");
    if (min_gap != 512 || max_gap != 512)
      fail("CHK-2 the presentation period is not exactly 512 CLK_AUDIO cycles");
    if (min_gap == 10)
      fail("CHK-3 the cadence is the pre-fix 10-cycle mixer strobe, not the 48 kHz grid");
    if (min_gap == 511)
      fail("CHK-3 the cadence drifted to the framework's own 511-cycle sample_ce");
    if (min_stable < 500)
      fail("CHK-4 the value was not stable between presentations (framework latch rule)");
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_OUT_RATE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_OUT_RATE: FAIL (%0d errors)", errors);
  end

  initial begin
    #(5 * 2 * (512 * 200 + 8192));
    $fatal(1, "TB_PC9821_AUDIO_OUT_RATE: TIMEOUT");
  end

endmodule

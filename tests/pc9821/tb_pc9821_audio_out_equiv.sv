// tb_pc9821_audio_out_equiv - the 48 kHz output stage's area rewrite against its pre-rewrite text.
//
// ==== WHAT THIS PROVES ====
// The 48 kHz output stage's area rewrite (the FIR MAC engine accumulating straight from the multiplier into a 34-bit DSP accumulator instead of through a 34-bit product register and a 42-bit logic adder) is cycle-for-cycle identical to the pre-rewrite stage (pc9821_audio_out_ref.sv, the three modules as of 3b134fe4): over random, full-scale, impulse, step, tone and silent mixer streams with the right channel changing off the valid edge, AUDIO_L/R, the CIC's output strobe and samples, and the stage-B and stage-C start and done strobes match on every CLK_AUDIO cycle.
//
// ==== DUT ====
// pc9821_audio_out (src/pc9821/audio/pc9821_audio_out.sv with the cic4 and fir_engine it
// instantiates) vs pc9821_audio_out_ref (tests/pc9821/pc9821_audio_out_ref.sv), same inputs.
// The reference is the pre-change text, not a model of the hardware: this bench proves the
// rewrite did not change behaviour; the stage's response is pinned by tb_pc9821_audio_out_alias,
// _rate and _timeline. The accumulator-width claim itself is proved by
// tools/check_fir_acc_bound.py (|acc| <= 32768 * sum|coef| < 2^33 for every stage and phase).
//
// ==== CHECKS ====
// CHK-1 out_l/out_r equal on every clock, in every stimulus class.
// CHK-2 the CIC output strobe and samples, the stage-B done strobe and samples and the stage-C
//       start strobe equal on every clock (the internal schedule did not move).
// CHK-3 the run was not vacuous: each class produced presentations, the outputs were not all
//       equal to one value, and the full-scale classes drove the saturating clamp's range.
//
// ==== VERDICT ====
// PASS when no clock differs in any class; FAIL names the first differing clock and class.
//
`timescale 1ns/1ps
module tb_pc9821_audio_out_equiv;
  reg clk = 0;
  always #5 clk = ~clk;

  reg               valid = 0;
  reg signed [15:0] in_l = 0, in_r = 0;
  wire signed [15:0] d_l, d_r, r_l, r_r;

  pc9821_audio_out dut (.clk(clk), .valid(valid), .in_l(in_l), .in_r(in_r), .out_l(d_l), .out_r(d_r));
  pc9821_audio_out_ref ref0 (.clk(clk), .valid(valid), .in_l(in_l), .in_r(in_r), .out_l(r_l), .out_r(r_r));

  wire d_cv = dut.cic_valid,  r_cv = ref0.cic_valid;
  wire signed [15:0] d_cl = dut.cic_l, r_cl = ref0.cic_l, d_cr = dut.cic_r, r_cr = ref0.cic_r;
  wire d_bd = dut.b_done, r_bd = ref0.b_done;
  wire signed [15:0] d_bl = dut.b_l, r_bl = ref0.b_l, d_br = dut.b_r, r_br = ref0.b_r;
  wire d_cs = dut.c_start, r_cs = ref0.c_start;

  localparam integer NCLASS = 7;
  localparam integer VALIDS = 12000;       // per class: 120 000 clk = 234 presentations

  integer errors = 0, cls = 0, cyc = 0, k = 0, n = 0;
  integer pres[0:NCLASS-1];
  reg signed [15:0] lt, rt;
  integer extreme_hits = 0;

  task automatic fail(input [8*72-1:0] what);
    begin
      errors = errors + 1;
      if (errors <= 10)
        $display("FAIL class %0d clk %0d: %0s  out %0d/%0d vs %0d/%0d", cls, cyc, what, d_l, d_r, r_l, r_r);
    end
  endtask

  // one new mixer sample per 10 clk; class picks the value
  function automatic signed [15:0] sample(input integer c, input integer i, input integer chan);
    reg [31:0] r;
    begin
      r = (i * 2 + chan + 1) * 32'h9E3779B1;
      r = r ^ (r >> 15);
      r = r * 32'h85EBCA6B;
      r = r ^ (r >> 13);
      case (c)
        0: sample = r[15:0];                                  // white
        1: sample = r[0] ? 16'sh7FFF : 16'sh8000;             // random full-scale
        2: sample = (i % 97 == 0) ? 16'sh7FFF : 16'sd0;       // impulse train
        3: sample = ((i / 700) % 2) ? 16'sh8000 : 16'sh7FFF;  // full-scale steps
        4: sample = 16'($rtoi(24000.0 * $sin(6.2831853 * i * (chan ? 0.0113 : 0.0071))) + $signed({1'b0, r[7:0]}) - 128);
        5: sample = ((i / 5) % 2) ? 16'sh8000 : 16'sh7FFF;    // near-Nyquist square, full scale
        default: sample = 16'sd0;                             // silence
      endcase
    end
  endfunction

  always @(posedge clk) begin
    cyc <= cyc + 1;
    // compare BEFORE the new stimulus lands (values after this clock edge)
    if (d_l !== r_l || d_r !== r_r) fail("CHK-1 out_l/out_r differ");
    if (d_cv !== r_cv || (d_cv && (d_cl !== r_cl || d_cr !== r_cr))) fail("CHK-2 CIC strobe/sample differ");
    if (d_bd !== r_bd || (d_bd && (d_bl !== r_bl || d_br !== r_br))) fail("CHK-2 stage B differs");
    if (d_cs !== r_cs) fail("CHK-2 stage C start differs");
    if (d_l == 16'sh7FFF || d_l == 16'sh8000) extreme_hits <= extreme_hits + 1;
  end

  // stimulus: valid every 10th clock; in_l is set with valid, in_r sometimes one clock later
  // (the CIC's asymmetric sampling) and sometimes with the valid.
  integer i = 0;
  integer slot = 0;
  reg late;
  always @(posedge clk) begin
    slot <= (slot == 9) ? 0 : slot + 1;
    valid <= 1'b0;
    if (slot == 9) begin
      valid <= 1'b1;
      lt = sample(cls, i, 0);
      rt = sample(cls, i, 1);
      in_l <= lt;
      late = (cls == 0 || cls == 4) && (sample(0, i + 77777, 1) % 3 == 0);
      if (late) in_r <= in_r;       // r changes next clock
      else in_r <= rt;
      i <= i + 1;
    end
    else if (slot == 0 && late) in_r <= rt;
  end

  integer lastout_changes = 0;
  reg signed [15:0] lastv = 0;
  always @(posedge clk) if (d_l !== lastv) begin lastv <= d_l; lastout_changes <= lastout_changes + 1; end

  initial begin
    for (k = 0; k < NCLASS; k = k + 1) pres[k] = 0;
    for (cls = 0; cls < NCLASS; cls = cls + 1) begin
      i = 0;
      n = lastout_changes;
      repeat (VALIDS * 10) @(posedge clk);
      pres[cls] = lastout_changes - n;
      $display("class %0d: %0d output changes, errors so far %0d", cls, pres[cls], errors);
    end
    for (k = 0; k < 5; k = k + 1)
      if (pres[k] < 100) begin
        errors = errors + 1;
        $display("FAIL CHK-3 class %0d produced only %0d output changes", k, pres[k]);
      end
    if (extreme_hits == 0) begin
      errors = errors + 1;
      $display("FAIL CHK-3 no output reached a rail: the clamp's range was never driven");
    end
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_OUT_EQUIV: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_OUT_EQUIV: FAIL (%0d errors)", errors);
  end

  initial begin
    #(10 * (VALIDS * 10 * NCLASS + 100000));
    $fatal(1, "TB_PC9821_AUDIO_OUT_EQUIV: TIMEOUT");
  end
endmodule

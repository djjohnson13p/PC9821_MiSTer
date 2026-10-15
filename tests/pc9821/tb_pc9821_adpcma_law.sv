`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Every one of the ADPCM-A increment table's 392 entries equals the die's law inc = ((2*nibble+1) * rss_delta[step]) / 8 as the elaborated RTL reads it -- the top-of-table entries (46,7)=2403, (47,7)=2645, (48,6)=2522 and (48,7)=2910 included, above 2047 and legal because the die's sample field is 12 bits and WRAPS -- and the decoder that consumes the table emits the law's sample stream up to step 48, a table clamped to 2047 at those four entries failing both legs.
//
// WHY THIS IS A BENCH OF ITS OWN. The two ADPCM units share nothing but a clock:
// ADPCM-A's increment is a 12-bit table read (jt10_adpcma_lut) and its top of table is
// where a hand-written table can be wrong. No existing bench reaches it -- the drum
// benches (tb_pc9821_audio_clip, tb_pc9821_opna_balance, tb_pc9821_rhythm_guard,
// tb_pc9821_rhythm_rom) drive the real pack image through the whole chip, so they
// exercise only the codes the ROM happens to carry at the level the mix happens to be
// at, and none of them names an increment. No bench saw one entry of this table.
//
// THIS IS A PIN, NOT A FIX. The table already is the law: the source's four top-of-table
// lines carry the law's value live and a commented-out `12'o3777` (= 2047) after `//` on
// the same line (jt10_adpcma_lut.v:131 (lut[9'o56_7] = 12'o4543;//12'o3777; lut[9'o56_7] = 12'o3777;)), and a raw-text parse that does not strip
// comments reads the dead text and reports four phantom mismatches -- which is what an
// earlier report was built on. The bench reads the
// elaborated table, so it cannot be fooled that way, and its teeth are shown by a planted
// mutant: with those four entries actually clamped to 2047 the bench fails both legs, and with the
// shipped file it passes.
//
// THE EXPECTED VALUES ARE THE DIE'S, NOT OURS. Every number this bench compares against is
// computed in-bench from the step table and the nibble law of the decapped YM2608B model
// (refs/YM2608-LLE/fmopna_impl.c): `rss_delta[64]` (:2870-2876) and
// `rss_adjust[8] = {63,63,63,63,2,5,7,9}` (:2877-2880), with the increment built as delta,
// delta>>1 and the nibble's bits 1/2/3 selected across the six ALU phases, i.e.
// inc = (2*(n&7)+1) * rss_delta[step] / 8 -- the same law three independent software
// references state: qemu-pc98's Init_ADPCMATable (hw/audio/fmopn.c:2615-2618,
// `(2*(nib&0x07)+1)*steps[step]/8`), NP2kai's OPNB::InitADPCMATable
// (sound/fmgen/fmgen_opna.cpp:1930-1943, `s * table2[j] / 8`) and ymfm's
// adpcm_a_channel::clock(). The chip's sample is 12 bits wide and WRAPS rather than
// saturating (`rss_sample = rss_regs[1][16] & 0xfff`, :2735; ymfm_adpcm.cpp's own "the
// 12-bit accumulator wraps on the ym2610 and ym2608 (like the msm5205)"), so increments
// above 2047 are legal values in a 12-bit field and the law's own maximum, 15*1552/8 =
// 2910, fits one. Eight entries of the law exceed 2047 and NONE of them is clamped.
//
// WHAT THIS BENCH DOES NOT CLAIM. It does not claim the top of the table is audible, and
// the captures do not resolve it: the two candidate decodes are 98.5 % correlated with
// each other (one trajectory under a piecewise-constant accumulator offset) and the
// captured rhythms differ from both by more than the candidates differ from each other.

// ==== DUT ====
//
// jt10_adpcma_lut is the shipped table: 392 entries of 12 bits, addressed {step,
// data[2:0]} (the sign bit is applied by the decoder, not by the table). jt10_adpcm is
// the decoder that reads it: the real module, with the real six-stage pipeline, driven
// one nibble per six cen cycles the way jt08_adpcm_drvA drives a channel's slot.

module tb_pc9821_adpcma_law;

  // ---- the die's step table, refs/YM2608-LLE/fmopna_impl.c:2870-2876 ----
  // (indices 49..63 repeat 1552, :2874; the step index stops at 48 --
  //  jt10_adpcm.v's `step_1p = step_next > 6'd48 ? 6'd48 : step_next`, and the die's
  //  own `rss_delta_ix` field of `rss_regs[1][14] & 63` is held there by rss_adjust)
  localparam integer DELTA [0:48] = '{
      16,  17,  19,  21,  23,  25,  28,  31,  34,  37,
      41,  45,  50,  55,  60,  66,  73,  80,  88,  97,
     107, 118, 130, 143, 157, 173, 190, 209, 230, 253,
     279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
     724, 796, 876, 963,1060,1166,1282,1411,1552 };

  // ---- the die's per-nibble step adjustment, fmopna_impl.c:2877-2880 ----
  // {63,63,63,63,2,5,7,9}, where 63 is -1 in the step field (mod 64) -- qemu's
  // step_inc {-16,-16,-16,-16,2*16,5*16,7*16,9*16}/16 and NP2kai's decode_tableA1.
  function automatic integer step_adj(input integer n);
    step_adj = (n < 4) ? -1 : ((n == 4) ? 2 : (n == 5) ? 5 : (n == 6) ? 7 : 9);
  endfunction

  // inc = ((2*(n&7)+1) * DELTA[step]) / 8 -- the die's law, integer division as every
  // reference performs it. The nibble's bit 3 is the sign, applied by the decoder.
  function automatic integer law_inc(input integer step, input integer n);
    law_inc = ((2 * (n & 7) + 1) * DELTA[step]) / 8;
  endfunction

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  integer errors = 0;

  task automatic fail(input string message);
    begin
      errors = errors + 1;
      $display("MISMATCH: %0s", message);
    end
  endtask

  reg  [8:0]  lut_addr = 0;
  wire [11:0] lut_inc;

  jt10_adpcma_lut u_lut(.clk(clk), .rst_n(rst_n), .cen(1'b1), .addr(lut_addr),
                        .inc(lut_inc));

  reg                chon = 0;
  reg                clr  = 0;
  reg  [3:0]         data = 0;
  wire signed [15:0] pcm;

  jt10_adpcm u_dec(.rst_n(rst_n), .clk(clk), .cen(1'b1), .data(data), .chon(chon),
                   .clr(clr), .pcm(pcm));

  // Two nibble streams, each its own key-on. The state is six stages deep and each
  // round is six cen cycles long (one slot per stage), so a clear is held for TWO
  // rounds: the round that presents it carries it through the rotation, and the round
  // that follows is the first one whose slot sees the cleared stage-I pair. That is the
  // module's own pipeline shape, not the expectation: the expectation below is the die's
  // law from an accumulator and step of zero, which is what a key-on clears to
  // (fmopna_impl.c:2985-2987's kon_event path).
  //
  //   stream A walks 0 -> 9 -> 18 -> 20 -> 29 -> 38 -> 47 -> 48: a nibble 7 AT STEP 47
  //   ((47,7) = 2645), then nibble 7 at step 48 ((48,7) = 2910), a nibble 6 at step 48
  //   ((48,6) = 2522), and a sign-set nibble 0xF at step 48 (the negated 2910 -- the
  //   decoder's ~inc+1 path).
  //   stream B walks 0 -> 9 -> 18 -> 20 -> 29 -> 38 -> 47 -> 46 -> 48: a nibble 7 AT
  //   STEP 46 ((46,7) = 2403), the one top-of-table entry the real rhythm ROM's top
  //   cymbal reaches from its own start address.
  localparam integer NA = 16;
  localparam integer NB = 14;
  localparam [3:0] STR_A [0:NA-1] = '{4'h7,4'h7,4'h4,4'h7,4'h7,4'h7,4'h7,
                                     4'h7,4'h6,4'hf,4'h7,4'h6,4'h7,4'h7,4'h6,4'hf};
  localparam [3:0] STR_B [0:NB-1] = '{4'h7,4'h7,4'h4,4'h7,4'h7,4'h7,4'h0,
                                     4'h7,4'h7,4'h7,4'h6,4'h7,4'h7,4'hf};

  integer k, i, step, n, expect_inc, got_inc, touched_hi;
  integer r_acc, r_step, r_inc, r_ref, sampled;

  // One nibble per six cen cycles, on the channel's own slot: slot 0 carries the channel
  // (chon high, data = the nibble) and slots 1..5 carry nothing, so the state advances
  // exactly once per round and the round's sample reaches pcm at slot 5 (its stage VI,
  // five cycles after the nibble entered stage I).
  task automatic drive(input integer nibble, input integer do_clr);
    begin
      clr  = do_clr;
      chon = 1;
      data = nibble[3:0];
      for (i = 0; i < 6; i = i + 1) begin
        @(posedge clk);
        if (i == 5) sampled = pcm;
        if (i == 0) begin chon = 0; data = 4'h0; clr = 0; end
      end
    end
  endtask

  integer bad;
  task automatic run_stream(input integer which);
    begin
      bad    = 0;
      r_acc  = 0;
      r_step = 0;
      drive(0, 1);                      // clear, held for the rotation
      drive(0, 1);
      for (k = 0; k <= ((which == 0) ? NA : NB) - 1; k = k + 1) begin
        n     = (which == 0) ? STR_A[k][2:0] : STR_B[k][2:0];
        r_inc = law_inc(r_step, n);
        r_acc = (((which == 0) ? STR_A[k][3] : STR_B[k][3]) ? (r_acc - r_inc)
                                                            : (r_acc + r_inc)) & 12'hFFF;
        r_step = r_step + step_adj(n);
        if (r_step < 0) r_step = 0;
        if (r_step > 48) r_step = 48;
        r_ref  = r_acc[11] ? (r_acc - 4096) : r_acc;      // the die's 12-bit sample
        drive((which == 0) ? STR_A[k] : STR_B[k], 0);
        if (sampled !== r_ref) begin
          bad = bad + 1;
          if (bad <= 3)
            fail($sformatf("decoder stream %0d sample %0d: 12-bit sample %0d, die's law %0d (increment %0d at step %0d)",
                           which, k, sampled, r_ref, r_inc, r_step));
        end
      end
      if (bad > 3)
        fail($sformatf("decoder stream %0d: %0d of %0d samples diverge from the die's law",
                       which, bad, (which == 0) ? NA : NB));
    end
  endtask

  // ==== CHECKS ====
  //
  // Leg 1 reads every one of the table's 392 entries off the elaborated RTL and compares it
  // with the law; leg 2 drives the real decoder to steps 46/47/48 and compares every sample
  // it emits with the law's own sequence.
  initial begin
    #23 rst_n = 1;
    #20;

    // ---- 1. the whole 392-entry table, against the die's law, entry by entry -----
    touched_hi = 0;
    for (step = 0; step <= 48; step = step + 1) begin
      for (n = 0; n <= 7; n = n + 1) begin
        lut_addr = {step[5:0], n[2:0]};
        @(posedge clk);
        #1;
        expect_inc = law_inc(step, n);
        got_inc    = lut_inc;
        if (got_inc !== expect_inc[11:0])
          fail($sformatf("table entry (%0d,%0d): shipped %0d, die's law %0d%s",
                         step, n, got_inc, expect_inc,
                         (expect_inc > 2047) ? "  [above 2047, legal in the die's 12-bit WRAPPING sample field]" : ""));
        if (expect_inc > 2047) touched_hi = touched_hi + 1;
      end
    end
    if (touched_hi != 8)
      fail($sformatf("the die's law has %0d entries above 2047, expected 8 -- the top of the table would not be exercised",
                     touched_hi));

    // ---- 2. the decoder, driven to steps 46/47/48 --------------------------------
    run_stream(0);
    run_stream(1);

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_ADPCMA_LAW: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ADPCMA_LAW: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog.
  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_ADPCMA_LAW: TIMEOUT");
  end

endmodule

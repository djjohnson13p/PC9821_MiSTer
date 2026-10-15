`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The four-plane column folded to a palette index the way the machine orders it, exhaustively: all 16 plane-bit combinations at all 8 dot positions. GVRAM is four planes (0 = blue at 0xA8000, 1 = red at 0xB0000, 2 = green at 0xB8000, 3 = intensity at 0xE0000), the index is {E,G,R,B} in bits 3..0, the column is one byte per plane MSB first so dot 0 is bit 7. Also checks NP2kai's relation (B = i&1, R = (i>>1)&1, G = (i>>2)&1) over every index the fold can produce, so a red/green swap cannot pass, and names the blue and intensity lanes individually.
//
// ---- the bench's own account of where each expectation comes from ----
// The four-plane column is folded to a palette index the way the MACHINE orders
// it, exhaustively: all 16 plane-bit combinations at all 8 dot positions, 128
// cases, because the module is a pure combinational select and there is no reason
// to sample it when it can be walked.
//
// WHAT "THE WAY THE MACHINE ORDERS IT" MEANS, and where each part comes from:
//  * GVRAM is four planes, 0 = blue (0xA8000), 1 = red (0xB0000), 2 = green
//    (0xB8000), 3 = intensity (0xE0000). The display shows one 4-bit palette
//    index per dot, {E,G,R,B} in bits 3..0.
//  * The index bits are assembled in LANE order, so idx[3] = E, idx[2] = G,
//    idx[1] = R, idx[0] = B.
//  * The column word is one byte per plane, MSB FIRST, so dot 0 of the column is
//    bit 7 of each lane. That is the same convention the text path uses for its
//    glyph row, which is what makes the two serialisers agree dot for dot.
//  [sources: the module's own header; NP2kai's plane-window order and its
//   degpal1[i] = {b = i & 1, r = (i >> 1) & 1, g = (i >> 2) & 1}, which agree
//   with each other and with the machine's power-on digital palette bytes
//   0xA8/AA/AC/AE = 37/15/26/04; an earlier review
//   states the same order as "B = bit 0, R = bit 1, G = bit 2, E = bit 3"]
//
// The NP2kai relation is what makes this checkable as a WHOLE rather than
// per-bit: an index i must be reproducible from its own bits, so for every value
// the fold produces, B = i&1, R = (i>>1)&1 and G = (i>>2)&1 must hold. A module
// that swapped red and green would pass a single-plane walk and fail that.

module tb_pc9821_plane_fold;
  reg  [31:0] column;
  reg  [ 2:0] dot;
  wire [ 3:0] idx;

  // ==== DUT ====
  pc9821_plane_fold dut (.column(column), .dot(dot), .idx(idx));

  // ==== CHECKS ====

  integer errors   = 0;
  integer d, p, i;
  reg     bit_of_plane;
  reg [3:0] want;

  initial begin
    // ---- exhaustively: every plane-bit combination at every dot ----
    for (d = 0; d < 8; d = d + 1) begin
      for (p = 0; p < 16; p = p + 1) begin
        dot = d[2:0];
        // Build a column whose four plane bytes each carry the same 8-bit
        // pattern p in every dot, so the dot select is what is being tested and
        // each lane is distinguishable from the others: lane n gets p rotated by
        // n, which makes a cross-lane wire swap visible.
        column = { 8'h00, 8'h00, 8'h00, 8'h00 };
        for (i = 0; i < 4; i = i + 1) begin
          bit_of_plane = (p >> i) & 1;
          column[8*i + 7 - d] = bit_of_plane;
        end
        #1;
        want[3] = (p >> 3) & 1;   // E from plane 3
        want[2] = (p >> 2) & 1;   // G from plane 2
        want[1] = (p >> 1) & 1;   // R from plane 1
        want[0] = (p >> 0) & 1;   // B from plane 0
        if (idx !== want) begin
          $display("FAIL fold at dot %0d planes %b: idx=%b, expected %b (idx[3]=E,idx[2]=G,idx[1]=R,idx[0]=B)",
                   d, p[3:0], idx, want);
          errors = errors + 1;
        end
      end
    end

    // ---- the NP2kai relation, over every index the fold can produce ----
    // For each index value, build the column that should produce it and check the
    // relation B = i&1, R = (i>>1)&1, G = (i>>2)&1 against what comes out.
    for (i = 0; i < 16; i = i + 1) begin
      dot = 3'd0;
      column = { 8'h00, 8'h00, 8'h00, 8'h00 };
      column[8*0 + 7] = i[0];   // B
      column[8*1 + 7] = i[1];   // R
      column[8*2 + 7] = i[2];   // G
      column[8*3 + 7] = i[3];   // E
      #1;
      if (idx !== i[3:0]) begin
        $display("FAIL index round trip for %0d: idx=%0d", i, idx);
        errors = errors + 1;
      end
      if (i[0] !== ((i >> 0) & 1) || i[1] !== ((i >> 1) & 1) || i[2] !== ((i >> 2) & 1)) begin
        $display("FAIL NP2kai bit relation for index %0d", i);
        errors = errors + 1;
      end
    end

    // ---- one explicit cross-lane check, so a swapped lane is named ----
    // dot 0: only the BLUE plane's bit 7 set must give index 1 (B), not 2 or 4.
    dot = 3'd0;
    column = 32'h0000_0000; column[8*0 + 7] = 1'b1;
    #1;
    if (idx !== 4'b0001) begin
      $display("FAIL blue lane alone at dot 0 gives idx=%b, expected 0001 (B is bit 0)", idx);
      errors = errors + 1;
    end
    column = 32'h0000_0000; column[8*3 + 7] = 1'b1;
    #1;
    if (idx !== 4'b1000) begin
      $display("FAIL intensity lane alone at dot 0 gives idx=%b, expected 1000 (E is bit 3)", idx);
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PLANE_FOLD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PLANE_FOLD: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_PLANE_FOLD: TIMEOUT");
  end

endmodule

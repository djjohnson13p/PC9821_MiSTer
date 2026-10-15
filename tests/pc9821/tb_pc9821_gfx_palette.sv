`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GFX_PALETTE:
// The graphics palette reads the way the MACHINE's palette does, in both modes, for the DIGITAL table entirely (its eight colours, the 8-colour mode's use of only the low three index bits, and the intensity bit not changing the answer) and for the ANALOGUE table now that it is a small RAM: the power-on entries are the ITF ROM's own (itf.rom 0x042F, entry 2 red / entry 4 green), a CPU write through the 0xA8-index/0xAA-G/0xAC-R/0xAE-B port lands in the LIVE table and is invisible until the frame-boundary copy carries it into the displayed one, the whole 4-bit index selects an entry (the intensity bit is part of it, so entry 8 differs from entry 0), and the read stays combinational so no dot of the pixel path moves. The PEGC 256-colour table is a SECOND store beside them: full bytes per channel at the full 8-bit index (NP2kai stores and renders the written byte verbatim), a registered dot-path read one clk after the index (the async form refuses every block type), and the 16-entry path unchanged by any of it. The live-to-displayed copy that carries it is checked cycle by cycle - one read register deep, entry k landing in disp in the cycle cp_cnt == k+1 out of the value read in cp_cnt == k - and a CPU write landing in the cycle the copy reads that entry is proven not to reach that frame's displayed table: the live table is block memory now, and read-during-write is the one cycle a block RAM could have resolved differently from the flop array it replaced (the post-fit netlist, driven with the same stimulus, is byte-identical).
// ---- the bench's own account of where each expectation comes from ----
// THE DIGITAL (8-COLOUR) TABLE, and why this is a specification test. The four
// palette registers 0xA8/0xAA/0xAC/0xAE are packed as one word; the machine
// powers up with 37/15/26/04; NP2kai makes those registers entries 3/1/2/0 of a
// four-entry pack, each carrying one colour in its high nibble and that colour's
// bright half in its low nibble, indexed by {G,R,B}. Working that out from the
// bytes alone gives black/blue/red/magenta in the high nibbles and
// green/cyan/yellow/white in the low ones, and the bench asserts all eight. Plus:
// 8-colour mode uses only the low three index bits.
//
// THE ANALOGUE TABLE is one entry per 4-bit index, {R,G,B} nibbles, and the
// INTENSITY PLANE SELECTS THE UPPER EIGHT. It is a 2x16x12 ping-pong RAM written
// on clk_sys and read on the dot enable, so the bench writes it through that port
// and swaps the banks with the frame-boundary commit - which is also the proof
// that a write does NOT reach the screen before the boundary.
//
// The output order is {R,G,B} in bits 11..0, which is the order the rest of the
// video path and the framework use.

module tb_pc9821_gfx_palette;
  reg  clk = 0;
  always #5 clk = ~clk;
  reg  rst_n = 0;

  reg  [7:0]  idx = 0;
  reg         mode16 = 0;
  reg  [31:0] dig = 0;
  reg         we = 0;
  reg  [3:0]  widx = 0;
  reg  [1:0]  wchan = 0;     // 0 = G, 1 = R, 2 = B
  reg  [3:0]  wdata = 0;
  reg         commit = 0;
  wire [11:0] colour;
  // The PEGC 256-colour table's ports (pegc-scope-REPORT.md 4 row 4).
  reg         p256_we = 1'b0;
  reg  [7:0]  p256_widx = 8'd0, p256_wdata = 8'd0;
  reg  [1:0]  p256_wchan = 2'd0;
  reg  [7:0]  idx256 = 8'd0;
  wire [23:0] colour256;

  // ==== DUT ====
  pc9821_gfx_palette dut (.clk(clk), .rst_n(rst_n),
                          .idx(idx), .mode16(mode16), .dig(dig),
                          .we(we), .widx(widx), .wchan(wchan), .wdata(wdata),
                          .commit(commit), .colour(colour),
                          .p256_we(p256_we), .p256_widx(p256_widx),
                          .p256_wchan(p256_wchan), .p256_wdata(p256_wdata),
                          .idx256(idx256), .colour256(colour256));

  // ==== CHECKS ====

  integer errors = 0;
  integer i;
  reg [7:0] n;
  reg [11:0] colour16_before;   // the 16-entry read's value before the 256 activity
  reg [3:0] gn, bn;   // the expected G and B nibbles for the entry under test
  reg [11:0] entry0 = 12'h000;

  // The eight colours the machine's power-on bytes must produce, most
  // significant nibble first: {R,G,B} with each channel all-ones or all-zero.
  function [11:0] rgb(input r, input g, input b);
    rgb = { (r ? 4'hF : 4'h0), (g ? 4'hF : 4'h0), (b ? 4'hF : 4'h0) };
  endfunction

  // The ITF ROM's power-on analogue table, {R,G,B} per entry (the source packs
  // {G,R,B}; pc9821_gfx_palette's own localparam is the same table).
  function [11:0] itf_entry(input [3:0] i);
    case (i)
      4'h0: itf_entry = 12'h000;
      4'h1: itf_entry = 12'h007;
      4'h2: itf_entry = 12'h700;
      4'h3: itf_entry = 12'h707;
      4'h4: itf_entry = 12'h070;
      4'h5: itf_entry = 12'h077;
      4'h6: itf_entry = 12'h770;
      4'h7: itf_entry = 12'h777;
      4'h8: itf_entry = 12'h444;
      4'h9: itf_entry = 12'h00F;
      4'hA: itf_entry = 12'hF00;
      4'hB: itf_entry = 12'hF0F;
      4'hC: itf_entry = 12'h0F0;
      4'hD: itf_entry = 12'h0FF;
      4'hE: itf_entry = 12'hFF0;
      default: itf_entry = 12'hFFF;
    endcase
  endfunction

  // One entry's channel write, then a settle: the write lands in the BACK bank.
  task automatic wchan_write(input [1:0] ch, input [3:0] w, input [3:0] dat);
    begin
      @(negedge clk);
      we = 1'b1; wchan = ch; widx = w; wdata = dat;
      @(negedge clk);
      we = 1'b0;
    end
  endtask

  // The frame boundary starts the live-to-displayed copy, which walks 16 entries over
  // 17 clk_sys; give it that room before anything reads the displayed table.
  task automatic commit_now;
    integer t;
    begin
      @(negedge clk);
      commit = 1'b1;
      @(negedge clk);
      commit = 1'b0;
      for (t = 0; t < 24; t = t + 1) @(negedge clk);
    end
  endtask

  // Present one index and sample the registered output one dot later.
  task automatic see(input [7:0] i, input [11:0] want, input [8*72-1:0] what);
    begin
      @(negedge clk);
      idx = i;
      @(negedge clk);
      if (colour !== want) begin
        $display("FAIL %0s: index %03x read %03x, expected %03x", what, i, colour, want);
        errors = errors + 1;
      end
    end
  endtask

  // ---- the copy: its cycle-by-cycle alignment, and the write/copy boundary ----------
  // The live-to-displayed copy is the ONLY place a one-cycle difference could hide: `live`
  // is now three block-RAM lanes whose read is registered, and the copy's read register
  // (`cp_q`) carries a reset and an enable (`pc9821_gfx_palette.sv`'s own comment) - the
  // shape Quartus synthesises for that is not the shape it synthesises for a bare
  // flop array. Its intermediate cycles are not visible on a port, so these two checks
  // read `cp_cnt`, `cp_q` and `disp` inside the DUT (the white-box form
  // tb_pc9821_scanout_pipeline already uses for `disp`).
  //
  // The block-RAM half of the same claim is measured at the NETLIST level, where the memory
  // actually appears: a one-off netlist simulation fitted this module standalone,
  // writes the post-fit Verilog out and drives it with the SAME stimulus as the RTL
  // (`tb_palette.v` / `tb_palette_boundary.v`, Intel's own `generic_m10k` model) - the two
  // runs are byte-identical, entry for entry and cycle for cycle, including every write
  // that lands in the cycle the copy reads that entry.
  reg [11:0] exp_tab [0:15];   // the live table each copy under test must reproduce
  integer    busy_cycles;

  // One copy, checked as it runs. At the negedge where the FSM is working on index c
  // (cp_cnt == c) it must be holding cp_q = live[c-1] - the read it issued in the previous
  // cycle - and disp[c-2] must have just been written with live[c-2]. Entry k therefore
  // lands in disp in the cycle cp_cnt == k+1, out of the value read in the cycle cp_cnt == k:
  // one read register, no shift, nothing stored twice.
  task automatic copy_checked(input [8*64-1:0] what);
    integer c;
    begin
      busy_cycles = 0;
      @(negedge clk);
      commit = 1'b1;
      @(negedge clk);
      commit = 1'b0;
      while (dut.cp_busy === 1'b1) begin
        c = dut.cp_cnt;
        if (c >= 1 && c <= 16) begin
          if (dut.cp_q !== exp_tab[c-1]) begin
            $display("FAIL %0s: at cp_cnt=%0d cp_q=%03x, expected live[%0d]=%03x",
                     what, c, dut.cp_q, c-1, exp_tab[c-1]);
            errors = errors + 1;
          end
          if (c >= 2 && dut.disp[c-2] !== exp_tab[c-2]) begin
            $display("FAIL %0s: at cp_cnt=%0d disp[%0d]=%03x, expected live[%0d]=%03x",
                     what, c, c-2, dut.disp[c-2], c-2, exp_tab[c-2]);
            errors = errors + 1;
          end
        end
        busy_cycles = busy_cycles + 1;
        @(negedge clk);
      end
      if (busy_cycles != 17) begin
        $display("FAIL %0s: the copy ran %0d cycles, expected 17", what, busy_cycles);
        errors = errors + 1;
      end
      for (c = 0; c < 16; c = c + 1) begin
        if (dut.disp[c] !== exp_tab[c]) begin
          $display("FAIL %0s: disp[%0d]=%03x after the copy, expected %03x",
                   what, c, dut.disp[c], exp_tab[c]);
          errors = errors + 1;
        end
      end
    end
  endtask

  // The write/copy boundary. A CPU write to entry k that lands in the cycle the copy READS
  // entry k is the one cycle a block RAM's read-during-write could resolve differently from
  // a flop array (a block RAM can be told old-data, new-data or don't-care; a flop array is
  // always read-before-write). The machine-visible rule is the copy's own comment: the copy
  // reads the live table as it goes, so the write is NOT in this frame's displayed table and
  // the next boundary carries it. `at_read` picks the colliding cycle (the write is driven at
  // the negedge where cp_cnt == k, so it lands at the edge whose read is live[k]); the caller
  // also runs the cycle after it, where disp[k] is already being written out of the value
  // read before the write.
  task automatic boundary_write(input [3:0] k, input at_read, input [8*64-1:0] what);
    reg [11:0] old_entry;
    integer    target;
    begin
      target = (at_read ? 5'd0 : 5'd1) + k;
      old_entry = exp_tab[k];
      @(negedge clk);
      commit = 1'b1;
      @(negedge clk);
      commit = 1'b0;
      while (dut.cp_busy === 1'b1 && dut.cp_cnt !== target[4:0]) @(negedge clk);
      if (dut.cp_busy !== 1'b1) begin
        $display("FAIL %0s: the copy ended before cp_cnt=%0d, so the write never landed where intended",
                 what, target);
        errors = errors + 1;
      end
      // Driven at the negedge whose cp_cnt is `target`, so the write lands at the posedge
      // whose copy read is live[target].
      we = 1'b1; wchan = 2'd1; widx = k; wdata = 4'h9;   // the R lane -> 9
      @(negedge clk);
      we = 1'b0;
      if (dut.cp_cnt !== target[4:0] + 5'd1) begin
        $display("FAIL %0s: the copy is at cp_cnt=%0d one cycle after the write, expected %0d",
                 what, dut.cp_cnt, target + 1);
        errors = errors + 1;
      end
      while (dut.cp_busy === 1'b1) @(negedge clk);
      repeat (2) @(negedge clk);
      idx = {4'h0, k};
      @(negedge clk);
      if (colour !== old_entry) begin
        $display("FAIL %0s: disp[%0d] is %03x in the frame the write landed in, expected the pre-write %03x",
                 what, k, colour, old_entry);
        errors = errors + 1;
      end
      // ... and the pattern is otherwise untouched by the write.
      for (i = 0; i < 16; i = i + 1) begin
        if (i != k && dut.disp[i] !== exp_tab[i]) begin
          $display("FAIL %0s: disp[%0d]=%03x moved with the write to entry %0d",
                   what, i, dut.disp[i], k);
          errors = errors + 1;
        end
      end
      // The next frame boundary carries it, like every other live write.
      exp_tab[k] = { 4'h9, 4'd15 - k, k ^ 4'd5 };
      commit_now;
      idx = {4'h0, k};
      @(negedge clk);
      if (colour !== exp_tab[k]) begin
        $display("FAIL %0s: disp[%0d] is %03x after the next boundary, expected %03x",
                 what, k, colour, exp_tab[k]);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;

    // ---- the power-on analogue table, before any write or commit ----
    // Both banks initialise to the ITF table, so the very first frame already
    // shows it (the snapshot this table replaces showed the NEXT frame's copy).
    mode16 = 1'b1;
    for (i = 0; i < 16; i = i + 1) begin
      idx = i[7:0];
      @(negedge clk);
      if (colour !== itf_entry(i[3:0])) begin
        $display("FAIL power-on analogue entry %0d = %03x, expected %03x",
                 i, colour, itf_entry(i[3:0]));
        errors = errors + 1;
      end
    end

    // ---- the machine's power-on digital bytes ----
    dig = { 8'h37, 8'h15, 8'h26, 8'h04 };
    mode16 = 1'b0;

    see(8'd0, rgb(0,0,0), "digital entry 0 (0xAE high nibble)");
    see(8'd1, rgb(0,0,1), "digital entry 1 (0xAA high nibble)");
    see(8'd2, rgb(1,0,0), "digital entry 2 (0xAC high nibble)");
    see(8'd3, rgb(1,0,1), "digital entry 3 (0xA8 high nibble)");
    see(8'd4, rgb(0,1,0), "digital entry 4 (0xAE low nibble)");
    see(8'd5, rgb(0,1,1), "digital entry 5 (0xAA low nibble)");
    see(8'd6, rgb(1,1,0), "digital entry 6 (0xAC low nibble)");
    see(8'd7, rgb(1,1,1), "digital entry 7 (0xA8 low nibble)");

    // The digital read must use only the low three index bits: the intensity bit
    // is not a colour in 8-colour mode, so idx[3] must not change the answer.
    see(8'd5,  rgb(0,1,1), "digital entry 5");
    see(8'd13, rgb(0,1,1), "digital 8-colour ignores idx[3]");

    // ---- the analogue table through its write port ----
    // Put a distinguishable nibble in every entry: entry n -> R=n, G=15-n, B=n^5.
    // The writes go to the BACK bank, so nothing is visible until the commit.
    for (i = 0; i < 16; i = i + 1) begin
      n = i;
      gn = 4'd15 - n[3:0];
      bn = n[3:0] ^ 4'd5;
      wchan_write(2'd1, i[3:0], n[3:0]);    // R
      wchan_write(2'd0, i[3:0], gn);        // G
      wchan_write(2'd2, i[3:0], bn);        // B
    end
    // Before the commit the screen still shows the power-on table. An index the
    // written table changes must read the OLD value.
    mode16 = 1'b1;
    see(8'h08, itf_entry(4'h8), "a palette write is invisible before the frame boundary");
    commit_now;
    // ... and after it, the written entry.
    for (i = 0; i < 16; i = i + 1) begin
      n = i;
      gn = 4'd15 - n[3:0];
      bn = n[3:0] ^ 4'd5;
      see(n, { n[3:0], gn, bn }, "analogue entry after the commit");
    end
    // The intensity bit must select the upper half, so entry 0x8 must differ from
    // entry 0x0. Both are checked against the pattern above, and the pair is what
    // proves idx[3] is part of the entry select rather than ignored.
    idx = 8'h00;
    @(negedge clk);
    entry0 = colour;
    idx = 8'h08;
    @(negedge clk);
    if (colour === entry0) begin
      $display("FAIL analogue entries 0 and 8 are the same colour: idx[3] is being ignored, and the intensity plane would paint nothing");
      errors = errors + 1;
    end

    // ---- the copy's cycle alignment, then the write/copy boundary ----
    for (i = 0; i < 16; i = i + 1) begin
      n = i;
      gn = 4'd15 - n[3:0];
      bn = n[3:0] ^ 4'd5;
      exp_tab[i] = { n[3:0], gn, bn };
    end
    copy_checked("the copy is one read register deep and writes disp[k] one cycle after reading live[k]");

    // A write in the cycle the copy reads that entry (the block RAM's one ambiguous cycle),
    // and a write one cycle after it: neither may reach this frame's displayed table.
    boundary_write(4'd10, 1'b1, "a write colliding with the copy's own read of that entry");
    boundary_write(4'd3,  1'b0, "a write in the cycle after the copy read that entry");
    // The table is back to pattern+the two writes, so the copy's content check still holds.
    copy_checked("the copy after the two boundary writes");

    // ---------------------------------------------------------------
    // THE PEGC 256-COLOUR TABLE (row 4): a SECOND store beside disp/live, not a
    // widening of them. Full bytes per channel (NP2kai stores the written byte
    // verbatim and pal_make9821 renders it verbatim), the FULL 8-bit index, and
    // a REGISTERED dot read (the async form refuses every block type - the
    // 276007 family this module's header records). FAIL-FIRST: before this
    // table existed the 256-colour arm had no store at all.
    colour16_before = colour;
    p256_we = 1'b1; p256_widx = 8'h2B; p256_wchan = 2'd1; p256_wdata = 8'hFE;  // R
    @(negedge clk);
    p256_wchan = 2'd0; p256_wdata = 8'h01;                                     // G
    @(negedge clk);
    p256_wchan = 2'd2; p256_wdata = 8'h80;                                     // B
    @(negedge clk);
    p256_we = 1'b0;
    idx256 = 8'h2B;
    @(negedge clk);
    if (colour256 !== 24'hFE0180) begin
      $display("FAIL: 256-entry 2B read %06x, want fe0180 (full bytes, NP2kai)", colour256);
      errors = errors + 1;
    end
    // The FULL 8-bit index: 0x2B and 0x0B are different entries.
    idx256 = 8'h0B;
    @(negedge clk);
    if (colour256 !== 24'h000000) begin
      $display("FAIL: 256-entry 0B read %06x, want 000000 (the index is 8 bits)", colour256);
      errors = errors + 1;
    end
    // The read is REGISTERED: the value appears one clk after the index.
    idx256 = 8'h2B;
    #1;
    if (colour256 !== 24'h000000) begin
      $display("FAIL: the 256-colour read must not be combinational (got %06x early)",
               colour256);
      errors = errors + 1;
    end
    @(negedge clk);
    if (colour256 !== 24'hFE0180) begin
      $display("FAIL: the registered read did not settle one clk after the index");
      errors = errors + 1;
    end
    // ... and the 16-entry path is untouched by any of it: the combinational
    // read answers the same value before and after the 256-colour activity.
    if (colour !== colour16_before) begin
      $display("FAIL: the 256-colour table moved the 16-colour read (%03x -> %03x)",
               colour16_before, colour);
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GFX_PALETTE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GFX_PALETTE: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_GFX_PALETTE: TIMEOUT");
  end

endmodule

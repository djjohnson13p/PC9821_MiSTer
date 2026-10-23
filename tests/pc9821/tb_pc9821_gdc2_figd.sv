`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The graphics GDC executes plain-plane FIGD dots and patterned Bresenham lines in every octant against the real Xe10's unchanged GDCDRAW.CSV and GDCROP.CSV: all 288 canonical endpoint lines, 16 dot positions, eight dot directions, the 48-dot A53C pattern line and 192 strict ROP cases produce exactly the captured GVRAM words, no extra writes in any plane or page, and the captured final cursor address and mask. The memory responder stalls accepts and returns reads later, so a draw must preserve its request until acceptance. FIGD through GRCG/EGC, rectangles, arcs, GCHRD, FIFO timing and the five-byte CURD format are outside this claim. Directed no-CURS chains consume the advanced cursor mask, and a stalled current draw preserves later guest CURS/MASK writes and a second queued figure snapshot.

`default_nettype none

module tb_pc9821_gdc2_figd;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 8'hA0, io_din = 0;
  wire [7:0] io_dout;
  wire mv, mw, mre, mrg, mp;
  wire [1:0] mpl;
  wire [14:0] mo;
  wire [31:0] md;
  wire [3:0] mb;
  wire mr;
  reg resp = 0;
  reg [31:0] rdata = 0;
  reg stall = 0;
  wire [15:0] line_addr;
  wire walk_page, disp, win_off, grph_on;

  // ==== DUT ====
  pc9821_gdc2 dut (
    .clk_sys(clk), .rst_n_sys(rst_n), .pixel_ce(1'b0),
    .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
    .frame_end(1'b0), .cfg_snap(1'b0), .cfg_pending(1'b0), .vline(10'd0),
    .vtotal(10'd440), .m_vbp(6'd25), .display_page(1'b0), .pegc_256(1'b0),
    .stat_blank(1'b0), .stat_vsync(1'b0), .gfx_line_addr(line_addr),
    .gfx_walk_page(walk_page), .gfx_disp(disp), .gfx_win_off(win_off), .gfx_grph_on(grph_on),
    .egc_mem_gate(1'b0), .grcg_cg_gate(1'b0), .access_page(1'b0),
    .mem_valid(mv), .mem_ready(mr), .mem_write(mw), .mem_route_egc(mre),
    .mem_route_grcg(mrg), .mem_page(mp), .mem_plane(mpl), .mem_offset(mo),
    .mem_din(md), .mem_be(mb), .mem_resp(resp), .mem_rdata(rdata));

  reg [15:0] memory [0:131071];
  reg [15:0] expected [0:131071];
  integer clock_n = 0, rd_delay = 0;
  reg [31:0] rd_payload;
  wire [16:0] base_idx = {mp, mpl, mo[14:2], 1'b0};
  assign mr = mv && !stall && rd_delay == 0 && !resp && (clock_n % 3 != 0);
  // The RAM is only a byte-enabled bus responder, never a graphics oracle.
  // All expected pixels come directly from the independent machine capture.
  always @(posedge clk) begin
    clock_n <= clock_n + 1;
    resp <= 0;
    if (rd_delay != 0) begin
      rd_delay <= rd_delay - 1;
      if (rd_delay == 1) begin resp <= 1; rdata <= rd_payload; end
    end
    if (rst_n && mv && mr) begin
      if (mw) begin
        if (mb[0]) memory[base_idx][7:0] = md[7:0];
        if (mb[1]) memory[base_idx][15:8] = md[15:8];
        if (mb[2]) memory[base_idx+1][7:0] = md[23:16];
        if (mb[3]) memory[base_idx+1][15:8] = md[31:24];
      end else begin
        rd_payload <= {memory[base_idx+1], memory[base_idx]};
        rd_delay <= 2 + clock_n % 4;
      end
    end
    if (rst_n && resp && mr) $fatal(1, "responder accepted in its read-response cycle");
  end

  reg held = 0;
  reg [56:0] held_request;
  always @(posedge clk) begin
    if (rst_n && held && (!mv || {mw,mre,mrg,mp,mpl,mo,md,mb} !== held_request))
      $fatal(1, "FIGD request changed before its accept (R7)");
    held <= rst_n && mv && !mr;
    held_request <= {mw,mre,mrg,mp,mpl,mo,md,mb};
  end

  `include "gdc_figd_vectors.svh"
  integer errors = 0, checks = 0;
  task automatic fail(input string reason);
    begin
      errors++;
      if (errors <= 10) $display("FAIL %s", reason);
    end
  endtask
  task automatic write_io(input [7:0] portnum, input [7:0] value);
    begin
      @(negedge clk); io_wr = 1; io_addr = portnum; io_din = value;
      @(negedge clk); io_wr = 0;
      @(negedge clk);
    end
  endtask
  task automatic param_word(input [15:0] value);
    begin write_io(8'hA0, value[7:0]); write_io(8'hA0, value[15:8]); end
  endtask
  task automatic read_param(output [7:0] value);
    begin
      @(negedge clk); io_addr = 8'hA2; io_rd = 1;
      @(negedge clk); io_rd = 0;
      @(negedge clk); value = io_dout;
    end
  endtask
  task automatic wait_idle;
    integer elapsed;
    begin
      elapsed = 0;
      while ((dut.d_state != 0 || dut.pend_valid) && elapsed < 50000) begin
        @(negedge clk); elapsed++;
      end
      if (elapsed == 50000) $fatal(1,"FIGD did not drain its pending queue");
      repeat (4) @(negedge clk);
    end
  endtask
  task automatic clear_memory;
    integer i;
    begin
      for (i = 0; i < 131072; i++) begin memory[i] = 0; expected[i] = 0; end
    end
  endtask
  task automatic check_memory(input string name);
    integer i;
    begin
      for (i = 0; i < 131072; i++) begin
        checks++;
        if (memory[i] !== expected[i])
          fail($sformatf("%s word %05h got %04h expected %04h",name,i,memory[i],expected[i]));
      end
    end
  endtask
  task automatic check_cursor(input [15:0] ead, input [15:0] mask);
    reg [7:0] lo, hi;
    begin
      write_io(8'hA2,8'hE0); read_param(lo); read_param(hi);
      checks++;
      if ({hi,lo} !== ead) fail($sformatf("cursor EAD got %04h expected %04h",{hi,lo},ead));
      checks++;
      if (dut.gdc2_cursor_mask !== mask)
        fail($sformatf("next FIGD cursor mask got %04h expected %04h",dut.gdc2_cursor_mask,mask));
    end
  endtask
  task automatic cursor(input [15:0] ead, input [3:0] dad);
    begin
      write_io(8'hA2,8'h49); param_word(ead); write_io(8'hA0,{dad,4'd0});
    end
  endtask
  task automatic figure(input [7:0] p1, input [15:0] dc, input [15:0] d,
                        input [15:0] d2, input [15:0] d1);
    begin
      write_io(8'hA2,8'h4C); write_io(8'hA0,p1);
      param_word(dc); param_word(d); param_word(d2); param_word(d1); param_word(16'hFFFF);
      write_io(8'hA2,8'h6C);
    end
  endtask

  // ==== CHECKS ====
  initial begin : cases
    reg [7:0] p1, b0, b1;
    reg [15:0] dc, d, d2, d1, dm, pattern, old, end_mask, pixel_index;
    reg [17:0] ead, end_ead;
    reg [3:0] dad;
    reg [1:0] rop;
    reg [5:0] word_count;
    integer v, i, w, elapsed;
    repeat (4) @(negedge clk);
    rst_n = 1;
    for (v = 0; v < FIGD_CASES; v++) begin
      {p1,dc,d,d2,d1,dm,ead,dad,pattern,rop,old,end_ead,end_mask,pixel_index,word_count}
        = FIGD_VECTORS[v];
      for (i = 0; i < 131072; i++) begin memory[i] = 0; expected[i] = 0; end
      memory[17'h5000] = old; expected[17'h5000] = old; // captured plane R word 1000
      for (i = 0; i < int'(word_count); i++) begin
        w = int'(pixel_index) + i;
        expected[17'h4000 + {3'd0, FIGD_PIXELS[w][29:16]}] = FIGD_PIXELS[w][15:0];
      end
      // WDAT command alone selects the ROP; no data bytes => no WDAT draw.
      write_io(8'hA2, 8'h20 | {6'd0,rop});
      write_io(8'hA2, 8'h78); param_word(pattern);
      write_io(8'hA2, 8'h49); param_word(ead[15:0]);
      write_io(8'hA0, {dad,2'd0,ead[17:16]});
      write_io(8'hA2, 8'h4C); write_io(8'hA0,p1);
      param_word(dc); param_word(d); param_word(d2); param_word(d1); param_word(dm);
      write_io(8'hA2, 8'h6C);
      elapsed = 0;
      while ((dut.d_state != 0 || dut.pend_valid) && elapsed < 50000) begin
        @(negedge clk); elapsed++;
      end
      if (elapsed == 50000) $fatal(1, "FIGD case %0d did not finish", v);
      repeat (4) @(negedge clk);
      for (i = 0; i < 131072; i++) begin
        checks++;
        if (memory[i] !== expected[i])
          fail($sformatf("capture %0d word %05h got %04h expected %04h",v,i,memory[i],expected[i]));
      end
      write_io(8'hA2,8'hE0); read_param(b0); read_param(b1);
      checks++;
      if ({b1,b0} !== end_ead[15:0])
        fail($sformatf("capture %0d final EAD got %04h expected %04h",v,{b1,b0},end_ead[15:0]));
      // CURD's five-byte format is a known independent gap; this assertion pins
      // the MASK state which the NEXT figure consumes, using the machine's mask.
      checks++;
      if ({dut.gdc2_mask[1],dut.gdc2_mask[0]} !== end_mask)
        fail($sformatf("capture %0d final MASK got %04h expected %04h",v,{dut.gdc2_mask[1],dut.gdc2_mask[0]},end_mask));
      checks++;
      if (dut.gdc2_cursor_mask !== end_mask)
        fail($sformatf("capture %0d next FIGD mask got %04h expected %04h",v,dut.gdc2_cursor_mask,end_mask));
    end

    // Two FIGDs with NO intervening CURS/MASK consume the cursor left by the
    // first figure. The two pixel positions are Xe10 DOT_DAD07/08's 0001/8000;
    // the second direction is DOT_DIR2's captured cursor advance to mask 0200.
    clear_memory;
    write_io(8'hA2,8'h23); write_io(8'hA2,8'h78); param_word(16'hFFFF);
    cursor(16'h9000,4'd7); figure(8'h02,0,0,0,0); wait_idle;
    check_cursor(16'h9000,16'h0100);
    write_io(8'hA2,8'h6C); wait_idle;
    expected[17'h5000] = 16'h8001;
    check_memory("two FIGDs with no CURS");
    check_cursor(16'h9000,16'h0200);

    // A new CURS and MASK while the current visit is stalled are later guest
    // intent, so completing the old dot cannot erase either. The following
    // figure has NO CURS: it must consume that retained address and MASK.
    clear_memory;
    cursor(16'h9000,4'd0);
    stall = 1;
    figure(8'h02,0,0,0,0);
    if (!mv) $fatal(1,"stalled cursor test never presented a visit");
    cursor(16'h9100,4'd9);
    write_io(8'hA2,8'h4A); param_word(16'h0400);
    stall = 0; wait_idle;
    check_cursor(16'h9100,16'h0400);
    write_io(8'hA2,8'h6C); wait_idle;
    expected[17'h5000] = 16'h0080; // DOT_DAD00
    expected[17'h5100] = 16'h2000; // DOT_DAD10
    check_memory("CURS and MASK survive old completion");
    check_cursor(16'h9100,16'h0800);

    // A second FIGD queues while the first is stalled. Its later PRAM/CURS/FIGS
    // writes cannot change the first job's snapshots. The first expected words
    // are LINE_PATTERN_A53C verbatim; the second DOT_DAD00 adds its captured bit.
    clear_memory;
    write_io(8'hA2,8'h78); param_word(16'hA53C);
    cursor(16'h9000,4'd8);
    stall = 1;
    figure(8'h0A,16'd47,16'hFFD1,16'hFFA2,16'd0);
    write_io(8'hA2,8'h78); param_word(16'hFFFF);
    cursor(16'h9000,4'd0);
    figure(8'h00,0,0,0,0);
    if (!dut.pend_valid) $fatal(1,"second FIGD did not queue behind stalled first");
    stall = 0; wait_idle;
    expected[17'h5000] = 16'h3C80;
    expected[17'h5001] = 16'h3CA5;
    expected[17'h5002] = 16'h3CA5;
    expected[17'h5003] = 16'h00A5;
    check_memory("queued FIGD snapshots");
    check_cursor(16'h9028,16'h0001);
    // ==== VERDICT ====
    $display("NOTE gdc2_figd: %0d machine-capture cases, %0d checks, %0d errors",FIGD_CASES,checks,errors);
    if (errors != 0) $fatal(1,"TB_PC9821_GDC2_FIGD: FAIL (%0d errors)",errors);
    $display("TB_PC9821_GDC2_FIGD: PASS");
    $finish;
  end
  initial begin
    #100_000_000;
    $fatal(1,"TB_PC9821_GDC2_FIGD: TIMEOUT");
  end
endmodule

`default_nettype wire


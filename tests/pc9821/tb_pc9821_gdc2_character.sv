`timescale 1ns/1ps
// ==== WHAT THIS PROVES ====
// The graphics GDC plain-plane character command replays545 explicit-input Xe10 GDCGCHR observations (one-hot rotations, solid areas, zoom1..16, zero replacement and PRAM address selection), comparing complete GVRAM contents and captured final cursor under stalled memory responses. Nine slant/mixed cases retain unknown input glyphs and are explicitly unreplayed; this is not full-family qualification. Command preamble is NEC Design Manual v3 sections4.24.13-14, not a recovered byte-identical rc6 program.

`default_nettype none

module tb_pc9821_gdc2_character;
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

  `include "gdc_character_vectors.svh"
  integer errors=0,checks=0;
  task automatic fail(input string reason);
    begin errors++; if(errors<=12)$display("FAIL %s",reason);end
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

  // ==== CHECKS ====
  initial begin : cases
    reg [7:0] p1,lo,hi;
    reg [15:0] dc,d,end_mask,pixel_index;
    reg [17:0] end_ead;
    reg [63:0] pram;
    reg [3:0] zoom,pram_start,pram_length;
    reg [1:0] rop;
    reg [5:0] count;
    integer v,i,w,offset,elapsed;
    repeat(4) @(negedge clk);rst_n=1;
    $display("GCHRD_CAPTURE_ACCOUNTING total=554 replayable=545 unreplayed_unknown_glyph=9");
    for(v=0;v<GCHR_CASES;v++) begin
      {p1,dc,d,zoom,pram,pram_start,pram_length,rop,end_ead,end_mask,pixel_index,count}=GCHR_VECTORS[v];
      for(i=0;i<131072;i++) begin memory[i]=0;expected[i]=0;end
      for(i=0;i<int'(count);i++) begin
        w=int'(pixel_index)+i;offset=17'h4000+int'(GCHR_PIXELS[w][45:32]);
        memory[offset]=GCHR_PIXELS[w][31:16];expected[offset]=GCHR_PIXELS[w][15:0];
      end
      // Canonical manual setup: replace/set RMW; writing zoom; pitch40;
      // PRAM8..15; cursor EAD09000,DAD8; FIGS GC+DIR,DC,D; GCHRD.
      write_io(8'hA2,8'h20|{6'd0,rop});
      write_io(8'hA2,8'h46);write_io(8'hA0,{4'd0,zoom});
      write_io(8'hA2,8'h47);write_io(8'hA0,8'd40);
      write_io(8'hA2,8'h78);
      for(i=0;i<8;i++)write_io(8'hA0,8'd0);
      write_io(8'hA2,8'h70|{4'd0,pram_start});
      for(i=0;i<int'(pram_length);i++)write_io(8'hA0,pram[(int'(pram_start)-8+i)*8+:8]);
      cursor(16'h9000,4'd8);
      write_io(8'hA2,8'h4C);write_io(8'hA0,p1);param_word(dc);param_word(d);
      write_io(8'hA2,8'h68);
      elapsed=0;
      while((dut.d_state!=0 || dut.pend_valid) && elapsed<100000)begin @(negedge clk);elapsed++;end
      if(elapsed==100000)$fatal(1,"GCHRD did not drain case%0d",v);
      repeat(4)@(negedge clk);
      check_memory($sformatf("GCHRD capture%0d",v));
      write_io(8'hA2,8'hE0);read_param(lo);read_param(hi);
      checks++;
      if({hi,lo}!==end_ead[15:0])fail($sformatf("GCHRD capture%0d EAD got%04h expected%04h",v,{hi,lo},end_ead[15:0]));
      checks++;
      if(dut.gdc2_cursor_mask!==end_mask)fail($sformatf("GCHRD capture%0d mask got%04h expected%04h",v,dut.gdc2_cursor_mask,end_mask));
    end
    if(errors!=0)$fatal(1,"TB_PC9821_GDC2_CHARACTER: FAIL (%0d errors; %0d checks;545 cases)",errors,checks);
    $display("TB_PC9821_GDC2_CHARACTER: PASS");$finish;
  end
endmodule

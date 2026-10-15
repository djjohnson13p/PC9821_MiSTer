`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GDC_LOG: The display-programming log (pc9821_gdc_log, the --dbg-gdc debug instrument) puts out the record format tools/decode_dbglog.py reads: an ALIVE record (type 0x1F) at power-up and after a reset; a seven-byte 0xA5/type/ms/raster-line/value record for every GDC display command and each of its parameter bytes on both GDCs (SCROLL 0x70 and TEXTW 0x78 with their bytes, SYNC, CSRFORM, PITCH, START/STOP) while the drawing traffic (CSRW, VECTW, WRITE, MASK) and its parameters are dropped; the five register ports 0x68/0x6A/0xA4/0xA6/0x09A8 only when the value changes; a millisecond time that advances and the raster line each write landed on; with the UART stalled until the ring fills, a LOST record (type 0x1E) carrying the exact count of dropped writes once it drains; and the text-attribute run records - a fill of consecutive cells with one value is ONE nine-byte record, and a value change or a non-consecutive cell starts a new one carrying the previous run's last cell.


`default_nettype none

module tb_pc9821_gdc_log;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 1'b0;
  reg io_wr = 1'b0;
  reg [15:0] io_addr = 16'h0;
  reg [7:0] io_din = 8'h0;
  reg [9:0] vline = 10'd0;
  reg tram_we = 1'b0;
  reg [13:0] tram_addr = 14'd0;
  reg [7:0] tram_din = 8'd0;   // a free-running raster stand-in: one line per 7 clocks
  always @(posedge clk) vline <= (vline == 10'd439) ? 10'd0 : vline + 10'd1;
  wire [7:0] log_byte;
  wire log_we;
  reg accept_en = 1'b1;
  wire log_accept = log_we && accept_en;

  // ==== DUT ====
  // 10,000 Hz: one millisecond is ten clocks, so the time field visibly advances.
  pc9821_gdc_log #(.LOG_CLK_HZ(10_000)) dut (
      .clk(clk), .rst_n(rst_n), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .vline(vline),
      .tram_we(tram_we), .tram_addr(tram_addr), .tram_din(tram_din),
      .log_byte(log_byte), .log_we(log_we), .log_accept(log_accept));

  // The captured stream.
  reg [7:0] cap [0:65535];
  integer ncap = 0;
  always @(posedge clk) if (log_accept) begin cap[ncap] <= log_byte; ncap <= ncap + 1; end

  integer errors = 0;
  task automatic fail(input string m);
    begin $display("FAIL: %0s", m); errors = errors + 1; end
  endtask

  // A guest OUT: one write strobe, then the bus idle for the rest of an I/O cycle.
  reg [9:0] last_line;
  task automatic out(input [15:0] a, input [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_din = d; io_wr = 1'b1; last_line = vline;
      @(negedge clk); io_wr = 1'b0;
      repeat (12) @(negedge clk);
    end
  endtask

  // The expected records (type, value), in order.
  reg [7:0] ex_t [0:255];
  reg [7:0] ex_v [0:255];
  reg [9:0] ex_l [0:255];
  reg       ex_lc [0:255];   // check the line (port writes; not ALIVE)
  integer nex = 0;
  task automatic expect_rec(input [7:0] t, input [7:0] v);
    begin ex_t[nex] = t; ex_v[nex] = v; ex_lc[nex] = 1'b0; nex = nex + 1; end
  endtask
  // OUT that must be logged as port code n.
  task automatic out_l(input [15:0] a, input [7:0] d, input [3:0] n);
    begin
      expect_rec({4'h1, n}, d); out(a, d);
      ex_l[nex-1] = last_line; ex_lc[nex-1] = 1'b1;
    end
  endtask

  task automatic drain();
    begin repeat (2000) @(negedge clk); end
  endtask

  // Check the captured stream against the expectation from record `from`.
  task automatic check_stream(input integer from_rec, input integer upto);
    integer r, b;
    reg [15:0] t, tprev;
    begin
      tprev = 16'h0;
      for (r = from_rec; r < upto; r = r + 1) begin
        b = r * 7;
        if (b + 6 >= ncap) begin fail($sformatf("record %0d missing (captured %0d bytes)", r, ncap)); r = upto; end
        else begin
          if (cap[b] !== 8'hA5) fail($sformatf("record %0d: sync %02x", r, cap[b]));
          if (cap[b+1] !== ex_t[r]) fail($sformatf("record %0d: type %02x, expected %02x", r, cap[b+1], ex_t[r]));
          if (cap[b+6] !== ex_v[r]) fail($sformatf("record %0d: value %02x, expected %02x", r, cap[b+6], ex_v[r]));
          if (ex_lc[r] && {cap[b+4][1:0], cap[b+5]} !== ex_l[r])
            fail($sformatf("record %0d: raster line %0d, expected %0d", r, {cap[b+4][1:0], cap[b+5]}, ex_l[r]));
          t = {cap[b+2], cap[b+3]};
          if (r > from_rec && t < tprev) fail($sformatf("record %0d: time %0d went backwards from %0d", r, t, tprev));
          tprev = t;
        end
      end
    end
  endtask

  integer i, nrec_before;
  reg [15:0] t_first, t_last;

  // ==== CHECKS ====
  initial begin
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    // 1. power-up / reset: ALIVE (once: the power-up and the end of the first reset are one)
    expect_rec(8'h1F, 8'h5A);
    repeat (20) @(negedge clk);
    // 2. a master.lib-style SCROLL on GDC2, one command per byte (Policenauts ITP's own shape)
    for (i = 0; i < 8; i = i + 1) begin
      out_l(16'h00A2, 8'h70 | i[7:0], 4'd3);
      out_l(16'h00A0, 8'h10 + i[7:0], 4'd2);
    end
    // the firmware's whole-block SCROLL and its TEXTW clear (partitions 3/4)
    out_l(16'h00A2, 8'h70, 4'd3);
    for (i = 0; i < 16; i = i + 1) out_l(16'h00A0, i[7:0], 4'd2);
    out_l(16'h00A2, 8'h78, 4'd3);
    for (i = 0; i < 8; i = i + 1) out_l(16'h00A0, 8'h00, 4'd2);
    // 3. the drawing traffic is dropped: CSRW + 3, MASK + 2, VECTW + 11, WRITE + 2
    out(16'h00A2, 8'h49); out(16'h00A0, 8'h12); out(16'h00A0, 8'h34); out(16'h00A0, 8'h00);
    out(16'h00A2, 8'h4A); out(16'h00A0, 8'hFF); out(16'h00A0, 8'hFF);
    out(16'h00A2, 8'h4C); for (i = 0; i < 11; i = i + 1) out(16'h00A0, i[7:0]);
    out(16'h00A2, 8'h20); out(16'h00A0, 8'hAA); out(16'h00A0, 8'h55);
    // and on the text GDC: the cursor (CSRW) is dropped, SYNC/CSRFORM/PITCH/START are logged
    out(16'h0062, 8'h49); out(16'h0060, 8'h00); out(16'h0060, 8'h00); out(16'h0060, 8'h00);
    out_l(16'h0062, 8'h0E, 4'd1);
    for (i = 0; i < 8; i = i + 1) out_l(16'h0060, 8'h40 + i[7:0], 4'd0);
    out_l(16'h0062, 8'h4B, 4'd1); out_l(16'h0060, 8'h0F, 4'd0);
    out_l(16'h0062, 8'h47, 4'd1); out_l(16'h0060, 8'h50, 4'd0);
    out_l(16'h0062, 8'h0D, 4'd1);
    out(16'h0060, 8'h99);   // a parameter after START: START takes none
    out_l(16'h00A2, 8'h0C, 4'd3);
    // 4. the register ports: logged on change only
    out_l(16'h00A4, 8'h01, 4'd6); out(16'h00A4, 8'h01); out_l(16'h00A4, 8'h00, 4'd6);
    out_l(16'h00A6, 8'h01, 4'd7); out(16'h00A6, 8'h01);
    out_l(16'h0068, 8'h08, 4'd4); out_l(16'h0068, 8'h09, 4'd4); out(16'h0068, 8'h09);
    out_l(16'h006A, 8'h07, 4'd5); out_l(16'h006A, 8'h05, 4'd5); out(16'h006A, 8'h05);
    out_l(16'h09A8, 8'h01, 4'd8); out(16'h09A8, 8'h01);
    // unlogged ports
    out(16'h0064, 8'h00); out(16'h007C, 8'h80); out(16'h00A8, 8'h12);
    drain();
    check_stream(0, nex);
    if (ncap != nex * 7) fail($sformatf("captured %0d bytes, expected %0d", ncap, nex * 7));
    t_first = {cap[2], cap[3]}; t_last = {cap[(nex-1)*7+2], cap[(nex-1)*7+3]};
    if (t_last <= t_first) fail($sformatf("the millisecond time did not advance (%0d -> %0d)", t_first, t_last));

    // 5. a reset: ALIVE again, and the register dedupe restarts
    @(negedge clk); rst_n = 1'b0; repeat (4) @(negedge clk); rst_n = 1'b1;
    nrec_before = nex;
    expect_rec(8'h1F, 8'h5A);
    repeat (20) @(negedge clk);
    out_l(16'h00A4, 8'h00, 4'd6);   // same value as before the reset: logged again
    drain();
    check_stream(nrec_before, nex);

    // 6. the ring full: stall the UART, write until 400 records were attempted (a 2 KiB ring
    // holds 291), then drain: the first ~291 come out, then a LOST record with the drop count
    nrec_before = ncap / 7;
    accept_en = 1'b0;
    for (i = 0; i < 400; i = i + 1) out_l(16'h00A0 + 16'h2, 8'h70, 4'd3);
    accept_en = 1'b1;
    drain(); drain(); drain();
    begin : lostcheck
      integer kept, b;
      // the drained ring: 1 record already in the output register plus the ring's capacity
      kept = (ncap / 7) - nrec_before - 1;   // minus the LOST record
      b = (ncap / 7 - 1) * 7;
      if (cap[b] !== 8'hA5 || cap[b+1] !== 8'h1E)
        fail($sformatf("no LOST record at the end of the drain (type %02x)", cap[b+1]));
      else if (cap[b+6] != 400 - kept)
        fail($sformatf("LOST counts %0d, but %0d of 400 were dropped", cap[b+6], 400 - kept));
      else if (kept < 285)
        fail($sformatf("only %0d records survived a stalled 2 KiB ring", kept));
      else $display("ring: %0d kept, LOST %0d", kept, cap[b+6]);
    end

    // 7. text-attribute runs: cells 0..79 = E1, 80..159 = 05, then 1680..1999 = 05 (a jump)
    begin : attrs
      integer c, p0;
      drain();
      p0 = ncap;
      for (c = 0; c < 2000; c = c + 1) begin
        if (c < 160 || c >= 1680) begin
          @(negedge clk); tram_addr = 14'h2000 + c[13:0] * 2; tram_din = (c < 80) ? 8'hE1 : 8'h05;
          tram_we = 1'b1;
          @(negedge clk); tram_addr = tram_addr + 14'd1; tram_din = 8'h00;   // the odd byte
          @(negedge clk); tram_we = 1'b0;
          repeat (6) @(negedge clk);
        end
      end
      drain();
      if (ncap - p0 != 27) fail($sformatf("attribute runs: %0d bytes, expected 3 records (27)", ncap - p0));
      else begin
        if (cap[p0+1] !== 8'h19 || {cap[p0+4], cap[p0+5]} !== 16'h0FFF || {cap[p0+6], cap[p0+7]} !== 16'd0 || cap[p0+8] !== 8'hE1)
          fail("attribute run 1: not {prev FFF, start 0, E1}");
        if (cap[p0+10] !== 8'h19 || {cap[p0+13], cap[p0+14]} !== 16'd79 || {cap[p0+15], cap[p0+16]} !== 16'd80 || cap[p0+17] !== 8'h05)
          fail("attribute run 2: not {prev 79, start 80, 05}");
        if (cap[p0+19] !== 8'h19 || {cap[p0+22], cap[p0+23]} !== 16'd159 || {cap[p0+24], cap[p0+25]} !== 16'd1680 || cap[p0+26] !== 8'h05)
          fail("attribute run 3: not {prev 159, start 1680, 05}");
      end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GDC_LOG: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GDC_LOG: FAIL (%0d errors)", errors);
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_GDC_LOG: TIMEOUT");
  end
endmodule

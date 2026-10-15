// tb_pc9821_ata_idcyl — the legacy-cylinder IDENTIFY word across every capacity class.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_IDCYL:
// The IDENTIFY geometry words across every capacity class that separates implementations: each capacity is set, IDENTIFY is issued, the whole 256-word block is consumed through the task file and word 1 (the factory-default 16-head/63-sector cylinder count floor(capacity/1008)) and word 54 (the current 8-head/17-sector count floor(capacity/136)) are compared against the bench's own integer division, each clamped at 0xFFFF - the clamp boundary 136*65536 and its neighbours, a capacity whose quotient is exactly 0xFFFF, and capacities up to 2^32 whose quotient the 16-bit field cannot hold. The module computes both with a two-pass 32-clock shift-and-subtract divider; the bench passes against either arithmetic, so it pins the answer rather than the divider.


module tb_pc9821_ata_idcyl;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1;
  reg readonly = 0;
  reg [31:0] capacity = 32'd1000;
  wire block_read;
  wire block_write;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0, block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire irq;

  // ==== DUT ====
  pc9821_ata dut (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk),
      .rst_n(rst_n),
      .io_rd(io_rd),
      .io_wr(io_wr),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted),
      .readonly(readonly),
      .capacity(capacity),
      .block_read(block_read),
      .block_write(block_write),
      .block_lba(block_lba),
      .block_done(block_done),
      .block_error(block_error),
      .block_buf_we(block_buf_we),
      .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr),
      .block_rd_data(block_rd_data),
      .irq(irq)
  );

  integer errors = 0;
  integer n;
  reg [7:0] value;
  reg [15:0] word_value;

  task fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr;
      io_din  = data;
      io_wr   = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr;
      io_rd   = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task read_word(output [15:0] data);
    reg [7:0] lo, hi;
    begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
      data = {hi, lo};
    end
  endtask

  // What the machine defines each word to be (docs/probes/IDE.TXT): word 1 is the
  // FACTORY default 16-head/63-sector count (capacity/1008), word 54 is the
  // CURRENT 8-head/17-sector count (capacity/136). Both fields are 16 bits, so a
  // quotient that does not fit saturates. These are the bench's own exact integer
  // divisions, never a value read out of the RTL.
  function [15:0] want_default_cylinders(input [31:0] cap);
    reg [31:0] q;
    begin
      q = cap / 32'd1008;
      if (q > 32'd65535) q = 32'd65535;
      want_default_cylinders = q[15:0];
    end
  endfunction

  function [15:0] want_current_cylinders(input [31:0] cap);
    reg [31:0] q;
    begin
      q = cap / 32'd136;
      if (q > 32'd65535) q = 32'd65535;
      want_current_cylinders = q[15:0];
    end
  endfunction

  // ==== CHECKS ====
  // The capacity classes that separate implementations, plus a random spread. The random
  // entries are fixed constants, not an LFSR, so a failure names the same capacity twice.
  localparam integer NCAP = 18;
  reg [31:0] caps [0:NCAP-1];
  reg [15:0] exp_default, exp_current;
  integer i, w;

  initial begin
    caps[0]  = 32'd0;
    caps[1]  = 32'd1;
    caps[2]  = 32'd135;
    caps[3]  = 32'd136;
    caps[4]  = 32'd137;
    caps[5]  = 32'd1000;
    caps[6]  = 32'd4096;
    caps[7]  = 32'd8_911_896;      // 136 * 65536 - 92000 : a plain quotient
    caps[8]  = 32'd8_912_759;      // 136 * 65535: quotient exactly 0xFFFF, one below the clamp
    caps[9]  = 32'd8_912_760;      // quotient 0x10000: the clamp's first capacity
    caps[10] = 32'd8_912_896;      // 136 * 65536
    caps[11] = 32'd16_777_215;     // 2^24 - 1
    caps[12] = 32'd16_777_216;     // 2^24
    caps[13] = 32'd16_777_217;
    caps[14] = 32'd16_843_576;     // 136 * 123_849: quotient 123_849
    caps[15] = 32'd268_435_456;    // 2^28
    caps[16] = 32'd2_147_483_647;
    caps[17] = 32'd4_294_967_295;

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    write_byte(16'h0432, 8'h01);   // select the bank the interface is on

    for (i = 0; i < NCAP; i = i + 1) begin
      capacity = caps[i];
      // The module recomputes over two 32-clock divider passes; the wait is long
      // enough for either form, so the same bench pins both.
      repeat (80) @(posedge clk);
      exp_default = want_default_cylinders(caps[i]);
      exp_current = want_current_cylinders(caps[i]);

      write_byte(16'h064E, 8'hEC);   // IDENTIFY DEVICE
      // The word pointer only advances, so the whole block is consumed to reach word 54.
      for (w = 0; w < 256; w = w + 1) begin
        read_word(word_value);
        if (w == 0 && word_value !== 16'h044A)
          fail("IDENTIFY word 0 is not the machine's general-config word");
        if (w == 1 && word_value !== exp_default) begin
          $display("  capacity %0d: word 1 = %0d, want %0d", caps[i], word_value, exp_default);
          fail("IDENTIFY word 1 (default cylinders)");
        end
        if (w == 54 && word_value !== exp_current) begin
          $display("  capacity %0d: word 54 = %0d, want %0d", caps[i], word_value, exp_current);
          fail("IDENTIFY word 54 (current cylinders)");
        end
      end
      if (dut.xfer_state !== 3'd0) fail("IDENTIFY did not finish");
      if (dut.status_reg !== 8'h50)
        fail("the task file did not return to the ready status after IDENTIFY");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_IDCYL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_IDCYL: FAIL (%0d errors)", errors);
  end

  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_ATA_IDCYL: TIMEOUT");
  end

endmodule

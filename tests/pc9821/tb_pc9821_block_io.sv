// tb_pc9821_block_io — MiSTer image metadata and SD-block handshake checks.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_BLOCK_IO:
// The MiSTer image metadata and SD-block handshake: an unmounted request fails immediately, metadata is latched, the request reaches hps_io, the buffer streams through, sd_rd clears on acknowledge, completion pulses with status, and a short block is rejected; words hps_io streams for ANOTHER slot's transfer while this request waits for its own acknowledge are ignored.


module tb_pc9821_block_io;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg img_mounted = 0, img_readonly = 0;
  reg [63:0] img_size = 0;
  wire mounted, readonly;
  wire [31:0] capacity;
  reg req_read = 0;
  reg req_write = 0;
  reg [31:0] req_lba = 0;
  wire req_done, req_error, buf_we, busy;
  wire [7:0] buf_addr;
  wire [15:0] buf_data;
  wire [7:0] buf_rd_addr;
  reg [15:0] buf_rd_data = 0;
  wire [31:0] sd_lba;
  wire sd_rd, sd_wr;
  wire [15:0] sd_buff_din;
  reg sd_ack = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [31:0] dbg_hps_cycles;
  integer errors = 0;
  integer hps_cycles_start = 0;   // the cycle the request went out, for the HP assertion
  integer word_index;
  integer foreign_we = 0;

  // ==== DUT ====
  pc9821_block_io dut (
      .clk(clk),
      .rst_n(rst_n),
      .img_mounted(img_mounted),
      .img_readonly(img_readonly),
      .img_size(img_size),
      .mounted(mounted),
      .readonly(readonly),
      .capacity(capacity),
      .req_read(req_read),
      .req_write(req_write),
      .req_lba(req_lba),
      // The sole owner of its engine: the window is its own, and a mount replaces the image
      // the window's blocks came from (pc9821_block_io's header).
      .req_window(1'b1),
      .win_flush(img_mounted),
      .req_done(req_done),
      .req_error(req_error),
      .buf_we(buf_we),
      .buf_addr(buf_addr),
      .buf_data(buf_data),
      .buf_rd_addr(buf_rd_addr),
      .buf_rd_data(buf_rd_data),
      .sd_lba(sd_lba),
      .sd_rd(sd_rd),
      .sd_wr(sd_wr),
      .sd_ack(sd_ack),
      .sd_buff_wr(sd_buff_wr),
      .sd_buff_addr(sd_buff_addr),
      .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps_cycles),
      .sd_buff_din(sd_buff_din),
      .busy(busy)
  );
  // ==== STIMULUS ====

  task fail(input [8*80-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task pulse_request(input [31:0] lba);
    begin
      @(negedge clk);
      req_lba  = lba;
      req_read = 1;
      @(posedge clk);
      @(negedge clk);
      req_read = 0;
    end
  endtask

  task pulse_mount(input [63:0] size, input ro);
    begin
      @(negedge clk);
      img_size = size;
      img_readonly = ro;
      img_mounted = 1;
      @(posedge clk);
      @(negedge clk);
      img_mounted = 0;
    end
  endtask

  // Write direction: the drive asks for a block write and the host reads the
  // drive's buffer through sd_buff_din at whatever address it presents.
  task pulse_write_request(input [31:0] lba);
    begin
      @(negedge clk);
      req_lba   = lba;
      req_write = 1;
      @(posedge clk);
      @(negedge clk);
      req_write = 0;
    end
  endtask
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    pulse_request(0);
    if (!req_done || !req_error || sd_rd) fail("unmounted request did not fail immediately");

    pulse_mount(64'd2048, 1'b1);
    if (!mounted || !readonly || capacity !== 32'd4) fail("image metadata was not latched");

    pulse_request(2);
    if (!sd_rd || !busy || sd_lba !== 32'd2) fail("block request was not presented to hps_io");

    @(negedge clk);
    sd_ack = 1;
    for (word_index = 0; word_index < 256; word_index = word_index + 1) begin
      sd_buff_wr = 1;
      sd_buff_addr = word_index;
      sd_buff_dout = 16'hA500 | word_index[7:0];
      #1;
      // Every word, not a sample: a stream that shifts by one would still hit a
      // single probe index.
      if (!buf_we || buf_addr !== word_index[7:0] ||
          buf_data !== (16'hA500 | word_index[7:0]))
        fail("SD buffer stream passthrough (word mismatch)");
      @(posedge clk);
      @(negedge clk);
    end
    sd_buff_wr = 0;
    if (sd_rd) fail("sd_rd remained asserted after acknowledge");
    sd_ack = 0;
    @(posedge clk);
    #1;
    if (!req_done || req_error || busy) fail("block completion pulse/status");
    // HP: the last completed transfer's cycles. It is the ONLY instrument this tree has for the
    // HPS block round trip (no bench models the ARM), so the counter's own semantics are pinned
    // here: the count runs from the accepted request to the completion pulse and is held after it
    // (a live gauge), and it must sit between the ack delay and the whole modelled transfer.
    // The model here is a 256-word stream driven one word per clk_sys after the ack, so the
    // count must cover the stream and not much more: below 256 means the counter started late or
    // stopped early, above 300 means it never stopped.
    if (dbg_hps_cycles < 256) begin
      $display("FAIL the HPS round-trip counter reads %0d cycles, under the 256-word stream",
               dbg_hps_cycles);
      errors = errors + 1;
    end
    if (dbg_hps_cycles > 300) begin
      $display("FAIL the HPS round-trip counter reads %0d cycles, past the whole modelled transfer",
               dbg_hps_cycles);
      errors = errors + 1;
    end

    // An early acknowledge drop must complete with an error rather than
    // exposing a partially initialized sector to ATA.
    pulse_request(1);
    @(negedge clk);
    sd_ack = 1;
    sd_buff_wr = 1;
    sd_buff_addr = 0;
    sd_buff_dout = 16'h1234;
    @(posedge clk);
    @(negedge clk);
    sd_buff_wr = 0;
    sd_ack = 0;
    @(posedge clk);
    #1;
    if (!req_done || !req_error || busy) fail("short block was not rejected");

    pulse_request(4);
    if (!req_done || !req_error || busy || sd_rd) fail("out-of-range request did not fail");

    // A buffer word whose address leaves the sector window must fail the transfer
    // rather than land somewhere in the sector. The errant word does not advance the
    // count, so 255 valid words plus it plus one more still reach 256 and complete.
    pulse_request(1);
    @(negedge clk);
    sd_ack = 1;
    for (word_index = 0; word_index < 255; word_index = word_index + 1) begin
      sd_buff_wr = 1;
      sd_buff_addr = word_index[7:0];
      sd_buff_dout = 16'hA500 | word_index[7:0];
      @(posedge clk);
      @(negedge clk);
    end
    sd_buff_addr = 13'h100;               // bit 8 set: outside the 256-word window
    @(posedge clk);
    @(negedge clk);
    sd_buff_addr = 8'd255;
    @(posedge clk);
    @(negedge clk);
    sd_buff_wr = 0;
    sd_ack = 0;                           // completion happens on the ack fall
    @(posedge clk);
    #1;
    if (!req_done || !req_error || busy)
      fail("out-of-window buffer word did not fail the transfer");

    // Unmounting during a transaction aborts it exactly once.
    pulse_request(1);
    if (!busy) fail("second valid request did not start");
    pulse_mount(0, 1'b1);
    if (mounted || busy || !req_done || !req_error || sd_rd)
      fail("in-flight unmount did not abort");

    // ---- another slot's stream while this request waits for its own acknowledge ----
    // hps_io serves ONE slot at a time and the word bus (sd_buff_wr/addr/dout) is shared by
    // every slot; only `sd_ack`, which is per slot (sys/hps_io.sv:331 "sd_ack <= disk[VD:0]"),
    // says whose words they are. Here the request is presented (sd_rd high) and hps_io is still
    // busy with another slot - the CD-ROM's CD-DA stream in Policenauts' intro - so its
    // 1024-word transfer goes by with THIS engine's sd_ack low. None of it may reach the buffer
    // or complete the request; then the request's own transfer must land word for word.
    pulse_mount(64'd512 * 100, 1'b1);
    pulse_request(32'd3);
    if (!sd_rd || !busy) fail("foreign-stream case: request not presented");
    foreign_we = 0;
    for (word_index = 0; word_index < 1024; word_index = word_index + 1) begin
      @(negedge clk);
      sd_buff_wr = 1;
      sd_buff_addr = word_index[12:0];
      sd_buff_dout = 16'hCD00 | word_index[7:0];
      #1;
      if (buf_we) foreign_we = foreign_we + 1;
      if (req_done) fail("a foreign slot's stream completed this request");
    end
    @(negedge clk);
    sd_buff_wr = 0;
    if (foreign_we != 0) begin
      $display("FAIL %0d words of another slot's stream were written into this drive's buffer",
               foreign_we);
      errors = errors + 1;
    end
    if (!sd_rd) fail("foreign-stream case: sd_rd dropped without this slot's acknowledge");
    @(negedge clk);
    sd_ack = 1;
    for (word_index = 0; word_index < 256; word_index = word_index + 1) begin
      sd_buff_wr = 1;
      sd_buff_addr = word_index;
      sd_buff_dout = 16'h5A00 | word_index[7:0];
      #1;
      if (!buf_we || buf_addr !== word_index[7:0] ||
          buf_data !== (16'h5A00 | word_index[7:0]))
        fail("own transfer after a foreign stream (word mismatch)");
      @(posedge clk);
      @(negedge clk);
    end
    sd_buff_wr = 0;
    sd_ack = 0;
    @(posedge clk);
    #1;
    if (!req_done || req_error || busy) fail("own transfer after a foreign stream did not complete cleanly");

    // ---- block write ----------------------------------------------------
    // The drive asks for a block write, so the adapter must raise sd_wr (never
    // sd_rd) and present the drive's buffer on sd_buff_din, indexed by whatever
    // address the host presents.
    pulse_mount(64'd512 * 100, 1'b0);
    if (!mounted || readonly) fail("writable image did not mount");
    pulse_write_request(32'd7);
    if (!busy || !sd_wr || sd_rd) fail("block write did not raise sd_wr");
    if (sd_lba !== 32'd7) fail("block write LBA");
    sd_buff_addr = 13'd5;
    buf_rd_data  = 16'hBEEF;
    @(negedge clk);
    if (sd_buff_din !== 16'hBEEF) fail("sd_buff_din did not follow the buffer");
    buf_rd_data  = 16'h1234;
    sd_buff_addr = 13'd9;
    @(negedge clk);
    if (sd_buff_din !== 16'h1234) fail("sd_buff_din did not track the address");
    if (buf_rd_addr !== 8'd9) fail("buffer read address not driven from sd_buff_addr");
    sd_ack = 1;
    @(negedge clk);
    if (sd_wr) fail("sd_wr held after acknowledgement");
    sd_ack = 0;
    @(negedge clk);
    if (!req_done || req_error || busy) fail("block write did not complete cleanly");

    // A read-only image is rejected before any host transaction starts.
    pulse_mount(64'd512 * 100, 1'b1);
    if (!readonly) fail("read-only image did not latch");
    pulse_write_request(32'd7);
    if (!req_done || !req_error || busy || sd_wr)
      fail("write to a read-only image was not rejected");

    // Out-of-range write is rejected too.
    pulse_mount(64'd512 * 100, 1'b0);
    pulse_write_request(32'd1000);
    if (!req_done || !req_error || busy || sd_wr)
      fail("out-of-range write was not rejected");
  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_BLOCK_IO: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_BLOCK_IO: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000;
    $fatal(1, "TB_PC9821_BLOCK_IO: TIMEOUT");
  end

endmodule

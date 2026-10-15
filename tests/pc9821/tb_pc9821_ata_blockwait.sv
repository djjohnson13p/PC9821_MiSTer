// tb_pc9821_ata_blockwait — the drive must not lose a block request while the engine is busy.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_BLOCKWAIT:
// The drive must account for a block transfer it has already issued before it issues another: pc9821_block_io accepts a request only while it is idle, so a request pulse that arrives while it is busy is never seen and the drive waits in X_WAIT_BLOCK forever. The sequence tested is one a guest can produce - a soft reset abandoning a transfer mid-flight, then a reissued READ SECTORS - and the assertion is that the adapter sees BOTH requests.
// THE PEER PROPERTY, quoted from pc9821_block_io.sv's own header: it "converts that
// level handshake into one request / one completion pulse", and it acts on req_read /
// req_write only in its B_IDLE state. A pulse that arrives while it is in B_ACK_HIGH or
// B_ACK_LOW is therefore not seen at all - it is not queued, and there is no busy
// output the drive could test before deciding to issue.
//
// WHY THIS IS MACHINE BEHAVIOUR AND NOT AN IMPLEMENTATION DETAIL. It does not matter
// whether the peer is a slow SD card or an image that is being swapped: what the guest
// observes is that it issued READ SECTORS, the drive reported BSY, and the command
// never completed. ATA device semantics allow a command to complete or to abort with
// ERR set, never to hang silently, and BANK3's IDE ROM polls 0x64E for the whole of a
// 0x136 x 0x4E20 timeout on exactly that assumption.
//
// WHAT THE EXISTING BENCHES DO NOT DO. tb_pc9821_ata models the block engine the same
// faithful way - it latches only when its own `block_active` is clear - but it never
// abandons a transfer, so it never presents a second request to a busy engine. Its
// transfers are 256 cycles long, which is long enough for the sequence below to land
// inside; the sequence is simply absent.
//
// THE ASSERTION IS A COUNT, NOT A TIMEOUT, on purpose: `seen` counts the requests the
// adapter actually latched, so a dropped one is reported by name rather than arriving
// as a mysterious DRQ timeout at the end of the run.

module tb_pc9821_ata_blockwait;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg        io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [ 7:0] io_din = 0;
  wire [ 7:0] io_dout;
  wire        block_read, block_write;
  wire [31:0] block_lba;
  reg         block_done = 0, block_error = 0, block_buf_we = 0;
  reg  [ 7:0] block_buf_addr = 0;
  reg  [15:0] block_buf_data = 0;
  reg  [ 7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire        irq;
  wire [ 7:0] dbg_state;
  wire [31:0] dbg_cmd;

  integer errors = 0;
  integer n;

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
      .mounted(1'b1),
      .readonly(1'b0),
      // 1000 / 136 = 7, which is the value the bench waits for below - the same
      // capacity tb_pc9821_ata uses, so the two benches initialise the drive
      // identically.
      .capacity(32'd1000),
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
      .irq(irq),
      .dbg_state(dbg_state),
      .dbg_cmd(dbg_cmd)
  );

  task fail(input [8*160-1:0] message);
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

  // ===================================================================
  // The block adapter, as pc9821_block_io actually behaves.
  //
  // It latches a request ONLY while it is idle - the `!active` guard is that
  // module's B_IDLE - streams 256 words one per cycle, and drives its
  // completion for a single cycle. Crucially `seen` counts what it latched, so
  // a request issued to a busy adapter is visible as a missing count rather
  // than as a silent hang.
  // ===================================================================
  reg     active = 0;
  integer index  = 0;
  integer seen   = 0;

  always @(negedge clk) begin
    block_done   = 0;
    block_buf_we = 0;
    if (!active && block_read) begin
      // B_IDLE: the only state in which the real adapter looks at req_read.
      active = 1;
      index  = 0;
      seen   = seen + 1;
    end else if (active) begin
      block_buf_we   = 1;
      block_buf_addr = index[7:0];
      block_buf_data = {index[7:0], 8'hA5};
      if (index == 255) begin
        active     = 0;
        block_done = 1;
      end else index = index + 1;
    end
  end

  task wait_drq(input [8*80-1:0] what);
    begin
      n = 0;
      while (!dut.status_reg[3] && n < 2000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!dut.status_reg[3]) fail(what);
    end
  endtask

  // One LBA28 READ SECTORS of a single sector, exactly the task-file sequence
  // the existing bench uses.
  task read_sectors_lba(input [7:0] lba_low);
    begin
      write_byte(16'h0644, 8'h01);        // sector count = 1
      write_byte(16'h0646, lba_low);      // sector number
      write_byte(16'h0648, 8'h00);        // cylinder low
      write_byte(16'h064A, 8'h00);        // cylinder high
      write_byte(16'h064C, 8'hE0);        // LBA mode, drive 0
      write_byte(16'h064E, 8'h20);        // READ SECTORS
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // Wait for the capacity-derived cylinder count, so IDENTIFY data is meaningful
    // and the drive is out of its own reset.
    while (dut.current_cylinders !== 16'd7) @(negedge clk);
    repeat (4) @(negedge clk);

    if (!dut.status_reg[6]) fail("drive is not ready at the start");

    // Select the interface's bank. 0x0432 is a WINDOW on the task file, and the
    // machine's built-in IDE answers at bank 0x01 while bank 0x00 -- the value
    // DOS leaves -- floats the whole block at 0x0E (measured; probes/JOY.TXT and
    // probes/WIN.TXT). Without this the commands below reach nothing at all,
    // which is what the first run of this bench did.
    write_byte(16'h0432, 8'h01);
    if (dut.status_reg !== 8'h50) fail("the task file does not answer at bank 0x01 after the bank select");

    // ---------------------------------------------------------------
    // 1. Issue a READ SECTORS. The adapter latches it and starts its 256-word
    //    stream, so it is BUSY for the next ~256 cycles.
    // ---------------------------------------------------------------
    read_sectors_lba(8'h05);
    // The adapter samples the request on its own negedge, which is the same edge
    // write_byte returns on, so give it a full cycle before looking.
    repeat (3) @(negedge clk);
    if (seen != 1) fail("the first READ SECTORS did not reach the block adapter");

    // Only a few cycles in, so the adapter is unambiguously mid-transfer.
    repeat (4) @(negedge clk);
    if (!active) fail("the adapter finished the first transfer before the reset landed, so the sequence did not test anything");

    // ---------------------------------------------------------------
    // 2. SOFT RESET, exactly as BANK3 does it: 0x74C = 0x06 then 0x00.
    //    This is a real guest action - it is how the firmware re-initialises
    //    the device - and the drive abandons the in-flight transfer when it
    //    is written.
    // ---------------------------------------------------------------
    write_byte(16'h074C, 8'h06);
    write_byte(16'h074C, 8'h00);

    // A driver polls for READY before issuing its next command, and the reset
    // must let it get there: the transfer is abandoned but the adapter is still
    // serving it, so the drive owes the adapter a completion before it can
    // accept work again. This poll is the observable form of that obligation -
    // on a correct drive it clears when the drain finishes, and on the defect
    // it clears immediately because the transfer was simply dropped.
    n = 0;
    while (dut.status_reg[7] && n < 4000) begin
      @(negedge clk);
      n = n + 1;
    end
    if (dut.status_reg[7])
      fail("the drive stayed BSY after the soft reset, so the guest can never issue another command");

    // ---------------------------------------------------------------
    // 3. Reissue READ SECTORS. The adapter has now finished the abandoned
    //    transfer, so a correct drive issues this request and the adapter sees
    //    it. A drive that dropped the first transfer reaches its idle state
    //    immediately and issues the request while the adapter is still busy -
    //    and pc9821_block_io, which acts only in its own idle state, never sees
    //    it.
    // ---------------------------------------------------------------
    read_sectors_lba(8'h06);
    repeat (400) @(negedge clk);

    if (seen != 2)
      fail("the drive issued a second block request while the adapter was still busy: the adapter never saw it (it acts only in its idle state), so the command waits forever");

    // A request the adapter did see must have been completed, and completing a
    // one-sector read must leave DRQ set with the sector available.
    wait_drq("the drive never reached DRQ after the reissued command");
    if (dut.xfer_state !== 3'd3)   // X_PIO_READ
      fail("the reissued command did not reach its data phase");

    // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_ATA_BLOCKWAIT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_BLOCKWAIT: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_ATA_BLOCKWAIT: TIMEOUT");
  end

endmodule

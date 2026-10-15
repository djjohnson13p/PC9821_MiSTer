// tb_pc9821_ata_integrity — byte-for-byte integrity of the disk PIO read path.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_INTEGRITY:
// The disk-read data path is byte-exact all the way from the host's 16-bit sector word to the guest's 0x640/0x641 PIO lanes: a known image is read back through the real pc9821_ata + pc9821_block_io pair with a host model that carries the full hps_io multi-block handshake (sd_blk_cnt+1 sectors in one ack session), so a long sequential run, an unaligned run, an odd-length/short run, a far random read and a re-read served out of the read-ahead window are each compared word-for-word against the image, the low lane is shown to be the even byte and the high lane the odd byte with the word pointer advancing only on 0x641, and the host is shown to have fetched every sector the guest consumed (none skipped, none served stale, no re-fetch loop) with the window re-read costing no host handshake at all.

// WHY THIS BENCH EXISTS SEPARATELY FROM tb_pc9821_ata_datapath. That bench uses a
// host model that streams EXACTLY 256 words per request and ignores sd_blk_cnt, so
// pc9821_block_io's multi-block burst never streams its tail: every follow-on request
// is a window MISS and the read-ahead window is never REPLAYED. This bench's host
// model streams sd_blk_cnt+1 sectors per ack session, so the burst tail lands in the
// window and the guests' later sectors are served by the window's own replay engine -
// the one data path a byte error would corrupt silently while every count-based bench
// stays green. (tb_pc9821_block_hostcost's main patterns do byte-check a sequential
// read through the shared engine; this bench isolates the same pair with a much
// smaller, purpose-built stimulus and pins the lane/pointer and fetch-accounting
// properties explicitly.)

module tb_pc9821_ata_integrity;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // ---- guest task-file ports ----
  reg        io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0]  io_din = 0;
  wire [7:0] io_dout;
  wire       irq;
  wire [7:0]  dbg_state;
  wire [31:0] dbg_cmd;

  // ---- hps_io host side ----
  reg         img_mounted = 0, img_readonly = 0;
  reg  [63:0] img_size = 0;
  wire        mounted, readonly;
  wire [31:0] capacity;
  wire [31:0] sd_lba;
  wire [5:0]  sd_blk_cnt;
  wire        sd_rd, sd_wr;
  reg         sd_ack = 0, sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  wire [15:0] sd_buff_din;
  wire [31:0] dbg_hps_cycles;
  wire        busy;

  // ---- ATA <-> block adapter ----
  wire        ata_block_read, ata_block_write;
  wire [31:0] ata_block_lba;
  wire        ata_block_done, ata_block_error;
  wire        ata_buf_we;
  wire [7:0]  ata_buf_addr;
  wire [15:0] ata_buf_data;
  wire [7:0]  ata_buf_rd_addr;
  wire [15:0] ata_buf_rd_data;

  // ==== DUT ====
  // The shipped pair, wired exactly as pc9821_system wires it (pc9821_ata.sv /
  // pc9821_block_io.sv).
  pc9821_ata ata (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .block_read(ata_block_read), .block_write(ata_block_write),
      .block_lba(ata_block_lba),
      .block_done(ata_block_done), .block_error(ata_block_error),
      .block_buf_we(ata_buf_we), .block_buf_addr(ata_buf_addr),
      .block_buf_data(ata_buf_data),
      .block_rd_addr(ata_buf_rd_addr), .block_rd_data(ata_buf_rd_data),
      .irq(irq), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd)
  );

  pc9821_block_io block_io (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
      // The disk is the sole owner of its own instance's window here.
      .win_flush(img_mounted),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .req_read(ata_block_read), .req_write(ata_block_write), .req_lba(ata_block_lba),
      .req_window(1'b1), .req_done(ata_block_done), .req_error(ata_block_error),
      .buf_we(ata_buf_we), .buf_addr(ata_buf_addr), .buf_data(ata_buf_data),
      .buf_rd_addr(ata_buf_rd_addr), .buf_rd_data(ata_buf_rd_data),
      .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr),
      .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .busy(busy),
      .dbg_hps_cycles(dbg_hps_cycles)
  );

  // ==== the known image ====
  // byte `off` of sector `lba`, a function of BOTH so a wrong sector, a wrong
  // byte offset and a swapped lane are each a distinct mismatch. The odd/odd
  // multipliers keep the even and odd lanes of every word different.
  function [7:0] image_byte(input [31:0] lba, input [31:0] off);
    reg [31:0] t;
    begin
      t = (lba * 32'd101) + (off * 32'd37) + ((lba >> 8) * 32'd1293) + 32'h5B;
      image_byte = t[7:0];
    end
  endfunction

  // The host presents a sector as sd_blk_cnt+1 sectors of 256 words; the word the
  // guest reads at 0x641:0x640 is {odd byte, even byte} (hps_io's little-endian
  // 16-bit word).
  function [15:0] image_word(input [31:0] lba, input [7:0] widx);
    begin
      image_word = {image_byte(lba, {24'd0, widx, 1'b1}),
                    image_byte(lba, {24'd0, widx, 1'b0})};
    end
  endfunction

  integer errors = 0, cases = 0;
  integer data_bad = 0;
  integer w, w2;
  reg [7:0] value, lo, hi;

  task automatic fail(input [8*72-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic check(input [8*40-1:0] name, input [31:0] got, input [31:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%08x image=0x%08x", name, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // ==== STIMULUS ====
  task automatic write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task automatic set_lba28(input [31:0] lba, input [7:0] count);
    begin
      write_byte(16'h0644, count);
      write_byte(16'h0646, lba[7:0]);
      write_byte(16'h0648, lba[15:8]);
      write_byte(16'h064A, lba[23:16]);
      write_byte(16'h064C, 8'hE0 | lba[27:24]);
    end
  endtask

  // Poll the ALTERNATE status so the poll does not acknowledge the IRQ.
  task automatic wait_drq;
    integer n;
    begin
      n = 0;
      read_byte(16'h074C, value);
      while (!value[3] && n < 200000) begin
        read_byte(16'h074C, value);
        n = n + 1;
      end
      if (!value[3]) fail("DRQ timeout");
    end
  endtask

  task automatic wait_idle;
    integer n;
    begin
      n = 0;
      while (ata.xfer_state !== 3'd0 && n < 400000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (ata.xfer_state !== 3'd0) fail("transfer did not return to X_IDLE");
    end
  endtask

  task automatic settle;
    begin
      wait_idle;
      read_byte(16'h064E, value);
    end
  endtask

  // Every word of the currently presented sector must equal the image's word for
  // that LBA. A wrong sector, a one-word shift, a byte swap or a bad block all
  // count, and a mismatch names the exact sector, word, byte offset and both
  // values.
  task automatic check_sector(input [31:0] lba);
    integer wi;
    reg [7:0] l, h;
    begin
      for (wi = 0; wi < 256; wi = wi + 1) begin
        read_byte(16'h0640, l);
        read_byte(16'h0641, h);
        if ({h, l} !== image_word(lba, wi[7:0])) begin
          if (data_bad < 8)
            $display("DATA MISMATCH lba=%08x word=%0d even_off=%0d got=%04x image=%04x (lo=%02x hi=%02x)",
                     lba, wi, wi * 2, {h, l}, image_word(lba, wi[7:0]), l, h);
          data_bad = data_bad + 1;
        end
      end
    end
  endtask

  // One multi-sector READ SECTORS command; each sector byte-checked in turn.
  task automatic read_run(input [31:0] base, input integer count);
    integer s;
    begin
      set_lba28(base, count[7:0]);
      write_byte(16'h064E, 8'h20);
      for (s = 0; s < count; s = s + 1) begin
        wait_drq;
        check_sector(base + s);
        read_byte(16'h064E, value);   // one IRQ per sector
      end
      settle;
    end
  endtask

  // ==== the host: the ARM's own hps_io block handshake ====
  // One ack session carries sd_blk_cnt+1 sectors of 256 words each over one
  // sd_buff_addr window, exactly as hps_io streams them (`h0X17` increments
  // sd_buff_addr per 16-bit word). host_blocks/ host_reads are the accounting
  // the integrity assertions read.
  integer host_wait = 0, host_addr = 0;
  integer host_lba = 0, host_blocks = 0;
  integer host_reads = 0, host_blocks_sum = 0;
  integer host_reads0 = 0, host_blocks0 = 0;
  localparam integer SD_LAT = 3;
  localparam [1:0] HS_IDLE = 2'd0, HS_LAT = 2'd1, HS_STREAM = 2'd2, HS_DROP = 2'd3;
  reg [1:0] host_state = HS_IDLE;

  always @(negedge clk) begin
    sd_buff_wr = 0;
    case (host_state)
      HS_IDLE: begin
        sd_ack = 0;
        if (sd_rd) begin
          host_lba      = sd_lba;
          host_blocks   = sd_blk_cnt + 1;
          host_reads    = host_reads + 1;
          host_blocks_sum = host_blocks_sum + host_blocks;
          host_wait     = SD_LAT;
          host_addr     = 0;
          host_state    = HS_LAT;
        end
      end
      HS_LAT: begin
        if (host_wait > 0) host_wait = host_wait - 1;
        else begin
          sd_ack     = 1;
          host_addr  = 0;
          host_state = HS_STREAM;
        end
      end
      HS_STREAM: begin
        sd_buff_wr   = 1;
        sd_buff_addr = host_addr[12:0];
        sd_buff_dout = image_word(host_lba + (host_addr >> 8), host_addr[7:0]);
        if (host_addr == host_blocks * 256 - 1) host_state = HS_DROP;
        else host_addr = host_addr + 1;
      end
      default: begin
        sd_ack     = 0;
        host_state = HS_IDLE;
      end
    endcase
  end

  task automatic mount(input [63:0] bytes, input ro);
    begin
      @(negedge clk);
      img_size = bytes; img_readonly = ro; img_mounted = 1;
      @(posedge clk);
      @(negedge clk);
      img_mounted = 0;
      repeat (4) @(posedge clk);
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    // 200000 sectors so every LBA below is in range.
    mount(64'd200000 * 64'd512, 1'b0);
    while (ata.current_cylinders !== 16'd1470) @(negedge clk);
    write_byte(16'h0432, 8'h00);           // the bank the built-in interface is on

    // ---- (a) the 16-bit lane and the word pointer ----
    // A 16-bit IN walks low (0x640) then high (0x641); the low lane is the sector's
    // EVEN byte, the high lane its ODD byte, 0x640 alone does not advance the word
    // pointer, and 0x641 does. NP2kai ideio_r16 hands back buf[0..511] two bytes at
    // a time (cbus/ideio.c) and QEMU's ide_data_readw advances a whole word on the
    // 16-bit access.
    data_bad = 0;
    set_lba28(32'h00000101, 8'h01);
    write_byte(16'h064E, 8'h20);
    wait_drq;
    read_byte(16'h0640, lo);
    check("lane_0x640_is_even_byte", lo, image_byte(32'h00000101, 32'd0));
    read_byte(16'h0640, hi);               // 0x640 again: must NOT advance
    check("lane_0x640_query_no_advance", hi, lo);
    read_byte(16'h0641, hi);
    check("lane_0x641_is_odd_byte", hi, image_byte(32'h00000101, 32'd1));
    read_byte(16'h0640, lo);               // word 1's even byte
    check("lane_0x641_advanced_to_word1", lo, image_byte(32'h00000101, 32'd2));
    // Drain words 1..255 from the lanes just presented (word 1's high byte next).
    for (w = 0; w < 255; w = w + 1) begin
      read_byte(16'h0641, hi);
      if ({hi, lo} !== image_word(32'h00000101, (w + 1) & 255)) begin
        if (data_bad < 8) $display("DATA MISMATCH lane drain word=%0d", w + 1);
        data_bad = data_bad + 1;
      end
      read_byte(16'h0640, lo);
    end
    check("lane_drain_byte_exact", data_bad, 0);
    settle;

    // The high lane first: a lone 0x641 read returns the odd byte and advances the
    // whole word, so the next 0x640 read is word 1's even byte.
    set_lba28(32'h00000102, 8'h01);
    write_byte(16'h064E, 8'h20);
    wait_drq;
    read_byte(16'h0641, hi);
    check("high_first_returns_odd_byte", hi, image_byte(32'h00000102, 32'd1));
    read_byte(16'h0640, lo);
    check("high_first_advanced_whole_word", lo, image_byte(32'h00000102, 32'd2));
    read_byte(16'h0641, hi);
    read_byte(16'h0640, lo);
    for (w2 = 0; w2 < 254; w2 = w2 + 1) begin
      read_byte(16'h0641, hi);
      read_byte(16'h0640, lo);
    end
    settle;

    // ---- (b) an unaligned long sequential read ----
    // 40 sectors from a base that is NOT a multiple of the burst width, so the
    // window base and every burst boundary are unaligned to the guest's LBA. This
    // run earns multi-block bursts and serves the follow-on sectors from the
    // window's replay engine - the exact path a silent read corruption would live in.
    data_bad = 0;
    host_reads0 = host_reads; host_blocks0 = host_blocks_sum;
    read_run(32'h00000247, 40);
    check("unaligned_run_byte_exact", data_bad, 0);
    // The host fetched every sector the guest consumed - and only a bounded
    // over-fetch: the two run-opening singles plus five 8-block bursts is 42
    // blocks for the 40 sectors (a burst over-fetches past the command's end), so
    // a skipped sector (< 40) or a re-fetch loop (> 48) fails here.
    if ((host_blocks_sum - host_blocks0) < 40)
      fail("the host fetched fewer sectors than the guest consumed: a sector was skipped or served from a stale window");
    if ((host_blocks_sum - host_blocks0) > 48)
      fail("the host fetched far more sectors than the guest consumed: a duplicate/re-fetch loop");
    // ... in far fewer handshakes than sectors: the burst amortisation is real, so
    // the multi-block path (and its window replay) was exercised.
    if ((host_reads - host_reads0) > 20)
      fail("40-sector run cost more than 20 host handshakes: the multi-block burst never engaged");
    $display("NOTE integrity: 40-sector unaligned run host handshakes=%0d",
             host_reads - host_reads0);

    // ---- (c) a re-read served from the window ----
    // A sector inside the just-fetched burst is re-read: it must be answered out of
    // the window with NO host handshake at all, and byte-exact.
    data_bad = 0;
    host_reads0 = host_reads; host_blocks0 = host_blocks_sum;
    // base+39 is the run's LAST sector, so it lies inside the final burst's window
    // (the burst that opens at base+34 and covers base+34..base+41).
    read_run(32'h00000247 + 39, 1);
    check("window_reread_byte_exact", data_bad, 0);
    check("window_reread_no_host_fetch", host_reads - host_reads0, 0);
    check("window_reread_no_sector_fetched", host_blocks_sum - host_blocks0, 0);

    // ---- (d) an odd-length / short run ----
    // 5 sectors, then 2, then 1, then 3: the run lengths that do not fill a burst,
    // so a burst's tail is abandoned mid-stream and the next command starts a new run.
    data_bad = 0;
    read_run(32'h00001001, 5);
    read_run(32'h00001006, 2);
    read_run(32'h00001008, 1);
    read_run(32'h00001009, 3);
    check("odd_length_runs_byte_exact", data_bad, 0);

    // ---- (e) a far random read then a return ----
    // A request far from the window is a single-block fetch (it does not extend the
    // run), and the return to the window's LBA range is served from it. Both must be
    // byte-exact - a wrong-slot replay would serve the far sector's bytes here.
    data_bad = 0;
    read_run(32'h00005000, 1);
    read_run(32'h0000100A, 1);
    check("far_then_return_byte_exact", data_bad, 0);

    // ---- (f) the sector-index vs byte-offset mapping ----
    // Two sectors whose first words are different: reading sector L then sector M
    // must present each sector's own byte n at the same word pointer, so the mapping
    // from the guest's word index to the image's byte offset follows the sector.
    data_bad = 0;
    read_run(32'h00000000, 1);
    read_run(32'h0000FFFF, 1);
    check("sector_index_mapping_byte_exact", data_bad, 0);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("NOTE ata_integrity: %0d cases, %0d data mismatches, %0d host handshakes total",
               cases, data_bad, host_reads);
      $display("TB_PC9821_ATA_INTEGRITY: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_INTEGRITY: FAIL (%0d errors)", errors);
  end

  initial begin
    #120_000_000;
    $fatal(1, "TB_PC9821_ATA_INTEGRITY: TIMEOUT");
  end

endmodule

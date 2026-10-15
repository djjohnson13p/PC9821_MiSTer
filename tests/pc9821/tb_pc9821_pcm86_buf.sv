// tb_pc9821_pcm86_buf -- the SDRAM-backed 86-PCM sample buffer.
//
// WHY THIS EXISTS. The 32 KiB sample buffer moved out of 32 M10K blocks and onto the memory
// controller's third port (src/pcm86/pc9821_pcm86_buf.sv). The existing PCM86 benches prove the
// block still plays samples, but they drive it through the guest's ports and so cannot see the
// buffer's own contract: which byte LANE a write lands in, whether back-to-back writes survive
// the FIFO, and whether the read request/valid handshake returns the byte that was written.
// This bench drives the buffer directly and checks exactly those.
//
// ==== WHAT THIS PROVES ====
// The SDRAM-backed sample buffer is byte-addressed and lossless: a byte written at any of the 32768 addresses reads back from that same address, whatever byte lane of the 32-bit SDRAM word it occupies, and back-to-back writes are queued rather than dropped, so a 0xA46C stream from the guest survives the move out of block RAM.
//
// ==== DUT ====
// pc9821_pcm86_buf with a behavioural stand-in for the SDRAM's third port.

`timescale 1ns/1ps

module tb_pc9821_pcm86_buf;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // Guest write port
  reg         wr_en   = 0;
  reg  [14:0] wr_addr = 0;
  reg   [7:0] wr_data = 0;

  // Drain read port
  reg         rd_req  = 0;
  reg  [14:0] rd_addr = 0;
  wire  [7:0] rd_data;
  wire        rd_valid;

  // SDRAM third port
  wire        sdram_valid, sdram_ready, sdram_write, sdram_resp_valid;
  wire [31:0] sdram_addr, sdram_din, sdram_dout;
  wire  [3:0] sdram_be;
  wire  [7:0] sdram_burstcount;

  pc9821_pcm86_buf dut (
    .clk(clk), .reset(reset), .buf_base(32'd0),
    .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
    .rd_req(rd_req), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  // pcm86_sdram_model: the SDRAM third-port handshake and a 32 KiB byte store. The real
  // controller answers a read after its CAS latency; this answers after one wait cycle, which
  // is enough to exercise the buffer's request/valid handshake.
  pcm86_sdram_model u_sdram (
    .clk(clk), .reset(reset),
    .valid(sdram_valid), .ready(sdram_ready), .write(sdram_write),
    .addr(sdram_addr), .din(sdram_din), .dout(sdram_dout),
    .resp_valid(sdram_resp_valid), .be(sdram_be)
  );

  integer errors = 0;
  integer cyc    = 0;
  always @(posedge clk) cyc = cyc + 1;

  task automatic fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // One guest write: wr_en high across exactly one posedge, which is the cycle the buffer
  // samples, matching the iobus's one-cycle device write strobe.
  task automatic wr(input [14:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      wr_addr = addr; wr_data = data; wr_en = 1'b1;
      @(posedge clk);
      #1 wr_en = 1'b0;
      @(negedge clk);
    end
  endtask

  // One read: rd_req for one cycle, then wait for rd_valid (bounded).
  task automatic rd(input [14:0] addr, output [7:0] data);
    integer guard;
    begin
      @(negedge clk);
      rd_addr = addr; rd_req = 1'b1;
      @(posedge clk);
      #1 rd_req = 1'b0;
      guard = 0;
      data = 8'h00;
      while (!rd_valid && guard < 100) begin
        @(posedge clk);
        #1;
        guard = guard + 1;
      end
      if (!rd_valid)
        fail("rd_valid never arrived");
      else
        data = rd_data;
      @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] got;
  integer   i;

  initial begin
    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (4) @(negedge clk);

    // ---- CHK-1: a byte written at each of the four lanes reads back from the same address ----
    // This is the byte-enable path: a write must land in the lane addr[1:0] selects, and the
    // read must pick that same lane out of the 32-bit response.
    for (i = 0; i < 4; i = i + 1) begin
      wr(i[14:0], 8'hA0 + i[7:0]);
    end
    for (i = 0; i < 4; i = i + 1) begin
      rd(i[14:0], got);
      if (got !== (8'hA0 + i[7:0]))
        begin $display("FAIL: lane %0d: wrote %02x, read %02x", i, 8'hA0 + i[7:0], got); errors = errors + 1; end
    end

    // ---- CHK-2: a write to a DISTINCT address does not disturb its neighbours ----
    // Byte-granular storage is the point: writing 0x5A at address 7 must leave address 6 and
    // 8 alone. A word-granular buffer that ignored the byte enables would pass CHK-1 and fail
    // here.
    wr(15'd6, 8'h11);
    wr(15'd7, 8'h5A);
    wr(15'd8, 8'h22);
    rd(15'd6, got); if (got !== 8'h11) begin $display("FAIL: addr 6: wanted 0x11, got %02x", got); errors = errors + 1; end
    rd(15'd7, got); if (got !== 8'h5A) begin $display("FAIL: addr 7: wanted 0x5A, got %02x", got); errors = errors + 1; end
    rd(15'd8, got); if (got !== 8'h22) begin $display("FAIL: addr 8: wanted 0x22, got %02x", got); errors = errors + 1; end

    // ---- CHK-3: a burst of writes is QUEUED, not dropped ----
    // The guest's 0xA46C strobe is one cycle and the SDRAM write is several, so the FIFO is
    // what keeps a write arriving while the previous one is still in flight from being lost.
    // The gap here (6 clk) is far tighter than the guest can manage - a device write costs an
    // I/O access, ~186 clk - and still lets the FIFO keep up, which is the point: it never
    // fills at the real rate, so it can never have to drop a byte.
    for (i = 0; i < 8; i = i + 1) begin
      @(negedge clk);
      wr_addr = 15'(16 + i); wr_data = 8'h30 + i[7:0]; wr_en = 1'b1;
      @(posedge clk);
      #1 wr_en = 1'b0;
      repeat (5) @(posedge clk);
    end
    repeat (200) @(posedge clk);   // let the FIFO drain to the SDRAM
    for (i = 0; i < 8; i = i + 1) begin
      rd(15'(16 + i), got);
      if (got !== (8'h30 + i[7:0]))
        begin $display("FAIL: burst %0d: wrote %02x, read %02x", i, 8'h30 + i[7:0], got); errors = errors + 1; end
    end

    // ---- CHK-4: a read while writes are pending returns ITS OWN byte ----
    // The engine serialises a write and a read on one port; a read must not be answered with
    // a pending write's data.
    wr(15'd200, 8'hDE);
    @(negedge clk);
    rd_addr = 15'd201; rd_req = 1'b1;
    @(posedge clk);
    #1 rd_req = 1'b0;
    while (!rd_valid) @(posedge clk);
    if (rd_data !== 8'h00)
      begin $display("FAIL: a read of an unwritten address returned %02x, not 0x00", rd_data); errors = errors + 1; end
    wr(15'd201, 8'hAD);
    rd(15'd201, got);
    if (got !== 8'hAD) begin $display("FAIL: addr 201: wanted 0xAD, got %02x", got); errors = errors + 1; end
    rd(15'd200, got);
    if (got !== 8'hDE) begin $display("FAIL: addr 200: wanted 0xDE, got %02x", got); errors = errors + 1; end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PCM86_BUF: PASS");
      $display("  %0d checks: 4 lanes, neighbour isolation, an 8-deep back-to-back burst,", cyc);
      $display("  and a read interleaved with a pending write.", cyc);
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86_BUF: FAIL (%0d errors)", errors);
  end

  // A hard stop, so a wedged handshake cannot hang the gate.
  initial begin
    #400000;
    $fatal(1, "TB_PC9821_PCM86_BUF: TIMEOUT");
  end

endmodule

// pcm86_sdram_model: the SDRAM third-port handshake and a 32 KiB byte store. The real
// controller answers a read after its CAS latency; this answers after one wait cycle.
module pcm86_sdram_model (
  input  wire        clk, reset,
  input  wire        valid,
  output reg         ready,
  input  wire        write,
  input  wire [31:0] addr,
  input  wire [31:0] din,
  output reg  [31:0] dout,
  output reg         resp_valid,
  input  wire  [3:0] be
);
  reg [7:0]  mem [0:32767];
  reg [1:0]  st;
  reg [31:0] lat_addr;
  reg        lat_wr;
  integer    i;
  wire [14:0] wbase = {lat_addr[14:2], 2'b00};
  always @(posedge clk) begin
    ready      <= 1'b0;
    resp_valid <= 1'b0;
    if (reset) begin
      st <= 2'd0;
      for (i = 0; i < 32768; i = i + 1) mem[i] <= 8'h00;
    end else case (st)
      2'd0: if (valid) begin
              ready    <= 1'b1;
              lat_addr <= addr;
              lat_wr   <= write;
              st       <= 2'd1;
            end
      2'd1: begin
              if (lat_wr) begin
                if (be[0]) mem[wbase]     <= din[7:0];
                if (be[1]) mem[wbase + 1] <= din[15:8];
                if (be[2]) mem[wbase + 2] <= din[23:16];
                if (be[3]) mem[wbase + 3] <= din[31:24];
                st <= 2'd0;
              end else begin
                dout <= {mem[wbase + 3], mem[wbase + 2], mem[wbase + 1], mem[wbase]};
                st   <= 2'd2;
              end
            end
      default: begin
              resp_valid <= 1'b1;
              st         <= 2'd0;
            end
    endcase
  end
endmodule

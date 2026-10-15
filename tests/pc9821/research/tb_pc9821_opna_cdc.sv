`timescale 1ns/1ps

// tb_pc9821_opna_cdc - a THROWAWAY measurement bench (tests/pc9821/research/, NOT in the
// gate; see tests/pc9821/research/README.md). It does not assert a contract; it measures how
// often the card's own sample bus is caught mid-flight by the CLK_AUDIO-domain capture in
// z486_mister.sv, which is the one crossing on the audio path that has no synchroniser.
//
// The DUT is the real pc9821_opna on clk_sys (50 MHz, the core's clock). Its snd_l/snd_r are
// the `sample_86_l/r` bus that `pc9821_audio_volume` samples, and that module is clocked by
// CLK_AUDIO (24.576 MHz, sys/pll_audio.v) - an asynchronous clock. In the RTL the two are
// wired straight through; this bench reproduces that and asks how often a CLK_AUDIO edge
// lands inside the bus's own transition.
//
// The bus is passed through a per-bit routing skew (`assign #(i*0.05)`, 0..1.55 ns) because
// that is what makes a mid-flight capture WRONG rather than merely late: without skew every
// bit of the bus settles together and a capture is either wholly old or wholly new. The bench
// prints, for SKEW=0 and for the skewed bus, how many CLK_AUDIO captures saw a bus that was
// not settled, out of the captures taken. The stimulus is the SSG noise generator, which is
// the fastest thing snd_l does (measured 61.4k edges/s of up to 12276 LSB in
// tb_pc9821_opna_path).
//
// Build: the command tests/pc9821/research/README.md shows for the SDRAM probe, with the OPNA
// source list, -DSKEW=0 / -DSKEW=1 and --top-module tb_pc9821_opna_cdc.

`ifndef SKEW
`define SKEW 1
`endif

module tb_pc9821_opna_cdc;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;            // 20 ns = 50 MHz
  reg clk_aud = 0;
  always #20.345 clk_aud = ~clk_aud;        // 40.69 ns = 24.576 MHz

  reg reset = 1;
  reg [15:0] io_addr = 0;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;
  wire       io_rd_wait;
  wire signed [19:0] snd_l, snd_r;
  wire       irq;

  pc9821_opna #(.SYS_CLOCK_HZ(50_000_000)) dut (
    .clk(clk_sys), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .extend(1'b1),
    .joystick(6'b111111),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  // The bus as `pc9821_audio_volume` sees it: 32 bits, taken straight from the clk_sys side.
  wire [33:0] bus = {snd_r, snd_l};

  // Per-bit routing skew. 0 with SKEW=0 (bits settle together).
  wire [31:0] bus_skew;
  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin : bit_skew
`ifdef SKEW0
      assign bus_skew[i] = bus[i];
`else
      assign #(i*0.05) bus_skew[i] = bus[i];
`endif
    end
  endgenerate

  // The CLK_AUDIO capture, exactly the shape of pc9821_audio_volume's `sample` register:
  // that module's channel counter walks 0..NUM_CH-1 (10) and only slot 1 - the -86 card's -
  // is registered into `sample`, so the bus is sampled once per rotation, i.e. at CLK_AUDIO/10
  // = 2.4576 MHz.
  reg [3:0] ch = 4'd0;
  reg [31:0] capture;
  integer    captures = 0;
  integer    midflight = 0;
  always @(posedge clk_aud) begin
    ch <= (ch == 4'd9) ? 4'd0 : ch + 4'd1;
    if (ch == 4'd1) begin
      capture <= bus_skew;
      captures = captures + 1;
      if (bus_skew !== bus) midflight = midflight + 1;   // the bus was not settled
    end
  end

  // ---- the write path, as in tb_pc9821_opna_path ---------------------------
  task automatic busy_wait;
    integer guard;
    begin
      io_addr = 16'h0188; io_wr = 0; io_rd = 0;
      @(negedge clk_sys);
      guard = 0;
      while (io_dout[7] && guard < 200000) begin @(negedge clk_sys); guard = guard + 1; end
    end
  endtask
  task automatic opna_wr(input [15:0] portnum, input [7:0] data);
    begin
      busy_wait;
      @(negedge clk_sys);
      io_addr = portnum; io_din = data; io_wr = 1;
      @(posedge clk_sys);
      @(negedge clk_sys);
      io_wr = 0;
    end
  endtask
  task automatic sound_o(input [7:0] r, input [7:0] d);
    begin opna_wr(16'h0188, r); opna_wr(16'h018A, d); end
  endtask

  integer n;
  initial begin
    repeat (3) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;
    repeat (4000) @(posedge clk_sys);

    // SSG: noise generator at max level on all three channels (fastest snd_l motion).
    sound_o(8'h06, 8'h01);
    sound_o(8'h07, 8'h07);
    sound_o(8'h08, 8'h0F);
    sound_o(8'h09, 8'h0F);
    sound_o(8'h0A, 8'h0F);
    repeat (10000) @(posedge clk_sys);

    // Measure over 20 ms.
    captures = 0;
    midflight = 0;
    for (n = 0; n < 500000; n = n + 1) begin
      @(posedge clk_aud);
    end
    $display("OPNA_CDC: captures=%0d midflight=%0d (%.4f%% -> %.0f/s)  snd_l=%0d",
             captures, midflight, 100.0*midflight/captures, midflight/0.020, snd_l);
    $display("OPNA_CDC: DONE");
    $finish;
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_OPNA_CDC: TIMEOUT");
  end

endmodule

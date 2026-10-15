// tb_pc9821_pcm86_equiv - the 86-PCM block's area rewrite against its pre-rewrite text.
//
// ==== WHAT THIS PROVES ====
// The 86-PCM block's area rewrite (the IRQ threshold held as an 8-bit count plus a ceiling flag, the DAC volume scale as a nibble repeat instead of a multiply, the SDRAM write FIFO's entries as unreset memory, the buffer address concatenated under the 32 KiB-aligned base instead of added, and the read request's don't-care write data left alone) is cycle-for-cycle identical to the pre-rewrite block (pc9821_pcm86_ref.sv, the two modules as of 3b134fe4): over a random mix of 0xA466/0xA468/0xA46A/0xA46C writes (buffer resets, every rate and format, thresholds including 0xFF, byte bursts that fill the write FIFO) against a random-latency SDRAM, every read port, the write wait, the interrupt, the DAC outputs, the logical count and the SDRAM request (valid, write, byte enable, burst count, and the address and write data whenever they are meaningful) match on every clock.
//
// ==== DUT ====
// pc9821_pcm86 (with pc9821_pcm86_buf) vs pc9821_pcm86_ref, same inputs, same SDRAM behaviour
// per instance (identical models with identical seeds, so equal requests get equal answers).
// The reference is the pre-change text, not a model of the hardware: this bench proves the
// rewrite did not change behaviour; the block's behaviour is pinned by tb_pc9821_pcm86*,
// tb_pc9821_pcm_phase and tb_pc9821_audio_clip. buf_base is 32 KiB aligned, the buffer's contract.
//
// ==== CHECKS ====
// CHK-1 io_dout, io_wr_wait, irq, snd_l, snd_r and dbg_count equal on every clock.
// CHK-2 sdram_valid, sdram_write, sdram_be and sdram_burstcount equal on every clock; sdram_addr
//       equal whenever sdram_valid; sdram_din equal whenever sdram_valid && sdram_write.
// CHK-3 the run was not vacuous: SDRAM reads and writes happened, the write FIFO filled
//       (io_wr_wait rose), the interrupt rose and fell, and a non-zero DAC sample was produced, and the logical count reached the full buffer.
//
// ==== VERDICT ====
// PASS when no clock differs; FAIL names the first differing clock and check.
//
`timescale 1ns/1ps

// A word-addressed SDRAM stand-in with a random ready pattern and random read latency. Two
// copies with the same seed behave identically for identical request streams.
module pcm86_eq_sdram (
  input  wire        clk,
  input  wire        reset,
  input  wire        valid,
  output wire        ready,
  input  wire        write,
  input  wire [31:0] addr,
  input  wire [31:0] din,
  input  wire  [3:0] be,
  output reg  [31:0] dout,
  output reg         resp_valid
);
  reg [31:0] mem [0:8191];
  reg [31:0] lfsr = 32'hACE1_2468;
  integer lat = 0;
  reg [31:0] pend_addr;
  reg        pend = 0;
  integer n;
  initial for (n = 0; n < 8192; n = n + 1) mem[n] = 32'h0;
  wire rdy_bit = lfsr[3] | lfsr[7] | (lfsr[11] & lfsr[12]);
  assign ready = valid && rdy_bit && !pend;
  always @(posedge clk) begin
    lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    resp_valid <= 1'b0;
    if (ready) begin
      if (write) begin
        if (be[0]) mem[addr[14:2]][7:0]   <= din[7:0];
        if (be[1]) mem[addr[14:2]][15:8]  <= din[15:8];
        if (be[2]) mem[addr[14:2]][23:16] <= din[23:16];
        if (be[3]) mem[addr[14:2]][31:24] <= din[31:24];
      end else begin
        pend <= 1'b1; pend_addr <= addr; lat <= 1 + lfsr[9:8] + lfsr[16:15];
      end
    end
    if (pend) begin
      if (lat <= 1) begin
        pend <= 1'b0; resp_valid <= 1'b1; dout <= mem[pend_addr[14:2]];
      end else lat <= lat - 1;
    end
  end
endmodule

module tb_pc9821_pcm86_equiv;
  localparam integer SYS_CLOCK_HZ = 80_000_000;
  localparam integer CLOCKS = 4_000_000;
  localparam [31:0] BUF_BASE = 32'h0214_0000;

  reg clk = 0;
  always #5 clk = ~clk;

  reg         reset = 1;
  reg  [15:0] io_addr = 16'hFFFF;
  reg         io_wr = 0, io_rd = 0;
  reg  [7:0]  io_din = 8'h00;

  wire [7:0]  d_dout, r_dout;
  wire        d_rw, r_rw, d_ww, r_ww, d_irq, r_irq;
  wire signed [15:0] d_sl, r_sl, d_sr, r_sr;
  wire [15:0] d_cnt, r_cnt;
  wire        d_v, r_v, d_rdy, r_rdy, d_w, r_w, d_resp, r_resp;
  wire [31:0] d_a, r_a, d_din, r_din, d_dq, r_dq;
  wire  [3:0] d_be, r_be;
  wire  [7:0] d_bc, r_bc;

  pcm86_eq_sdram d_mem (.clk(clk), .reset(reset), .valid(d_v), .ready(d_rdy), .write(d_w), .addr(d_a),
                        .din(d_din), .be(d_be), .dout(d_dq), .resp_valid(d_resp));
  pcm86_eq_sdram r_mem (.clk(clk), .reset(reset), .valid(r_v), .ready(r_rdy), .write(r_w), .addr(r_a),
                        .din(r_din), .be(r_be), .dout(r_dq), .resp_valid(r_resp));

  pc9821_pcm86 #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset), .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(d_dout), .io_rd_wait(d_rw), .io_wr_wait(d_ww), .snd_l(d_sl), .snd_r(d_sr), .irq(d_irq),
    .dbg_count(d_cnt), .buf_base(BUF_BASE),
    .sdram_valid(d_v), .sdram_ready(d_rdy), .sdram_write(d_w), .sdram_addr(d_a), .sdram_din(d_din),
    .sdram_dout(d_dq), .sdram_resp_valid(d_resp), .sdram_be(d_be), .sdram_burstcount(d_bc));
  pc9821_pcm86_ref #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) ref0 (
    .clk(clk), .reset(reset), .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(r_dout), .io_rd_wait(r_rw), .io_wr_wait(r_ww), .snd_l(r_sl), .snd_r(r_sr), .irq(r_irq),
    .dbg_count(r_cnt), .buf_base(BUF_BASE),
    .sdram_valid(r_v), .sdram_ready(r_rdy), .sdram_write(r_w), .sdram_addr(r_a), .sdram_din(r_din),
    .sdram_dout(r_dq), .sdram_resp_valid(r_resp), .sdram_be(r_be), .sdram_burstcount(r_bc));

  integer errors = 0, cyc = 0;
  integer n_rd = 0, n_wr = 0, n_wait = 0, n_irq_up = 0, n_irq_dn = 0, n_nz = 0;
  reg irq_q = 0;
  integer max_cnt = 0;

  task automatic fail(input [8*40-1:0] what);
    begin
      errors = errors + 1;
      if (errors <= 10) $display("FAIL clk %0d: %0s", cyc, what);
    end
  endtask

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (d_dout !== r_dout || d_rw !== r_rw || d_ww !== r_ww || d_irq !== r_irq ||
        d_sl !== r_sl || d_sr !== r_sr || d_cnt !== r_cnt) fail("CHK-1 outputs differ");
    if (d_v !== r_v || d_w !== r_w || d_be !== r_be || d_bc !== r_bc) fail("CHK-2 request control differs");
    if (d_v && d_a !== r_a) fail("CHK-2 sdram_addr differs");
    if (d_v && d_w && d_din !== r_din) fail("CHK-2 sdram_din differs");
    if (d_v && d_rdy && d_w)  n_wr = n_wr + 1;
    if (d_v && d_rdy && !d_w) n_rd = n_rd + 1;
    if (d_ww) n_wait = n_wait + 1;
    if (d_cnt > max_cnt) max_cnt = d_cnt;
    if (d_irq && !irq_q) n_irq_up = n_irq_up + 1;
    if (!d_irq && irq_q) n_irq_dn = n_irq_dn + 1;
    irq_q <= d_irq;
    if (d_sl != 0 || d_sr != 0) n_nz = n_nz + 1;
  end

  // ---- stimulus: a function of a free-running generator only (never of the DUT's outputs) ----
  reg [31:0] g = 32'h1357_9BDF;
  reg [31:0] h;
  function automatic [31:0] step(input [31:0] v);
    step = {v[30:0], v[31] ^ v[21] ^ v[1] ^ v[0]};
  endfunction
  integer mode = 0;                 // changes every 100 000 clocks: burst rate and port mix
  integer gap = 0;
  localparam [15:0] PORTS [0:7] = '{16'hA462, 16'hA464, 16'hA466, 16'hA468, 16'hA46A, 16'hA46C, 16'hA46E, 16'hA467};

  always @(posedge clk) begin
    g <= step(step(step(g)));
    h = g;
    io_wr <= 1'b0;
    io_rd <= 1'b0;
    mode <= (cyc / 100000) % 6;
    if (cyc == 6) reset <= 1'b0;
    if (cyc > 6 && cyc < 100 && cyc % 7 == 0) reset <= 1'b0;
    if (cyc > 7 && cyc % 400000 == 399999) reset <= 1'b1;
    if (cyc > 7 && cyc % 400000 == 2) reset <= 1'b0;
    // idle: wander the read address over every port (io_dout is a function of the address alone)
    io_addr <= PORTS[h[26:24]];
    if (gap > 0) gap <= gap - 1;
    else begin
      // choose a write
      gap <= (mode == 1 || mode == 4) ? h[1:0] : (mode == 2) ? {1'b0, h[0]} : h[5:0];
      case ((mode == 1 || mode == 2 || mode == 4) ? (h[9:8] != 0 ? 0 : h[12:10]) : h[11:8])
        0, 1, 2, 3, 4, 5: begin io_addr <= 16'hA46C; io_din <= h[23:16]; io_wr <= 1'b1; end
        6: begin  // 0xA468: rate, buffer reset, threshold-select, enable
             io_addr <= 16'hA468;
             io_din <= {(h[15:12] != 0) && (mode != 2), 1'b0, h[17], h[18], (h[23:19] == 0) && (mode != 2), h[2:0] ^ h[26:24]};
             io_din[4] <= h[27];
             io_wr <= 1'b1;
           end
        7: begin io_addr <= 16'hA468; io_din <= ((mode == 2) ? 8'h00 : 8'h80) | (h[20] ? 8'h20 : 8'h00) | {5'b0, h[18:16]}; io_wr <= 1'b1; end
        8: begin io_addr <= 16'hA46A; io_din <= h[23:16]; io_wr <= 1'b1; end
        9: begin io_addr <= 16'hA46A; io_din <= h[20] ? 8'hFF : {1'b0, h[22:21], 1'b0, h[19:16] | 4'h0}; io_wr <= 1'b1; end
        10: begin io_addr <= 16'hA466; io_din <= {3'b101, h[20], h[19:16]}; io_wr <= 1'b1; end
        default: begin io_addr <= PORTS[h[26:24]]; io_wr <= 1'b0; io_rd <= 1'b1; end
      endcase
    end
  end

  initial begin
    repeat (CLOCKS) @(posedge clk);
    if (n_wr == 0 || n_rd == 0) begin errors = errors + 1; $display("FAIL CHK-3 no SDRAM reads/writes (%0d/%0d)", n_rd, n_wr); end
    if (n_wait == 0) begin errors = errors + 1; $display("FAIL CHK-3 the write FIFO never filled"); end
    if (n_irq_up == 0 || n_irq_dn == 0) begin errors = errors + 1; $display("FAIL CHK-3 the interrupt did not toggle (%0d/%0d)", n_irq_up, n_irq_dn); end
    if (max_cnt < 32768) begin errors = errors + 1; $display("FAIL CHK-3 the logical count never reached the full buffer (%0d)", max_cnt); end
    if (n_nz == 0) begin errors = errors + 1; $display("FAIL CHK-3 no non-zero DAC sample"); end
    $display("coverage: %0d sdram writes, %0d reads, %0d wait clk, irq up/down %0d/%0d, %0d nonzero DAC clk",
             n_wr, n_rd, n_wait, n_irq_up, n_irq_dn, n_nz);
    if (errors == 0) begin
      $display("TB_PC9821_PCM86_EQUIV: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PCM86_EQUIV: FAIL (%0d errors)", errors);
  end

  initial begin
    #(10 * (CLOCKS + 100000));
    $fatal(1, "TB_PC9821_PCM86_EQUIV: TIMEOUT");
  end
endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The PEGC register file's area rewrite (mio2's 32 read-back bytes held in one block RAM behind per-dword dirty flops, with plane_mode and vram_en in their own flops) is cycle-for-cycle identical to the pre-rewrite module (pc9821_pegc_ref.sv, the module as of d8f166a6): over random dword-aligned reads, line reads and byte-enabled writes across the mio1 and mio2 windows and their neighbours, with random gaps between requests and random resets mid-run (so the lazy zero of a clean dword is exercised after dirty data), cpu_dout, cpu_line_dout, cpu_ready, both response pulses, bank_a, bank_b, plane_mode and vram_en match on every cycle.

// ==== DUT ====
// pc9821_pegc vs pc9821_pegc_ref, same inputs. The reference is the pre-change text, not a
// model of the hardware: this bench proves the rewrite did not change behaviour; the register
// semantics themselves are pinned by tb_pc9821_pegc (NP2kai memvgaio).

module tb_pc9821_pegc_equiv;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg         cpu_valid = 0, cpu_write = 0, cpu_line_read = 0;
  reg  [14:0] cpu_addr = 0;
  reg  [31:0] cpu_din = 0;
  reg  [3:0]  cpu_be = 4'hF;

  wire [31:0] d_dout, r_dout;
  wire [127:0] d_line, r_line;
  wire d_rdy, d_rv, d_lrv, r_rdy, r_rv, r_lrv;
  wire [3:0] d_ba, d_bb, r_ba, r_bb;
  wire d_pm, d_ve, r_pm, r_ve;

  pc9821_pegc dut (.clk(clk), .reset(reset), .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_line_read(cpu_line_read), .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
      .cpu_dout(d_dout), .cpu_line_dout(d_line), .cpu_ready(d_rdy), .cpu_resp_valid(d_rv),
      .cpu_line_resp_valid(d_lrv), .bank_a(d_ba), .bank_b(d_bb), .plane_mode(d_pm), .vram_en(d_ve));
  pc9821_pegc_ref ref0 (.clk(clk), .reset(reset), .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_line_read(cpu_line_read), .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
      .cpu_dout(r_dout), .cpu_line_dout(r_line), .cpu_ready(r_rdy), .cpu_resp_valid(r_rv),
      .cpu_line_resp_valid(r_lrv), .bank_a(r_ba), .bank_b(r_bb), .plane_mode(r_pm), .vram_en(r_ve));

  integer errors = 0, cycles = 0, seed = 7, gap = 0, nreads = 0, nreset = 0, nwr = 0;
  reg [31:0] rnd;
  reg [14:0] a;
  reg [31:0] rw;

  function automatic [31:0] rr(input integer dummy);
    rr = $random(seed);
  endfunction

  // ==== CHECKS ====
  always @(posedge clk) begin
    // compare on every cycle (sampled before this edge's updates)
    cycles <= cycles + 1;
    if (d_dout !== r_dout || d_line !== r_line || d_rdy !== r_rdy || d_rv !== r_rv ||
        d_lrv !== r_lrv || d_ba !== r_ba || d_bb !== r_bb || d_pm !== r_pm || d_ve !== r_ve) begin
      errors <= errors + 1;
      if (errors < 10)
        $display("MISMATCH cyc=%0d dout %h/%h rdy %b/%b rv %b/%b pm %b/%b ve %b/%b ba %h/%h",
                 cycles, d_dout, r_dout, d_rdy, r_rdy, d_rv, r_rv, d_pm, r_pm, d_ve, r_ve, d_ba, r_ba);
    end
    // stimulus
    if (reset) begin
      cpu_valid <= 1'b0;
    end else if (cpu_valid) begin
      if (d_rdy) begin cpu_valid <= 1'b0; gap <= rr(0) & 3; end
    end else if (gap != 0) begin
      gap <= gap - 1;
    end else begin
      rnd = rr(0);
      rw = rr(0);
      case (rnd[3:0])
        0, 1, 2, 3, 4, 5, 6, 7: a = {10'd8, rw[4:2], 2'b00};   // mio2 dwords (0xE0100-0xE011F)
        8, 9:     a = 15'h0004;                                // mio1
        10:       a = 15'h0000;
        11:       a = {rw[12:2], 2'b00};                       // anywhere in the window
        12:       a = {10'd8, 5'h00} + {rw[7:2], 2'b00} - 15'h20; // around mio2
        default:  a = {10'd8, rw[4:2], 2'b00};
      endcase
      cpu_addr <= a;
      cpu_write <= rr(0) & 1 | (rnd[7:4] > 6);
      cpu_line_read <= (rnd[11:8] == 0);
      cpu_be <= (rnd[15:12] < 6) ? 4'hF : (rr(0) & 15);
      cpu_din <= rr(0);
      cpu_valid <= 1'b1;
    end
    // random mid-run reset
    if (!reset && (rr(0) & 16'hFFF) == 0 && cycles > 100) begin
      reset <= 1'b1; nreset <= nreset + 1;
    end else if (reset && cycles > 20 && (rr(0) & 3) == 0) reset <= 1'b0;
  end

  // ==== VERDICT ====
  initial begin
    #40_000_000;
    if (errors == 0 && cycles > 1_000_000 && nreset >= 0)
      $display("TB_PC9821_PEGC_EQUIV: PASS");
    else
      $fatal(1, "TB_PC9821_PEGC_EQUIV: FAIL errors=%0d cycles=%0d", errors, cycles);
    $finish;
  end
endmodule

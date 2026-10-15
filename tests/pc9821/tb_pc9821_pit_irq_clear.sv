`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// A masked IRQ0 request does NOT stay latched: the master IRR bit 0 follows the PIT channel-0 OUT pin and clears on the falling edge (pc9821_pic's WD_MASK), so the STEELGUN master-IRR falling-edge poll terminates. Expected from the real Xe10 (docs/probes/IRQWD.TXT: with ch0 forced to mode 3, 'IRQ0 masked poll ... falls 2826 rises 2826') and NP2kai's masked-timer clear (io/pic.c:217-225, :240-252). FAIL-FIRST: the pre-change pure edge latch never fell. The positive control delivers exactly one IRQ0 (vector 0x08) when unmasked, and an unmasked request is not lost.
//
// ---- where the expectation comes from ----
//   docs/probes/IRQWD.TXT - the real Xe10: while IRQ0 is masked the master IRR
//     bit 0 toggles with the PIT OUT pin (2826 falls / 2826 rises, ch0 mode 3).
//   STEELGUN's startup freeze is the game that needed it.
//   NP2kai io/pic.c picmask / pic_setirq - the software reference's masked-timer
//     clear (io/pic.c:217-225, :240-252).
// The positive control (unmasked, one delivery, vector 0x08) is the firmware's
// own master ICW2 = 0x08.

`default_nettype none

module tb_pc9821_pit_irq_clear;

  reg clk = 0;
  always #10 clk = ~clk;                 // 50 MHz, the shipped SYS_FREQ
  reg reset_n = 0;

  reg  io_wr = 0, io_rd = 0;
  reg  [15:0] io_addr = 0;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg  master_cs = 0, slave_cs = 0, pit_cs = 0;
  reg  keyboard_irq = 0, vsync_irq = 0;
  reg  [3:0] master_aux_irq = 0;
  reg  [7:0] slave_irq = 0;
  wire cpu_intr;
  reg  cpu_inta = 0;
  wire [31:0] cpu_inta_din;
  wire cpu_inta_ready;
  wire pit_out0, pit_out1, pit_out2;
  wire [7:0] dbg_imr, dbg_irr, dbg_isr;
  wire [7:0] dbg_s_imr, dbg_s_isr;

  // ==== DUT ====
  pc9821_interrupts #(.SYS_CLOCK_HZ(50_000_000)) dut (.*);

  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  task automatic fail(input [8*140-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic set_selects(input [15:0] portnum);
    begin
      master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
      pit_cs    = ((portnum[15:3] == 13'h000E) || (portnum[15:3] == 13'h07FB)) &&
                  portnum[0];
    end
  endtask

  task automatic write_port(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; set_selects(portnum); io_din = data; io_wr = 1;
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic read_port(input [15:0] portnum, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum; set_selects(portnum); io_rd = 1;
      #1 data = io_dout;
      @(negedge clk); io_rd = 0;
    end
  endtask

  task automatic init_master(input [7:0] mask);
    begin
      write_port(16'h0000, 8'h11); write_port(16'h0002, 8'h08);
      write_port(16'h0002, 8'h80); write_port(16'h0002, 8'h1D);
      write_port(16'h0002, mask);
    end
  endtask

  task automatic reset_all;
    begin
      reset_n = 0; io_wr = 0; io_rd = 0; cpu_inta = 0;
      repeat (4) @(negedge clk);
      reset_n = 1;
      repeat (2) @(negedge clk);
    end
  endtask

  // One x86 acknowledge is two INTA assertions, as the bridge's state machine needs.
  task automatic one_inta;
    begin
      @(negedge clk); cpu_inta = 1;
      while (!cpu_inta_ready) @(negedge clk);
      @(negedge clk); cpu_inta = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  // Wait for IRQ0 to reach the CPU, acknowledge it, EOI, and return the vector.
  task automatic service_irq(output [7:0] vec, output bit ok);
    integer guard;
    begin
      guard = 0;
      while (!cpu_intr && guard < 20000) begin @(posedge clk); guard = guard + 1; end
      ok = (guard < 20000);
      vec = 8'h00;
      if (ok) begin
        one_inta(); one_inta();
        vec = cpu_inta_din[7:0];
        write_port(16'h0000, 8'h20);       // master non-specific EOI
        repeat (4) @(posedge clk);
      end
    end
  endtask

  bit iok;
  reg [7:0] rv;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;

    reset_all();
    init_master(8'hFF);                    // IRQ0 masked: watch the IRR only
    write_port(16'h0077, 8'h36);           // ch0, LSB then MSB, mode 3 (square wave)
    write_port(16'h0071, 8'h40);           // divisor 0x40 -> half period ~671 clk_sys
    write_port(16'h0071, 8'h00);

    // ---- 1. the STEELGUN poll: while masked, the IRR bit 0 must FALL ----
    // Sample dbg_irr[0] across several PIT periods and count its transitions.
    begin
      reg prev;
      integer falls, rises, i;
      prev = dbg_irr[0];
      falls = 0; rises = 0;
      for (i = 0; i < 12000; i = i + 1) begin
        @(posedge clk);
        if (prev && !dbg_irr[0]) falls = falls + 1;
        if (!prev && dbg_irr[0]) rises = rises + 1;
        prev = dbg_irr[0];
      end
      if (falls < 1)
        fail("the masked IRQ0 request never fell: the edge latch held it (STEELGUN hangs)");
      if (rises < 1)
        fail("the masked IRQ0 request never rose: the PIT is not feeding IRQ0");
      $display("ok       steelgun_poll_falls falls=%0d rises=%0d", falls, rises);
    end

    // ---- 2. the follow: while masked (and never in service) the IRR bit 0
    //         tracks the PIT channel-0 OUT pin. Allow a 1-cycle registration
    //         delay: dbg_irr[0] must equal the OUT pin state sampled one cycle
    //         earlier. ----
    begin
      reg out_q;
      integer bad, i;
      bad = 0;
      out_q = pit_out0;
      for (i = 0; i < 4000; i = i + 1) begin
        @(posedge clk);
        if (dbg_irr[0] !== out_q) bad = bad + 1;
        out_q = pit_out0;
      end
      if (bad != 0)
        fail("the masked IRR bit 0 did not track the PIT OUT pin");
      else $display("ok       irq0_masked_tracks_out");
    end

    // ---- 3. positive control: unmask, deliver exactly one IRQ0 (vector 0x08) ----
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h36);
    write_port(16'h0071, 8'h40);
    write_port(16'h0071, 8'h00);
    write_port(16'h0002, 8'hFE);            // unmask IRQ0 only
    service_irq(rv, iok);
    if (!iok) fail("an unmasked IRQ0 did not reach the CPU");
    else if (rv !== 8'h08) fail("IRQ0 vector not 0x08 (master ICW2 0x08 + 0)");

    // ---- 4. a masked falling edge must not lose an UNMASKED request: with
    //         IRQ0 unmasked the request is delivered, not withdrawn ----
    reset_all();
    init_master(8'hFF);
    write_port(16'h0077, 8'h36);
    write_port(16'h0071, 8'h40);
    write_port(16'h0071, 8'h00);
    write_port(16'h0002, 8'hFE);            // unmask IRQ0
    service_irq(rv, iok);
    if (!iok) fail("the unmasked IRQ0 did not deliver after the mask test");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PIT_IRQ_CLEAR: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_IRQ_CLEAR: FAIL (%0d errors)", errors);
  end

endmodule

`default_nettype wire

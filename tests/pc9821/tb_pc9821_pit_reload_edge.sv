// tb_pc9821_pit_reload_edge - a count write to a running mode-3 channel makes no OUT edge.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PIT_RELOAD_EDGE:
// A count write to a RUNNING mode-2/3 PIT channel never drives OUT, so it can never make an IRQ0 edge: master.lib's BGM timer (bgm_timer.asm _BGM_TIMER_INIT: control 0x36 to 0x77, count to 0x71; bgm_timerhook.asm _BGM_TIMERHOOK: the INT 08h handler rewrites the ch0 count on EVERY tick) is replayed with handler latencies that land in both halves of the square wave, and every OUT0 rising edge must be a counted-down half-period end, never the cycle after a count write. NP2kai's ch0 write (io/pit.c pit_o71) restarts the count as an absolute event and raises no interrupt; the 8254 loads a mode-3 count at the next half-cycle and leaves OUT alone. Only the CONTROL WORD drives OUT high in modes 2/3 (8254 datasheet), and that edge is kept and asserted here too.
//
// ---- where the expectation comes from ----
//   NP2kai io/pit.c pit_o71: `pit_setcount(...)` then `pic.pi[0].irr &= ~1;
//     setsystimerevent(pitch->value, NEVENT_ABSOLUTE)` - the write restarts the timer
//     and WITHDRAWS a pending IRQ0; it never requests one.
//   8254 datasheet, mode 3: "if a new count is written during counting it is loaded at
//     the end of the current half-cycle"; "OUT goes high when the control word is written".
//   rec98 libs/master.lib bgm_timer.asm / bgm_timerhook.asm: the guest pattern.
// Before the fix pc9821_pit drove OUT high on every mode-2/3 count write, so a handler that
// ran late (inside the low half, e.g. behind a CLI'd BIOS disk transfer) produced a phantom
// rising edge - an IRQ0 the real part never raises - and the bench FAILs on that edge.

module tb_pc9821_pit_reload_edge;

  reg clk = 0;
  always #10 clk = ~clk;   // 50 MHz, the shipped SYS_FREQ
  reg rst_n = 0;
  reg cs = 0, wr = 0, rd = 0;
  reg  [1:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire out0, out1, out2;

  // ==== DUT ====
  pc9821_pit #(.SYS_CLOCK_HZ(50_000_000)) dut (
      .clk(clk), .rst_n(rst_n), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .out0(out0), .out1(out1), .out2(out2)
  );

  // Count 64 -> a 32-tick half-period, ~651 clk_sys at 50 MHz / 2.4576 MHz.
  localparam [15:0] DIVISOR   = 16'd64;
  localparam integer HALF_CLK = 651;

  integer errors = 0;
  integer rises = 0;
  integer phantoms = 0;
  integer reloads = 0;
  integer late_reloads = 0;
  integer since_write = 1000;   // clk_sys since the last count-completing write
  reg     out0_q = 0;
  integer k;
  integer lat;

  // ==== STIMULUS ====
  task write_pit(input [1:0] port, input [7:0] value);
    begin
      @(negedge clk);
      addr = port; din = value; cs = 1; wr = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0; wr = 0;
    end
  endtask

  // Edge monitor: a rising edge within 3 clk_sys of a count-completing write is the
  // write's doing, not a counted-down half-period end (which is >= one PIT tick,
  // ~20 clk_sys, away from any write that restarted it).
  always @(posedge clk) begin
    out0_q <= out0;
    if (since_write < 1000) since_write <= since_write + 1;
    if (rst_n && out0 && !out0_q) begin
      rises = rises + 1;
      if (since_write <= 3) phantoms = phantoms + 1;
    end
  end

  task reload_count;   // the ISR's `out 71h,al / mov al,ah / out 71h,al`
    begin
      write_pit(2'd0, DIVISOR[7:0]);
      write_pit(2'd0, DIVISOR[15:8]);
      since_write = 0;
      reloads = reloads + 1;
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // _BGM_TIMER_INIT: control word 0x36 (ch0, LSB+MSB, mode 3, binary), then the count.
    write_pit(2'd3, 8'h36);
    reload_count();

    // ---- 1. the direct case: a reload in the LOW half leaves OUT low ----
    @(negedge out0);
    repeat (HALF_CLK / 3) @(posedge clk);
    if (out0 !== 1'b0) begin
      $display("FAIL setup: OUT0 not low one third into the low half");
      errors = errors + 1;
    end
    reload_count();
    // Both references keep OUT low for at least the rest of a half-period's worth of
    // ticks (8254: the current half finishes; NP2kai: the restarted count runs out).
    for (k = 0; k < HALF_CLK / 2; k = k + 1) begin
      @(posedge clk);
      if (out0 !== 1'b0) begin
        $display("FAIL case 1: OUT0 rose %0d clk_sys after a count write in the low half (a phantom IRQ0 edge)", k);
        errors = errors + 1;
        k = HALF_CLK;
      end
    end

    // ---- 2. the ISR replay: reload after every rising edge, latency in either half ----
    phantoms = 0;
    for (k = 0; k < 24; k = k + 1) begin
      @(posedge out0);
      // Latencies from 5% to 170% of a half-period: the long ones reload in the LOW half.
      lat = (HALF_CLK * ((k * 37) % 34 + 1)) / 20;
      if (lat > HALF_CLK) late_reloads = late_reloads + 1;
      repeat (lat) @(posedge clk);
      reload_count();
    end
    repeat (4 * HALF_CLK) @(posedge clk);
    if (late_reloads == 0) begin
      $display("FAIL bench: no reload landed in the low half, the replay proves nothing");
      errors = errors + 1;
    end
    if (phantoms != 0) begin
      $display("FAIL case 2: %0d OUT0 rising edges followed a count write within 3 clk_sys (%0d reloads, %0d in the low half)",
               phantoms, reloads, late_reloads);
      errors = errors + 1;
    end

    // ---- 3. the control word DOES drive OUT high in mode 3 (authentic 8254) ----
    @(negedge out0);
    repeat (HALF_CLK / 3) @(posedge clk);
    write_pit(2'd3, 8'h36);
    @(posedge clk);
    if (out0 !== 1'b1) begin
      $display("FAIL case 3: a mode-3 control word left OUT0 low (the 8254 sets OUT high on the control word)");
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("reloads=%0d late=%0d rises=%0d phantoms=%0d", reloads, late_reloads, rises, phantoms);
      $display("TB_PC9821_PIT_RELOAD_EDGE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_RELOAD_EDGE: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_PIT_RELOAD_EDGE: TIMEOUT");
  end

endmodule

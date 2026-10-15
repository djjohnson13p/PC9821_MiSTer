// tb_pc9821_mouse_sign - a PS/2 delta is 9-bit: the sign lives in packet byte 0.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MOUSE_SIGN: the bus mouse decodes hps_io's PS/2 packet deltas as the 9-bit two's-complement values Main_MiSTer sends - the X sign in byte 0 bit 4 and the Y sign in bit 5, with the delta byte the low 8 bits, so magnitudes 128-255 arrive in both directions - and a fast move of +200 / -200 counts as +200 / -200 (latched and clamped to 0x7F / 0x80), never as the -56 / +56 an 8-bit sign extension of the delta byte gives, on both axes including Y's PS/2-up to PC-98-down negation.

// ---- where the expectation comes from ----
//   Main_MiSTer user_io.cpp user_io_mouse(): "// PS2 format: // YOvfl, XOvfl, dy8, dx8, 1,
//     mbtn, rbtn, lbtn", `ps2_mouse[0] |= (x < 0) ? 0x10 : 0x00;`, x clamped to +-255 with
//     `ps2_mouse[1] = (char)x;`, and `y = -y;` before the same for Y with 0x20. sys/hps_io.sv
//     forwards the three bytes as ps2_mouse[7:0]/[15:8]/[23:16].
//   NP2kai io/mouseif.c setportc: the latch takes the counter clamped to [-128, 127].
// FAIL-FIRST: before the fix x_ext/y_ext sign-extended bit 7 of the delta byte, so +200 (0xC8,
// sign 0) counted -56 and latched 0xC8 instead of 0x7F, and -200 (0x38, sign 1) counted +56.

`default_nettype none

module tb_pc9821_mouse_sign;

  reg clk = 0;
  always #10 clk = ~clk;
  reg reset = 1;
  reg cs = 1, wr = 0, rd = 0;
  reg  [2:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  reg  [24:0] ps2_mouse = 25'd0;
  wire irq;

  // ==== DUT ====
  pc9821_mouse #(.SYS_CLOCK_HZ(32'd50_000_000)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd), .din(din),
      .dout(dout), .dip_strap(3'd0), .ps2_mouse(ps2_mouse), .irq(irq)
  );

  integer errors = 0;
  reg [7:0] lo, hi;

  // ==== STIMULUS ====
  task automatic wport(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk); addr = a; din = d; wr = 1;
      @(negedge clk); wr = 0;
    end
  endtask

  task automatic rport(input [2:0] a, output [7:0] d);
    begin
      @(negedge clk); addr = a; rd = 1; #1 d = dout;
      @(negedge clk); rd = 0;
    end
  endtask

  // A packet exactly as Main_MiSTer builds it from signed deltas (|d| <= 255).
  task automatic packet(input integer x, input integer y_up);
    reg [7:0] b0;
    begin
      b0 = 8'h08 | ((x < 0) ? 8'h10 : 8'h00) | ((y_up < 0) ? 8'h20 : 8'h00);
      @(negedge clk);
      ps2_mouse = {~ps2_mouse[24], y_up[7:0], x[7:0], b0};
      repeat (3) @(negedge clk);
    end
  endtask

  // Latch (portc bit 7 0 -> 1) and read the latched axis byte through the nibble selects.
  task automatic read_latch(input axis_y, output [7:0] v);
    begin
      wport(3'd2, 8'h00);
      wport(3'd2, 8'h80 | (axis_y ? 8'h40 : 8'h00));
      rport(3'd0, lo);
      wport(3'd2, 8'hA0 | (axis_y ? 8'h40 : 8'h00));
      rport(3'd0, hi);
      v = {hi[3:0], lo[3:0]};
    end
  endtask

  // ==== CHECKS ====
  task automatic one(input [8*24-1:0] tag, input integer x, input integer y_up,
                     input [7:0] want_x, input [7:0] want_y);
    reg [7:0] vx, vy;
    begin
      // The packet toggle restarts at 0 with the DUT's own tracker, so no stale packet replays.
      @(negedge clk); reset = 1; ps2_mouse = 25'd0;
      repeat (3) @(negedge clk); reset = 0;
      repeat (3) @(negedge clk);
      packet(x, y_up);
      read_latch(1'b0, vx);
      // the latch edge took both axes; re-read Y from the same latch
      wport(3'd2, 8'hC0); rport(3'd0, lo);
      wport(3'd2, 8'hE0); rport(3'd0, hi);
      vy = {hi[3:0], lo[3:0]};
      if (vx !== want_x || vy !== want_y) begin
        $display("MISMATCH %0s: latch x=%02x y=%02x, want x=%02x y=%02x", tag, vx, vy, want_x, want_y);
        errors = errors + 1;
      end else $display("ok       %0s: x=%02x y=%02x", tag, vx, vy);
    end
  endtask

  initial begin
    // PC-98 Y is down-positive: PS/2 up +200 is -200 there (clamps to 0x80).
    one("x+200 yup+200", 200, 200, 8'h7F, 8'h80);
    one("x-200 yup-200", -200, -200, 8'h80, 8'h7F);
    one("x+255 yup-255", 255, -255, 8'h7F, 8'h7F);
    one("x-100 yup+100", -100, 100, 8'h9C, 8'h9C);   // in-range control
    one("x+5 yup-5", 5, -5, 8'h05, 8'h05);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_MOUSE_SIGN: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_MOUSE_SIGN: FAIL (%0d errors)", errors);
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_MOUSE_SIGN: TIMEOUT");
  end

endmodule

`default_nettype wire

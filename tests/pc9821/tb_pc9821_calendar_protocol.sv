`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The uPD4990A/4993A serial protocol against NP2kai io/upd4990.c and the machine's own captured stream (docs/probes/TRS.TXT, /TIMEREF and /TIMESET): the 48 payload bits come out first and are followed by the 0x01 the reference loads into reg[1] (the machine's 52-bit captures end 1,0,0,0), a register-hold (opcode 0) DISARMS the output walk, and the serial opcode is decoded as the full four bits (NP2kai io/upd4990.c:26), so 0xA the 30-second interrupt command does not alias TIMESET. All three pass on the fixed RTL.
//
// The three expectations and their reference, in one place:
//  * NP2kai io/upd4990.c:43-49 (time read) ZeroMemory's reg, fills reg[2..7] with
//    calendar_get and then sets reg[1] = 0x01; the shift walks reg[7] down to reg[0],
//    so the 49th bit out is reg[1] bit 0 = 1. docs/probes/TRS.TXT TIMEREF captured
//    52 bits ending "...1000" with the payload at bit 0, which is the same nibble.
//  * NP2kai io/upd4990.c:29-30 (opcode 0, register hold) sets regsft = 0, so the
//    position counter stops and the output pin holds; the RTL's hold arm leaves
//    `shifting` set and keeps walking the register.
//  * NP2kai io/upd4990.c:26 decodes the SERIAL opcode as `serial & 0x0f`; cases 4-0x0f
//    are the interrupt/test commands and have no compiled body, so cmd 0xA does
//    nothing. The RTL masks the opcode to 3 bits, so 0xA becomes TIMESET and loads
//    the counters from the input stream.
module tb_pc9821_calendar_protocol;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // The framework RTC: 2026-09-12 12:34:56, weekday 5.
  reg  [55:0] rtc_bcd = 56'h05_26_09_12_12_34_56;
  reg         rtc_load = 0;

  reg         cmd_we = 0, mode_we = 0, tick_we = 0, tick_rd = 0;
  reg  [7:0]  cmd_din = 0, mode_din = 0, tick_din = 0;
  wire [7:0]  mode_dout, tick_dout;
  wire        cdat, irq;
  integer     errors = 0;

  // ==== DUT ====
  pc9821_calendar dut (
      .clk(clk), .rst_n(rst_n),
      .rtc_bcd(rtc_bcd), .rtc_load(rtc_load),
      .cmd_we(cmd_we), .cmd_din(cmd_din),
      .mode_we(mode_we), .mode_din(mode_din), .mode_dout(mode_dout),
      .tick_we(tick_we), .tick_din(tick_din), .tick_dout(tick_dout),
      .tick_rd(tick_rd),
      .cdat(cdat), .irq(irq));

  // ==== STIMULUS ====
  task fail(input [8*128-1:0] message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  // Set up on the falling edge so the DUT samples at the next rising edge.
  task cal_write(input [7:0] d);
    begin
      @(negedge clk);
      cmd_din = d; cmd_we = 1;
      @(negedge clk);
      cmd_we = 0;
    end
  endtask

  task cal_mode(input [7:0] d);
    begin
      @(negedge clk);
      mode_din = d; mode_we = 1;
      @(negedge clk);
      mode_we = 0;
    end
  endtask

  // The firmware's serial command form (BANK7@0x5DA2): field held at 7, the four
  // opcode bits LSB-first on DATA with a CLK each, then an STB pulse.
  task send_serial(input [3:0] opcode);
    integer i;
    reg [3:0] ah;
    reg [7:0] al;
    begin
      ah = opcode;
      for (i = 0; i < 4; i = i + 1) begin
        al = ah[0] ? 8'h27 : 8'h07;
        cal_write(al);
        cal_write(al | 8'h10);
        ah = ah >> 1;
      end
      al = al & 8'hEF;
      cal_write(al);
      cal_write(al | 8'h08);
      cal_write(al & 8'hF7);
    end
  endtask

  task clk_bit;
    begin
      cal_write(8'h17);          // CLK rising, field 7
      cal_write(8'h07);          // CLK falling
    end
  endtask

  // One payload bit, in the machine's own encoding (BANK7@0x5D76-0x5D8E): the
  // field held at 7 with the bit on DATA (bit 5), then a CLK rise and fall. The
  // field is NOT what selects data vs command - the machine sends both on 7 -
  // so the accumulator takes a bit whatever it holds.
  task send_data_bit(input b);
    begin
      cal_write(b ? 8'h27 : 8'h07);
      cal_write(b ? 8'h37 : 8'h17);
      cal_write(b ? 8'h27 : 8'h07);
    end
  endtask

  task send_time(input [7:0] sec, input [7:0] min, input [7:0] hour,
                 input [7:0] day, input [7:0] mw,  input [7:0] year);
    integer i, k;
    reg [7:0] f [0:5];
    begin
      f[0] = sec; f[1] = min; f[2] = hour; f[3] = day; f[4] = mw; f[5] = year;
      for (i = 0; i < 6; i = i + 1)
        for (k = 0; k < 8; k = k + 1)
          send_data_bit(f[i][k]);
    end
  endtask

  // The ITF's reader: TIMEREAD latches, SHIFT arms, then 8 samples per byte with the
  // first bit out landing in bit 0.
  task read_clock(output [7:0] sec, output [7:0] min, output [7:0] hour,
                  output [7:0] day, output [7:0] mw,  output [7:0] year);
    integer i, k;
    reg [7:0] b;
    reg [7:0] got [0:5];
    begin
      send_serial(4'd3);
      send_serial(4'd1);
      for (i = 0; i < 6; i = i + 1) begin
        b = 8'h00;
        for (k = 0; k < 8; k = k + 1) begin
          b[k] = cdat;             // sample before the clock advances
          clk_bit;
        end
        got[i] = b;
      end
      sec = got[0]; min = got[1]; hour = got[2];
      day = got[3]; mw  = got[4]; year = got[5];
    end
  endtask

  // The raw emission order: bits[i] is the i-th bit out of 0x33 bit 0, so
  // bits[47:0] is the payload (bit 0 of each byte first) and bits[51:48] are the
  // four bits after it.
  task read_stream(output [51:0] bits);
    integer i;
    reg [51:0] acc;
    begin
      send_serial(4'd3);
      send_serial(4'd1);
      acc = 52'h0;
      for (i = 0; i < 52; i = i + 1) begin
        acc[i] = cdat;
        clk_bit;
      end
      bits = acc;
    end
  endtask

  reg [7:0] s, m, h, d, mw, y;
  reg [51:0] stream;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(negedge clk); rtc_load = 1;
    @(negedge clk); rtc_load = 0;
    repeat (4) @(posedge clk);

    // The firmware selects the uPD4993A format before it reads; measured 0xEF.
    cal_mode(8'hEF);

    // ---- A. the emitted stream: 48 payload bits, then the reference's 0x01 nibble
    // TRS.TXT TIMEREF/ 52-bit capture: payload at bit 0 (sec=05 min=01 hour=00 day=00
    // mon/wday=00 year=00) then 1000. NP2kai produces the same trailing nibble.
    read_stream(stream);
    $display("stream=%013x", stream);
    if (stream[47:0] !== 48'h2695_1212_3456)
      fail("the 48 payload bits (sec/min/hour/day/mon|wday/year) are not the loaded time");
    if (stream[51:48] !== 4'b0001)
      fail("bits 48-51 are not the reference's 1,0,0,0 (NP2kai reg[1]=0x01; TRS.TXT 1000)");

    // ---- B. register hold (opcode 0) must disarm the output walk
    // NP2kai io/upd4990.c:29-30 sets regsft = 0 on a hold, and the module's own
    // header says only SHIFT arms the walk-out. A behavioral cdat check cannot
    // separate the two here: NP2kai's DATA-write path rewrites reg[pos] before the
    // STB, so its post-hold cdat is the corrupted bit either way. The contract is
    // read directly instead.
    send_serial(4'd3);
    send_serial(4'd1);
    if (dut.shifting !== 1'b1)
      fail("SHIFT (opcode 1) did not arm the output walk");
    send_serial(4'd0);            // register hold
    if (dut.shifting !== 1'b0)
      fail("register-hold (opcode 0) left the output walk armed (NP2kai regsft=0)");

    // ---- C. a serial opcode with bit 3 set is not an alias of opcodes 0-3
    // 0xA is NP2kai's 30-second interrupt command: no case matches, so it does
    // nothing. An accumulator holding a valid different time proves the RTL used it.
    send_serial(4'd1);                                  // SHIFT: clear the input accumulator
    send_time(8'h00, 8'h00, 8'h00, 8'h01, 8'h11, 8'h01); // 2001-01-01, month 1 wday 1
    send_serial(4'hA);                                  // NP2kai: no-op
    read_clock(s, m, h, d, mw, y);
    if (s !== 8'h56 || m !== 8'h34 || h !== 8'h12 ||
        d !== 8'h12 || mw !== 8'h95 || y !== 8'h26)
      fail("serial opcode 0xA aliased to TIMESET: the counters moved off the framework time");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CALENDAR_PROTOCOL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CALENDAR_PROTOCOL: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_CALENDAR_PROTOCOL: timeout");
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MPU: The MPU-PC98II register model answers the read side the driver hangs on (idle status 0x80, the ACK 0xFE per command with bit 7 clearing while it is queued, the data register's last-read latch), frames the intelligent-mode transfers it receives (0xD0 + 3 bytes emitted as one complete 0x90 40 7F message, 0xDF + F0..F7 byte-identically), emits the 0xFF reset's 16-channel all-notes-off burst in order, produces no MIDI bytes for a follow-byte command, enters UART mode on 0x3F, and raises the H.CLK 0xFD after 0x95 - all at the real 31250-baud line rate, which a two-clock probe measures as the SAME 32 us bit time and 320 us byte time at 50 and 100 MHz.
//
// The expected values are the reference's, not this RTL's: NP2kai's model
// (../NP2kai/cbus/mpu98ii.c) for the status polarity (:1101-1104), the ACK (:1030), the short
// message's framing and length table (:100, :777-812), the system-exclusive framing (:806-838),
// the reset burst (:223-233), the H.CLK tick and its stepclock (:111-129, :333-356, :532-537),
// and the register defaults (:1149 data = MPUMSG_ACK); and MMD.COM's own primitives for what
// the driver polls (CS:0x01C6 read, CS:0x01D3 write, CS:0x15AC presence probe, CS:0x167E H.CLK
// wait), every one of them read from the driver's disassembly.
//
// FAIL-FIRST, class by class: with the read-back replaced by a tie-off (the shape pc9821_iobus
// gives an undecoded port) the idle-status check reads 0xFF and the driver's `test al,al / js`
// loop never exits; with the message assembly removed the 0x90 40 7F check sees three separate
// bytes instead of one message; with the reset burst removed the 48-byte check sees zero; with
// the H.CLK arm removed the 0xFD check times out; and with the serialiser's divider taken from
// a fixed clk_sys count instead of SYS_CLOCK_HZ the 100 MHz probe's bit time halves.

module tb_pc9821_mpu;

  // ==== DUT ====
  localparam integer BIT_CYCLES = 1600;          // 50_000_000 / 31250, exact at every profile clock

  reg         clk = 1'b0;
  reg         clk100 = 1'b0;
  reg         reset = 1'b1;
  always #10 clk = ~clk;                          // 50 MHz (the base profile)
  always #5  clk100 = ~clk100;                    // 100 MHz (mediumoc)

  reg         cs = 1'b0;
  reg  [15:0] addr = 16'hE0D0;
  reg         wr = 1'b0;
  reg         rd = 1'b0;
  reg  [7:0]  din = 8'h00;
  wire [7:0]  dout;
  wire        uart_tx;
  wire        irq;

  pc9821_mpu #(.SYS_CLOCK_HZ(50_000_000)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .uart_tx(uart_tx), .irq(irq));

  // The line receiver: every byte the DUT puts on the wire, decoded at 8N1 LSB-first by
  // sampling the middle of each bit. It runs for the whole test, so a byte that appears EARLY
  // (before a message is complete, or at all when the command should be silent) is caught
  // rather than reasoned about.
  reg  [7:0]  stream [0:255];
  integer     stream_len = 0;
  integer     k;
  reg  [7:0]  rx_byte;

  initial begin : rx_loop
    // The line is only meaningful once the reset has been released: before that the
    // transmitter's power-up mark has not been applied and a zero would read as a start bit.
    wait (!reset);
    repeat (2) @(posedge clk);
    forever begin
      while (uart_tx !== 1'b0) @(posedge clk);   // the start bit's falling edge
      repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        rx_byte[k] = uart_tx;
        repeat (BIT_CYCLES) @(posedge clk);
      end
      if (stream_len < 256) begin
        stream[stream_len] = rx_byte;
        stream_len = stream_len + 1;
      end
      // The stop bit: wait for the mark instead of counting one more bit time, so a byte
      // that follows with a SHORT gap is still found by its own start edge rather than
      // missed while this receiver was still timing the previous byte out.
      while (uart_tx !== 1'b1) @(posedge clk);
    end
  end

  // ==== CHECKS ====
  integer errors = 0;

  task automatic chk(input condition, input string msg);
    begin
      if (!condition) begin
        errors = errors + 1;
        $display("FAIL %s", msg);
        $fatal(1, "MPU check failed: %s", msg);
      end
    end
  endtask

  // One device strobe, exactly as pc9821_iobus presents it: cs and the address are held for one
  // clk_sys while the one-cycle S_BYTE strobe is high.
  // The stimulus is driven from the NEGEDGE, so the DUT's posedge always samples the strobe
  // and there is no race between this bench and the DUT about which edge sees it.
  task automatic bus_wr(input [15:0] a, input [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; din = b; wr = 1'b1; rd = 1'b0;
      @(negedge clk);
      wr = 1'b0; cs = 1'b0;
    end
  endtask

  // A read samples the byte combinationally (pc9821_system's device read mux takes it in the
  // strobe cycle), and the DATA port's pop happens on the strobe's clk edge.
  task automatic bus_rd(input [15:0] a, output [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; rd = 1'b1; wr = 1'b0;
      #1;
      b = dout;
      @(negedge clk);
      rd = 1'b0; cs = 1'b0;
    end
  endtask

  task automatic idle_cycles(input integer n);
    integer j;
    begin
      for (j = 0; j < n; j = j + 1) @(posedge clk);
    end
  endtask

  reg [7:0] b0, b1;
  integer   t0;

  wire [31:0] rate50_bit_ns, rate100_bit_ns;

  initial begin
    fork
      // A bench that stops making progress names itself instead of hanging the runner.
      // 200 ms of simulated time covers every burst and tick this bench waits for.
      begin
        #200_000_000;
        $fatal(1, "tb_pc9821_mpu did not finish in 200 ms of simulated time");
      end
      begin
        reset = 1'b1;
        idle_cycles(20);
        reset = 1'b0;
        idle_cycles(20);

        // ---- 1. the idle read-back: status 0x80, data 0xFE, no IRQ -------------------
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "idle status is not 0x80 (bit 7 = response register empty)");
        chk(irq == 1'b0, "IRQ asserted with an empty response queue");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the data register of an empty queue does not return the latch");

        // ---- 2. MMD's presence probe: (rd(0xE0D0) & rd(0xE0D2)) != 0xFF --------------
        bus_rd(16'hE0D0, b0);
        bus_rd(16'hE0D2, b1);
        chk((b0 & b1) != 8'hFF, "the presence probe's AND reads all ones: no board");

        // ---- 3. every command queues an ACK, and bit 7 clears while it is queued ------
        bus_wr(16'hE0D2, 8'h94);            // clock to host OFF
        bus_rd(16'hE0D2, b0);
        chk(b0[7] == 1'b0, "status bit 7 stayed set with an ACK queued");
        chk(irq == 1'b1, "IRQ not asserted with an ACK queued");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the ACK is not 0xFE");
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "status did not return to 0x80 after the queue drained");
        chk(irq == 1'b0, "IRQ stayed asserted after the queue drained");

        // ---- 4. 0xE7 + 0x04: ACKed, and NOTHING reaches the line ---------------------
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hE7);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xE7 was not ACKed");
        bus_wr(16'hE0D0, 8'h04);
        idle_cycles(100_000);               // 2 ms, six byte times
        chk(stream_len == 0, "a follow-byte command put bytes on the MIDI line");

        // ---- 5. 0xD0 + 90 40 7F: exactly one complete message, and only at completion -
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hD0);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xD0 was not ACKed");
        bus_wr(16'hE0D0, 8'h90);
        bus_wr(16'hE0D0, 8'h40);
        idle_cycles(100_000);
        chk(stream_len == 0, "an incomplete short message reached the line");
        bus_wr(16'hE0D0, 8'h7F);
        idle_cycles(60_000);                // ~1.2 ms: three byte times
        chk(stream_len == 3, "the completed short message did not put exactly 3 bytes out");
        chk(stream[0] == 8'h90, "short message byte 0 is wrong");
        chk(stream[1] == 8'h40, "short message byte 1 is wrong");
        chk(stream[2] == 8'h7F, "short message byte 2 is wrong");

        // ---- 6. 0xDF + a system exclusive passes through byte-identically --------------
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hDF);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xDF was not ACKed");
        bus_wr(16'hE0D0, 8'hF0);
        bus_wr(16'hE0D0, 8'h43);
        bus_wr(16'hE0D0, 8'h75);
        bus_wr(16'hE0D0, 8'h00);
        bus_wr(16'hE0D0, 8'h01);
        bus_wr(16'hE0D0, 8'hF7);
        idle_cycles(100_000);
        chk(stream_len == 6, "the system exclusive put the wrong number of bytes out");
        chk(stream[0] == 8'hF0 && stream[1] == 8'h43 && stream[2] == 8'h75 &&
            stream[3] == 8'h00 && stream[4] == 8'h01 && stream[5] == 8'hF7,
            "the system exclusive is not byte-identical");

        // ---- 7. 0x95: the H.CLK byte the driver's connection check waits for ----------
        bus_wr(16'hE0D2, 8'h95);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0x95 was not ACKed");
        bus_rd(16'hE0D2, b0);
        chk(b0[7] == 1'b0, "no H.CLK byte in the response queue after 0x95");
        chk(irq == 1'b1, "IRQ not asserted for the H.CLK byte");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFD, "the H.CLK byte is not 0xFD");
        // It repeats at the reference's stepclock, SYS_CLOCK_HZ/200 = 5 ms (250_000 cycles).
        t0 = 0;
        while (irq == 1'b0 && t0 < 600_000) begin
          @(posedge clk);
          t0 = t0 + 1;
        end
        chk(irq == 1'b1, "the H.CLK tick did not repeat within 12 ms");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFD, "the repeated H.CLK byte is not 0xFD");
        chk((t0 > 200_000) && (t0 < 300_000),
            "the H.CLK period is not the reference's stepclock (250_000 cycles)");

        // ---- 8. 0x94 turns it off again ----------------------------------------------
        bus_wr(16'hE0D2, 8'h94);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0x94 was not ACKed");
        idle_cycles(600_000);               // 12 ms: two stepclocks
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "the H.CLK tick continued after 0x94");

        // ---- 9. BUSY (status bit 6) is the output credit -----------------------------
        bus_rd(16'hE0D2, b0);
        chk(b0[6] == 1'b0, "BUSY is set with an idle output queue");
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hFF);            // reset: the 48-byte all-notes-off burst
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xFF was not ACKed");
        idle_cycles(1000);
        bus_rd(16'hE0D2, b0);
        chk(b0[6] == 1'b1, "BUSY is clear while the 48-byte reset burst is outstanding");
        idle_cycles(900_000);               // 18 ms: 48 byte times is 15.4 ms
        bus_rd(16'hE0D2, b0);
        chk(b0[6] == 1'b0, "BUSY stayed set after the reset burst drained");
        chk(stream_len == 48, "the reset did not put 48 bytes on the line");
        begin : burst_chk
          integer i;
          for (i = 0; i < 16; i = i + 1) begin
            chk(stream[i*3 + 0] == (8'hB0 + i[7:0]), "the reset burst's channel status is wrong");
            chk(stream[i*3 + 1] == 8'h7B, "the reset burst's controller byte is not 0x7B");
            chk(stream[i*3 + 2] == 8'h00, "the reset burst's value byte is not 0x00");
          end
        end

        // ---- 10. 0x3F: UART mode, and a data write passes straight through ------------
        stream_len = 0;
        bus_wr(16'hE0D2, 8'h3F);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0x3F was not ACKed");
        idle_cycles(900_000);               // drain the burst 0x3F also sends
        chk(stream_len == 48, "UART mode did not send the all-notes-off burst");
        stream_len = 0;
        bus_wr(16'hE0D0, 8'h5A);
        idle_cycles(60_000);
        chk(stream_len == 1 && stream[0] == 8'h5A,
            "a UART-mode data write did not pass straight through");
        // A command that is not 0xFF is NOT ACKed in UART mode (mpu98ii_o2's mode branch), and
        // 0xFF returns to intelligent mode with an ACK.
        bus_wr(16'hE0D2, 8'h94);
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "a command was ACKed in UART mode");
        bus_wr(16'hE0D2, 8'hFF);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xFF did not return from UART mode with an ACK");

        // ---- 10b. the response queue holds two values: ACK 0xFE and H.CLK 0xFD, and ---
        // ----      an ACK outranks a tick when both land on the same cycle --------------
        // Order 1 (H.CLK first, then ACK): 0x95 queues its own ACK and arms the immediate
        // kick, so the queue reads 0xFE then the kick's 0xFD; after one stepclock the periodic
        // H.CLK 0xFD arrives with no ACK ahead of it, and a 0x94 ACK queues BEHIND it.
        bus_wr(16'hE0D2, 8'h95);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0x95's own ACK is not 0xFE");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFD, "the 0x95 kick's H.CLK is not 0xFD");
        t0 = 0;
        while (irq == 1'b0 && t0 < 600_000) begin
          @(posedge clk);
          t0 = t0 + 1;
        end
        chk(irq == 1'b1, "the periodic H.CLK tick did not arrive within 12 ms");
        bus_wr(16'hE0D2, 8'h94);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFD, "the H.CLK queued ahead of the ACK is not 0xFD");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the ACK queued behind the H.CLK is not 0xFE");

        // Order 2 (same cycle): 0x95 arms the kick; the next command's strobe lands on the
        // kick's own cycle, so the ACK and the tick coincide. The ACK must win and the tick be
        // dropped - exactly two 0xFE bytes, no 0xFD.
        bus_wr(16'hE0D2, 8'h95);
        cs = 1'b1; addr = 16'hE0D2; din = 8'h94; wr = 1'b1; rd = 1'b0;
        @(negedge clk);
        wr = 1'b0; cs = 1'b0;
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the same-cycle ACK did not outrank the H.CLK kick (first byte)");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the same-cycle ACK did not outrank the H.CLK kick (second byte)");
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "the dropped H.CLK kick left a byte behind the two ACKs");

        // ---- 11. the two-clock line rate ----------------------------------------------
        // The probes run their own DUTs from the same reset; a fixed clk_sys count would read
        // 32 us at 50 MHz and 16 us at 100 MHz.
        t0 = 0;
        while ((rate50_bit_ns == 32'd0 || rate100_bit_ns == 32'd0) && t0 < 2_000_000) begin
          @(posedge clk);
          t0 = t0 + 1;
        end
        chk(t0 < 2_000_000, "the two-clock rate probes did not complete");
        chk(rate50_bit_ns  == 32'd32_000, "the 50 MHz MIDI bit time is not 32 us");
        chk(rate100_bit_ns == 32'd32_000, "the 100 MHz MIDI bit time is not 32 us");

        // ==== VERDICT ====
        $display("TB_PC9821_MPU: PASS");
        $finish;
      end
    join
  end

  tb_mpu_rate_probe #(.HZ(50_000_000)) rate50 (
      .clk(clk), .reset(reset), .bit_ns(rate50_bit_ns));
  tb_mpu_rate_probe #(.HZ(100_000_000)) rate100 (
      .clk(clk100), .reset(reset), .bit_ns(rate100_bit_ns));

endmodule

// ==== THE LINE-RATE PROBE ====
// Drives one channel message into its own pc9821_mpu and measures, in NANOSECONDS, the start
// bit's width - which IS the bit time, 1/31250 s. It is a real time: a divider counting clk_sys
// rather than deriving from SYS_CLOCK_HZ reports half the time at twice the clock.
module tb_mpu_rate_probe #(parameter integer HZ = 50_000_000) (
    input  wire        clk,
    input  wire        reset,
    output reg  [31:0] bit_ns
);
  reg         cs = 1'b0;
  reg  [15:0] addr = 16'hE0D0;
  reg         wr = 1'b0;
  reg         rd = 1'b0;
  reg  [7:0]  din = 8'h00;
  wire [7:0]  dout;
  wire        uart_tx;
  wire        irq;
  integer     c;
  localparam integer NS_PER_CYCLE = 1_000 / (HZ / 1_000_000);

  pc9821_mpu #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .uart_tx(uart_tx), .irq(irq));

  // The stimulus is driven from the NEGEDGE, so the DUT's posedge always samples the strobe
  // and there is no race between this bench and the DUT about which edge sees it.
  task automatic bus_wr(input [15:0] a, input [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; din = b; wr = 1'b1; rd = 1'b0;
      @(negedge clk);
      wr = 1'b0; cs = 1'b0;
    end
  endtask

  initial begin
    bit_ns = 32'd0;
    wait (!reset);
    repeat (10) @(posedge clk);
    // 0xD0 (command) then 0x91 0x7F 0x7F: one complete channel message reaches the wire. Both
    // bytes have bit 0 SET, so the first low run after the falling edge IS the start bit and
    // nothing else - with a bit 0 of zero the run would continue through the data bits.
    bus_wr(16'hE0D2, 8'hD0);
    bus_wr(16'hE0D0, 8'h91);
    bus_wr(16'hE0D0, 8'h7F);
    bus_wr(16'hE0D0, 8'h7F);
    // The start bit is the first falling edge after the line has idled high.
    while (uart_tx !== 1'b1) @(posedge clk);
    while (uart_tx !== 1'b0) @(posedge clk);
    c = 0;
    while (uart_tx === 1'b0) begin
      @(posedge clk);
      c = c + 1;
    end
    bit_ns = c * NS_PER_CYCLE;      // one clk cycle is NS_PER_CYCLE nanoseconds
  end
endmodule

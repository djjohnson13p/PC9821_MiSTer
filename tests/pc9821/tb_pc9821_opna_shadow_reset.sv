`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_SHADOW_RESET: pc9821_opna's SSG read shadow (ssg_reg) restores the board's reset image ATOMICALLY across a device reset, and a guest write is never clobbered by the 16-clk seeding sweep that stands in for the block memory's missing reset. The reset is atomic at the FIRST access: a 0x18A read of register 0x0F issued about seven clock after the reset lifts answers the reset byte 0xFF - what the flop form installed and what the `initial` image carries - even though the sweep has not reached entry 15, where the pre-change tree answered the PRE-reset 0x80, so this arm is FAIL-FIRST. A guest write is preserved ACROSS CYCLES: a write of 0x5A to register 0x0A four clock into that sweep reads back 0x5A once the sweep is done, where the pre-change tree read back the reset 0x00 because the sweep visited entry 10 later and overwrote it - the code's claim that a host write is never clobbered held only for the same-cycle collision, so this arm is FAIL-FIRST too. Both are proven at the module boundary, for a bare master as well as through pc9821_iobus, because the module answers the reset image for an entry that is neither seeded nor guest-written and skips the entries the guest has written. The power-up image and the steady state are asserted with them: register 7 reads the MACHINE's 0x00 (probes/OPNA.TXT section CHIPID) and register 0x0F reads NP2kai's opna_reset 0xFF, and after the sweep all sixteen shadow entries (register 0x0E excepted - 0x18A answers that one from the joystick) read the reset image.
//
// THE SHAPE OF THE FIX, and why not a guest-access gate. Gating the guest (holding the
// device's io_wr_wait / read-hold until the sweep finishes) makes F1 true but leaves F2
// intact: it only DEFERS a write, and the module still clobbers one presented inside the
// window, so F2's own minimal case - a direct 0x18A write four clocks into the sweep -
// still reads back 0x00 across cycles. The flag shape satisfies both findings at the
// module boundary, for a bare master as well as through the iobus, and removes the
// window instead of pinning the ~1-clk margin between a 16-clk sweep and the CPU reset
// gate's hold.
//
// REFERENCES (external). NP2kai sound/opna.c opna_reset seeds the SSG shadow: reg[0x07]
// = 0xbf, reg[0x0e] = 0xff, reg[0x0f] = 0xff, everything else 0. The MACHINE refutes the
// reg-7 seed (probes/OPNA.TXT section CHIPID reads 0x00), so this bench asserts the
// capture for register 7 and the reference for 0x0f, exactly as tb_pc9821_opna_regs does.
//
// ==== DUT ====
// pc9821_opna alone, at its own host port pair (0x188 = register select / status read,
// 0x18A = data), the addressing a driver uses. tb_pc9821_opna proves iobus routes those
// ports here; this bench is about the module's own reset behaviour, so it drives the
// module directly and needs no bus master.
module tb_pc9821_opna_shadow_reset;

  localparam integer SYS_CLOCK_HZ = 50_000_000;
  reg clk = 0;
  always #10 clk = ~clk;

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  wire [7:0] io_dout;
  wire       io_rd_wait, irq;
  wire signed [19:0] snd_l, snd_r;

  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .extend(1'b0),
    .joystick(6'b111111),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  integer errors = 0;

  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
  // The 0x188 register-select write, the 0x18A data write and the 0x18A read are the
  // three the driver's own sound_o/read_reg use (the games' register write: index to
  // 0x188, data to 0x18A, as tb_pc9821_opna_regs quotes from master.lib's soundio.asm).
  task automatic write_port(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk); io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk); io_wr = 0; io_din = 8'h00;
      @(negedge clk);
    end
  endtask

  task automatic read_port(input [15:0] portnum, output [7:0] data);
    begin
      @(negedge clk); io_addr = portnum; io_rd = 1;
      @(negedge clk); @(negedge clk);
      #1 data = io_dout;
      @(negedge clk); io_rd = 0;
      @(negedge clk);
    end
  endtask

  task automatic read_reg(input [7:0] reg_index, output [7:0] data);
    begin
      write_port(16'h0188, reg_index);
      read_port(16'h018A, data);
    end
  endtask

  task automatic write_reg(input [7:0] reg_index, input [7:0] data);
    begin
      write_port(16'h0188, reg_index);
      write_port(16'h018A, data);
    end
  endtask

  task automatic wait_clk(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(posedge clk);
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] v;
  integer   i;

  initial begin
    // ---------------- power-on: the image, and the sweep - the steady state ----------
    reset = 1;
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    wait_clk(2000);

    read_reg(8'h07, v);
    if (v !== 8'h00)
      fail("fresh shadow reg 7 is not the machine's 0x00 (probes/OPNA.TXT CHIPID)");
    read_reg(8'h0F, v);
    if (v !== 8'hFF)
      fail("fresh shadow reg 0x0F is not NP2kai opna_reset's 0xFF");
    read_reg(8'h03, v);
    if (v !== 8'h00)
      fail("fresh shadow reg 3 is not the reset 0x00");

    // ---------------- F1: the FIRST read after a reset is the reset image ----------
    // Write reg 0F = 0x80 and confirm it reads back, then let a reset wipe it.
    write_reg(8'h0F, 8'h80);
    read_reg(8'h0F, v);
    if (v !== 8'h80)
      fail("reg 0F write did not read back 0x80");

    // A SHORT reset, then read 0F at the first access: the sweep needs 16 clk and
    // entry 15 is the LAST it restores, so this read lands while ssg_seed < 16.
    // The flop form installed 0xFF here; the pre-change sweep form answered 0x80.
    reset = 1;
    wait_clk(8);
    @(negedge clk); reset = 0;
    read_reg(8'h0F, v);
    $display("PROBE first reg 0F read after a short reset: %02x (reset image: FF, stale: 80) ssg_seed=%0d",
             v, dut.ssg_seed);
    if (v !== 8'hFF)
      fail("F1: the first reg 0F read after a reset is NOT the reset image 0xFF");

    // A second high register too, to show the answer is not one entry's luck.
    read_reg(8'h07, v);
    if (v !== 8'h00)
      fail("F1: reg 7 during the sweep is not the reset image 0x00");

    // After the sweep, the whole image is back (0x0E is answered from the joystick).
    wait_clk(200);
    for (i = 0; i < 16; i = i + 1) begin
      if (i == 8'h0E) continue;
      read_reg(i[7:0], v);
      if (v !== ((i == 15) ? 8'hFF : 8'h00))
        fail("the shadow entry after the sweep is not its reset image");
    end

    // ---------------- F2: a guest write inside the sweep STICKS --------------------
    // A write to reg 0x0A lands about four clock into the sweep. The guest write wins
    // its own cycle either way; the requirement is that the sweep, which reaches entry
    // 10 several clocks later, must not overwrite it.
    reset = 1;
    wait_clk(8);
    @(negedge clk); reset = 0;
    write_reg(8'h0A, 8'h5A);
    wait_clk(200);
    read_reg(8'h0A, v);
    $display("PROBE reg 0A after a mid-sweep guest write: %02x (kept: 5A, clobbered: 00)", v);
    if (v !== 8'h5A)
      fail("F2: the seeding sweep clobbered a guest write to reg 10");

    // The entries the guest did NOT write are still the reset image: the write protected
    // its own entry, not the sweep's whole run.
    read_reg(8'h0B, v);
    if (v !== 8'h00)
      fail("F2: a neighbouring entry is not the reset image after the mid-sweep write");

    // ---------------- a write AFTER the sweep, the ordinary case --------------------
    write_reg(8'h05, 8'h3C);
    read_reg(8'h05, v);
    if (v !== 8'h3C)
      fail("a reg 5 write after the sweep did not read back 0x3C");
    // ... and a later reset wipes it back to the image.
    reset = 1;
    wait_clk(40);
    @(negedge clk); reset = 0;
    wait_clk(200);
    read_reg(8'h05, v);
    if (v !== 8'h00)
      fail("a reset did not restore the shadow entry a guest had written");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_SHADOW_RESET: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_SHADOW_RESET: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: every wait here is cycle-bounded, so this only fires if the
  // DUT stops responding altogether.
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_OPNA_SHADOW_RESET: TIMEOUT");
  end

endmodule

`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The portable RAM's four contracts, any of which silently corrupts a consumer elsewhere: port B's read enable is a HOLD rather than a free-running read (the module's own reason to have an enable at all -- the GDC scanout and the 86-PCM drain both depend on the data phase following only the address that was presented), a write returns the written byte on that port's output in the same cycle, both ports share one array, and INIT_EN lands INIT_LEN bytes at INIT_OFFSET and nothing else, and INIT2_EN does the same for a second disjoint run (the battery-backed configuration record firmware refuses to boot without).
//
// ---- the bench's own account of where each expectation comes from ----
// The portable RAM's four contracts, each of which silently corrupts a consumer
// somewhere else in the tree if it breaks:
//
//  1. PORT B'S READ ENABLE IS A HOLD, NOT A FREE-RUNNING READ. The module's own
//     header says why this is the whole reason `en_b` exists: "a free-running
//     read would return the byte for the current dot when the enables have gaps
//     and the previous dot's byte when they do not." The GDC scanout and the
//     86-PCM's drain both rely on it -- the PCM presents an address in D_RD and
//     captures in D_CAP precisely because the data phase must depend only on the
//     address presented, and a registered enable would be one cycle late.
//     [source: src/pc9821/common/pc9821_dpram.sv's own port documentation]
//
//  2. A WRITE ON A PORT RETURNS THE WRITTEN BYTE ON THAT PORT'S OUTPUT IN THE
//     SAME CYCLE. Consumers latch `q` on the write cycle.
//
//  3. THE PORTS SHARE ONE ARRAY, so a byte written on A is visible on B. A
//     module that inferred two arrays would pass every single-port test and fail
//     here.
//
//  4. INIT_EN WRITES INIT_LEN BYTES FROM INIT_OFFSET AND NOTHING ELSE, and
//     INIT2_EN does the same for a SECOND disjoint run (the CG store's
//     configuration lives in two: the software-DIP record and its port mirror).
//     This is
//     the battery-backed machine configuration that lives inside text VRAM: a
//     real machine has it present before the guest runs, and firmware that
//     validates it refuses to boot without it. Byte `i` of INIT_BYTES is
//     INIT_BYTES[i*8 +: 8], so byte 0 is the LOWEST byte of the literal.
//     [source: the module's INIT_* parameters; first consumer pc9821_gdc_text's
//     CG store, whose power-on configuration record lives there]
//
// The two ports run on deliberately different clocks, and every stimulus is
// driven off clk_b edges so that the interleaving is deterministic.

module tb_pc9821_dpram;
  reg clk_a = 0, clk_b = 0;
  always #5 clk_a = ~clk_a;   // 10 ns
  always #3 clk_b = ~clk_b;   // 6 ns, deliberately unrelated

  localparam AW = 6, DW = 8;

  reg              wren_a = 0, wren_b = 0, en_b = 0;
  reg  [AW-1:0]    address_a = 0, address_b = 0;
  reg  [DW-1:0]    data_a = 0, data_b = 0;
  wire [DW-1:0]    q_a;
  wire [DW-1:0]    q_b;

  // ==== DUT ====
  // Bytes 0..3 are 00 01 02 03 -- the lowest byte of the literal is byte 0.
  pc9821_dpram #(
      .AW(AW), .DW(DW),
      .INIT_EN(1'b1), .INIT_BYTES(256'hDEAD_BEEF_0000_0000_0000_0000_0302_0100),
      .INIT_LEN(4), .INIT_OFFSET(6'd5),
      .INIT2_EN(1'b1), .INIT2_BYTES(256'h0000_0000_0000_0000_0000_0000_0000_A55A),
      .INIT2_LEN(2), .INIT2_OFFSET(6'd40)
  ) dut (
      .clock_a(clk_a), .address_a(address_a), .data_a(data_a), .wren_a(wren_a), .q_a(q_a),
      .clock_b(clk_b), .en_b(en_b), .address_b(address_b), .data_b(data_b), .wren_b(wren_b),
      .q_b(q_b)
  );

  // ==== CHECKS ====

  integer errors = 0;

  // Port B read: drive the address with the enable, then sample after one more
  // clk_b edge, which is the registered read latency the module documents.
  task rd_b(input [AW-1:0] a, input [7:0] want, input [127:0] what);
    begin
      @(negedge clk_b);
      address_b = a; en_b = 1;
      @(posedge clk_b); #1;
      if (q_b !== want) begin
        $display("FAIL %0s: q_b=%02x at address %0d, expected %02x", what, q_b, a, want);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk_b);

    // ---- 4. INIT contents, at INIT_OFFSET, and nothing below it ----
    rd_b(6'd5, 8'h00, "INIT byte 0 at offset 5");
    rd_b(6'd6, 8'h01, "INIT byte 1 at offset 6");
    rd_b(6'd7, 8'h02, "INIT byte 2 at offset 7");
    rd_b(6'd8, 8'h03, "INIT byte 3 at offset 8");
    rd_b(6'd4, 8'h00, "byte BELOW INIT_OFFSET (must not be seeded)");
    rd_b(6'd9, 8'h00, "byte ABOVE INIT_LEN (must not be seeded)");
    rd_b(6'd40, 8'h5A, "INIT2 byte 0 at offset 40");
    rd_b(6'd41, 8'hA5, "INIT2 byte 1 at offset 41");
    rd_b(6'd39, 8'h00, "byte BELOW INIT2_OFFSET (must not be seeded)");
    rd_b(6'd42, 8'h00, "byte ABOVE INIT2_LEN (must not be seeded)");

    // ---- 2. a write on A returns the written byte on A ----
    @(negedge clk_b);
    address_a = 6'd20; data_a = 8'h5A; wren_a = 1;
    @(posedge clk_a); #1;
    if (q_a !== 8'h5A) begin
      $display("FAIL port A write-through: q_a=%02x, expected 5A", q_a);
      errors = errors + 1;
    end
    @(negedge clk_b); wren_a = 0;

    // ---- 3. the same byte is visible on port B ----
    rd_b(6'd20, 8'h5A, "byte written on port A read back on port B");

    // ---- 2b. and a write on B returns the written byte on B ----
    @(negedge clk_b);
    address_b = 6'd21; data_b = 8'hA5; wren_b = 1;
    @(posedge clk_b); #1;
    if (q_b !== 8'hA5) begin
      $display("FAIL port B write-through: q_b=%02x, expected A5", q_b);
      errors = errors + 1;
    end
    @(negedge clk_b); wren_b = 0;
    rd_b(6'd21, 8'hA5, "port B reads back its own write");

    // ---- 1. en_b LOW HOLDS THE OUTPUT: the module's reason to exist ----
    // Present a DIFFERENT address whose contents differ from what q_b holds. A
    // free-running read returns that address's byte; a hold keeps 0xA5.
    @(negedge clk_b);
    address_b = 6'd5; en_b = 0;
    repeat (4) @(posedge clk_b); #1;
    if (q_b !== 8'hA5) begin
      $display("FAIL en_b low did not hold: q_b=%02x, expected the previous A5 (a free-running read returned the newly addressed byte %02x)", q_b, 8'h00);
      errors = errors + 1;
    end
    // Raising the enable at that address must now return the seeded byte, which
    // also proves the hold was a hold and not a stuck register.
    rd_b(6'd5, 8'h00, "en_b re-enabled read at the address presented while disabled");

    // ---- port A has no enable and follows its address every clk_a ----
    @(negedge clk_b); en_b = 0;
    address_a = 6'd20; @(posedge clk_a); #1;
    if (q_a !== 8'h5A) begin
      $display("FAIL port A read-back at 20: q_a=%02x, expected 5A", q_a);
      errors = errors + 1;
    end
    address_a = 6'd5; @(posedge clk_a); #1;
    if (q_a !== 8'h00) begin
      $display("FAIL port A read at the seeded location 5: q_a=%02x, expected 00", q_a);
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DPRAM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_DPRAM: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_DPRAM: TIMEOUT");
  end

endmodule

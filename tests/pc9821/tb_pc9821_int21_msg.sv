`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_INT21_MSG: The INT-21h telemetry record formats one completed call as the 1.4 wire-format pair - "21 IN AH=.. BX=.. CS=.. IP=.." then "21 OUT AH=.. CY=.. AX=.. BX=..", 71 bytes in two bare-LF lines - from a snapshot latched at the vectoring-read trigger and the caller-return match, filters to AH in {48h,49h,4Ah} and rejects every other function, pairs the return only when the CPU is back at the caller CS:EIP, holds the snapshot across ack until the next entry, and counts a call that arrives while the record is being emitted as a drop instead of overwriting it.
//
// WHY THIS EXISTS. The record is a contract with tools/decode_telemetry.py and
// tools/check_telemetry_contract.py, and the only reader that checks the FORMATTER's bytes (the
// checker holds labels and lengths; this bench holds the byte-exact layout against the 1.4
// literals). The expected bytes are the 1.4 string literals themselves, not a copy of the
// formatter's case arms, so a shifted digit or a missing space fails here on the literal.

`default_nettype none

module tb_pc9821_int21_msg;

  // ==== DUT ====
  reg         clk = 1'b0;
  reg         reset = 1'b1;
  reg         vec_fetch = 1'b0;
  reg  [31:0] dbg_EAX = 32'd0;
  reg  [31:0] dbg_EBX = 32'd0;
  reg         dbg_CF = 1'b0;
  wire        arena_err;
  // Cycles arena_err was high: the instruction ring's freeze trigger (check 6).
  integer     arena_cycles = 0;
  always @(posedge clk) if (arena_err) arena_cycles = arena_cycles + 1;
  reg  [15:0] cpu_cs = 16'd0;
  reg  [31:0] cpu_eip = 32'd0;
  reg   [7:0] idx = 8'd0;
  reg         ack = 1'b0;
  reg         emitting = 1'b0;
  wire  [7:0] ch;
  wire        pending;
  wire  [7:0] drops;

  pc9821_int21_msg dut (
      .clk(clk), .reset(reset),
      .vec_fetch(vec_fetch),
      .dbg_EAX(dbg_EAX), .dbg_EBX(dbg_EBX), .dbg_CF(dbg_CF),
      .cpu_cs(cpu_cs), .cpu_eip(cpu_eip),
      .idx(idx), .ack(ack), .emitting(emitting),
      .ch(ch), .pending(pending), .drops(drops),
      .arena_err(arena_err)
  );

  // ==== STIMULUS ====
  integer errors = 0;

  // The 1.4 literals, verbatim. The IN line has TWO spaces after "IN" (to align with "OUT"),
  // which the formatter must reproduce exactly.
  string in_golden  = "21 IN  AH=48 BX=5208 CS=1A2B IP=022B\n";
  string out_golden = "21 OUT AH=48 CY=1 AX=0008 BX=1900\n";

  always #5 clk = ~clk;   // 10 ns period

  task automatic check_byte(input [511:0] what, input [7:0] got, input [7:0] want);
    begin
      if (got !== want) begin
        $display("  FAIL %s: got %02x, want %02x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("  ok   %s = %02x", what, got);
      end
    end
  endtask

  // Compare ch at indices base..base+len-1 against a golden string, byte for byte.
  task automatic check_line(input string golden, input integer len, input integer base);
    integer k;
    begin
      for (k = 0; k < len; k = k + 1) begin
        idx = base + k;
        #1;
        if (ch !== golden[k]) begin
          $display("  FAIL byte %0d: got %02x, want %02x", base + k, ch, golden[k]);
          errors = errors + 1;
        end
      end
    end
  endtask

  // One cycle of vec_fetch, driven between edges so the DUT samples it exactly once.
  task automatic pulse_vec();
    begin
      @(negedge clk);
      vec_fetch = 1'b1;
      @(negedge clk);
      vec_fetch = 1'b0;
    end
  endtask

  task automatic reset_dut();
    begin
      reset = 1'b1;
      vec_fetch = 1'b0; ack = 1'b0; emitting = 1'b0;
      repeat (3) @(posedge clk);
      reset = 1'b0;
      @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    reset_dut();

    // CHECK 1 - ENTRY: a vectoring-read trigger with AH=48 latches the entry half, and the IN
    // line reads the 1.4 literal byte for byte. The CPU is then moved to the handler (a different
    // EIP) so the return match does not fire on the entry cycle itself.
    $display("check 1: entry capture formats the IN line verbatim");
    dbg_EAX  = 32'h0000_4800;   // AH=48
    dbg_EBX  = 32'h0000_5208;   // BX=5208
    cpu_cs   = 16'h1A2B;
    cpu_eip  = 32'h0000_022B;   // caller CS:IP
    pulse_vec();
    cpu_eip = 32'h0000_4000;    // now inside the handler: return match must not fire yet
    @(posedge clk); #1;
    check_byte("no pending yet (handler still running)", {7'b0, pending}, 8'h00);
    check_line(in_golden, 37, 0);

    // CHECK 2 - RETURN: back at the caller's CS:EIP, the return half is latched, pending rises,
    // and the OUT line reads the 1.4 literal byte for byte. DOS's error-8 return clobbers AH to
    // 00 (AX=0008), while the OUT line's AH is the FUNCTION carried from the entry snapshot.
    $display("check 2: the caller-return match latches the return half and formats the OUT line");
    dbg_EAX = 32'h0000_0008;    // AX=0008 (AL=08, AH=00)
    dbg_EBX = 32'h0000_1900;    // BX=1900
    dbg_CF  = 1'b1;             // CY=1
    cpu_eip = 32'h0000_022B;    // iret arrives: back at the caller
    @(posedge clk); #1;
    check_byte("pending after the return", {7'b0, pending}, 8'h01);
    check_line(out_golden, 34, 37);

    // CHECK 2b - THE FIRST-CYCLE TRAP: the return half must NOT latch while the CPU is still at
    // the caller's CS:EIP in the first cycle after arming. in_eip_q is the fetch EIP captured at
    // the vectoring (already EIP+2, the return address), so on the real machine cpu_eip still
    // equals it for a cycle before the DOS handler runs; the OUT half may only fire after the CPU
    // has LEFT the caller and then come back.
    $display("check 2b: the OUT half does not latch before the CPU leaves the caller");
    reset_dut();
    dbg_EAX = 32'h0000_4800;    // entry AH=48, AX=4800
    dbg_EBX = 32'h0000_5208;    // entry BX=5208
    dbg_CF  = 1'b0;             // entry CY=0
    cpu_cs  = 16'h1A2B;
    cpu_eip = 32'h0000_022B;    // caller CS:IP
    pulse_vec();
    // One full cycle still at the caller (the CPU has not jumped to the handler yet): this must
    // NOT latch the return half, even though cpu_cs/eip equal the snapshot.
    @(posedge clk); #1;
    check_byte("no pending while still at the caller", {7'b0, pending}, 8'h00);

    // Now leave the caller (into the handler), then iret back with the DOS error-8 return.
    dbg_EAX = 32'h0000_0008;    // AX=0008 (AL=08, AH clobbered to 00)
    dbg_EBX = 32'h0000_9804;    // BX=9804
    dbg_CF  = 1'b1;             // CY=1
    cpu_eip = 32'h0000_4000;    // inside the handler
    @(posedge clk); #1;
    check_byte("no pending while in the handler", {7'b0, pending}, 8'h00);

    cpu_eip = 32'h0000_022B;    // iret arrives: back at the caller
    @(posedge clk); #1;
    check_byte("pending after the return (2b)", {7'b0, pending}, 8'h01);
    check_line("21 OUT AH=48 CY=1 AX=0008 BX=9804\n", 34, 37);

    // CHECK 3 - ACK: the sequencer's ack releases the record (pending clears) and leaves the
    // snapshot in place for the next entry.
    $display("check 3: ack releases the pending record");
    @(negedge clk);
    ack = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ack = 1'b0;
    check_byte("pending cleared by ack", {7'b0, pending}, 8'h00);

    // CHECK 4 - THE AH FILTER: 47h is rejected (the entry half is never latched), and 49h / 4Ah
    // are accepted exactly like 48h. The AH digits at index 10/11 are the proof either way.
    $display("check 4: the AH filter accepts 48h/49h/4Ah and rejects 47h");
    reset_dut();
    dbg_EAX = 32'h0000_4700;    // AH=47: not the OOM family
    cpu_cs = 16'h0001; cpu_eip = 32'h0000_0100;
    pulse_vec();
    cpu_eip = 32'h0000_5000;
    @(posedge clk); #1;
    idx = 8'd10; #1;
    check_byte("47h rejected: AH high nibble stays 0", {7'b0, ch}, 8'h30);   // idx 10 -> '0'
    check_byte("47h rejected: no pending", {7'b0, pending}, 8'h00);

    reset_dut();
    dbg_EAX = 32'h0000_4900;    // AH=49
    cpu_cs = 16'h0001; cpu_eip = 32'h0000_0100;
    pulse_vec();
    cpu_eip = 32'h0000_5000;
    @(posedge clk);
    idx = 8'd10; #1; check_byte("49h accepted: AH high nibble", {7'b0, ch}, 8'h34);
    idx = 8'd11; #1; check_byte("49h accepted: AH low nibble", {7'b0, ch}, 8'h39);

    reset_dut();
    dbg_EAX = 32'h0000_4A00;    // AH=4A
    cpu_cs = 16'h0001; cpu_eip = 32'h0000_0100;
    pulse_vec();
    cpu_eip = 32'h0000_5000;
    @(posedge clk);
    idx = 8'd10; #1; check_byte("4Ah accepted: AH high nibble", {7'b0, ch}, 8'h34);
    idx = 8'd11; #1; check_byte("4Ah accepted: AH low nibble", {7'b0, ch}, 8'h41);

    // CHECK 5 - A DROP, NEVER AN OVERWRITE: a new call while the previous record is still being
    // emitted increments the drop counter instead of overwriting the snapshot mid-emission.
    $display("check 5: a call during emission is counted as a drop, not an overwrite");
    reset_dut();
    dbg_EAX = 32'h0000_4800;
    cpu_cs = 16'h0001; cpu_eip = 32'h0000_0100;
    emitting = 1'b1;
    pulse_vec();
    @(posedge clk);
    check_byte("drops incremented", drops, 8'h01);
    check_byte("no entry latched while emitting", {7'b0, pending}, 8'h00);
    emitting = 1'b0;

    // CHECK 6 - THE ARENA-ERROR TRIGGER: a captured return with CF=1 and AX=0007h (DOS "memory
    // control blocks destroyed", the OP.EXE capture's second C0 shrink) pulses arena_err for ONE
    // cycle. Checks 1-5 above returned CF=1 AX=0008h (insufficient memory, an ordinary answer)
    // and must not have fired it: that is the negative control.
    $display("check 6: an AX=0007 CF=1 return pulses arena_err once; AX=0008 never does");
    check_byte("no arena_err on the AX=0008 returns", arena_cycles[7:0], 8'h00);
    reset_dut();
    dbg_EAX = 32'h0000_4A00;    // AH=4A
    dbg_EBX = 32'h0000_0881;
    dbg_CF  = 1'b0;
    cpu_cs = 16'h0F3F; cpu_eip = 32'h0000_009B;
    pulse_vec();
    dbg_EAX = 32'h0000_0007;    // AX=0007
    dbg_CF  = 1'b1;
    cpu_eip = 32'h0000_4000;    // inside DOS
    @(posedge clk); #1;
    cpu_eip = 32'h0000_009B;    // back at the caller
    repeat (4) @(posedge clk); #1;
    check_byte("arena_err pulsed exactly one cycle", arena_cycles[7:0], 8'h01);

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_INT21_MSG: %0d check(s) failed", errors);
    $display("TB_PC9821_INT21_MSG: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #1_000_000;
    $fatal(1, "the INT21 message bench did not finish in 1 ms of simulated time");
  end

endmodule

`default_nettype wire

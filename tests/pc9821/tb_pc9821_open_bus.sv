`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPEN_BUS:
// The open-bus responder's phases: no combinational response, acceptance separate from the data response, all-ones data, and a line read returning four all-ones words.


module tb_pc9821_open_bus;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg cpu_valid = 0, cpu_write = 0, cpu_line_read = 0;
  wire [31:0] cpu_dout;
  wire [127:0] cpu_line_dout;
  wire cpu_ready, cpu_resp_valid, cpu_line_resp_valid;

  // ==== DUT ====
  pc9821_open_bus dut (.*);
  integer errors = 0;
  // ==== CHECKS ====

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    cpu_valid = 1;

    @(negedge clk); // request captured, not accepted combinationally
    if (cpu_ready || cpu_resp_valid) begin
      $display("FAIL early open-bus response");
      errors = errors + 1;
    end
    @(negedge clk); // acceptance
    if (!cpu_ready || cpu_resp_valid) begin
      $display("FAIL acceptance phase");
      errors = errors + 1;
    end
    @(negedge clk); // separate read response
    if (cpu_ready || !cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF) begin
      $display("FAIL DWORD response phase");
      errors = errors + 1;
    end
    cpu_valid = 0;
    repeat (2) @(negedge clk);

    cpu_valid = 1;
    cpu_line_read = 1;
    repeat (3) @(negedge clk);
    if (!cpu_line_resp_valid || cpu_resp_valid ||
        cpu_line_dout !== {4{32'hFFFF_FFFF}}) begin
      $display("FAIL line response");
      errors = errors + 1;
    end
    cpu_valid = 0;
    cpu_line_read = 0;
    repeat (2) @(negedge clk);

    cpu_valid = 1;
    cpu_write = 1;
    repeat (2) @(negedge clk);
    if (!cpu_ready || cpu_resp_valid || cpu_line_resp_valid) begin
      $display("FAIL dropped-write acceptance");
      errors = errors + 1;
    end
    @(negedge clk);
    if (cpu_resp_valid || cpu_line_resp_valid) begin
      $display("FAIL dropped write generated response");
      errors = errors + 1;
    end
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_OPEN_BUS: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_OPEN_BUS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time
  // (BENCH_TIMEOUT) and greps the PASS marker, but a bench that
  // blocks on a DUT signal with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_OPEN_BUS: TIMEOUT");
  end

endmodule

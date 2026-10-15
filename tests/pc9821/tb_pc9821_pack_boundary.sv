`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PACK_BOUNDARY:
// The ROM loader's reserve boundary follows its OWN PACK_BYTES parameter rather than a hardcoded 1 MiB, and BOTH sides of that boundary are asserted: the last legal word of the reserve is accepted and written to SDRAM, and the first address at or above the reserve raises load_error with no write and never publishes rom_ready. The bench drives the DUT with an explicit small reserve, so a loader that ignored its parameter and hardcoded the shipped 1 MiB fails here, and the accept side of the boundary - the last word, which the existing rom_loader bench never sends - is checked rather than assumed.
//
// WHY THIS EXISTS, and it is measured rather than supposed. The existing tb_pc9821_rom_loader
// sends exactly one out-of-range address, 0x100000, and detects a wrong boundary only through the
// accepted-write COUNT. So a loader that rejects the reserve's final word - the classic off-by-one
// at the top, `ioctl_addr < PACK_BYTES - 2` - produces the same count and PASSES that bench. That
// was checked by planting the break: with `PACK_BYTES - 2` in place, the bench
// rom_loader reports PASS. The consequence of the break is that the last word of the firmware
// reserve never reaches SDRAM, which is latent today only because the region below 1 MiB happens to
// be 0xFF filler, and would be a corrupt pack the moment anything is placed near the top.
//
// SPECIFICATION SOURCES. The reserve contract is pc9821_rom_loader.sv's own comment, which states
// the two-sided rule directly: the reserve "must move together with gvram_base (pc9821_memory_
// subsystem.sv), the OSD RAM-size budget (z486_mister.sv) and the layout in tools/build_pack.py",
// and "Everything at or above it fails closed: a download that reaches this bound raises load_error
// and the CPU is never released". tools/build_pack.py fills the whole reserve
// (pack[0:FONT_OFFSET+FONT_SIZE] with FONT_SIZE ending at 0xC6800, and PACK_SIZE == PACK_BYTES ==
// 0x100000), so the last word is real pack data and must load. The backend's timing comes from
// src/memory/sdram.v's own header, "Write latency: ACT at t0, low-half write at t=T_RCD, high-half
// write at t=T_RCD+2", which is why this bench drives a backend that answers LATE: the loader's
// contract is about accepted-versus-stored, and a peer that is instantaneous cannot express it.

module tb_pc9821_pack_boundary;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [31:0] pack_base = 32'h01F8_0000;
  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait;
  wire mem_valid;
  reg mem_ready = 0;
  wire [31:0] mem_addr, mem_din;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_write, rom_ready, load_error, saw_download;

  // A SMALL RESERVE, DELIBERATELY. Testing the shipped 1 MiB would need 500 000 words to reach the
  // boundary, and testing the default would not notice a loader that hardcoded it. 16 KiB spans
  // both sides and keeps the bench in the seconds it is meant to take.
  localparam [26:0] RESERVE = 27'h000_4000;

  // ==== DUT ====
  pc9821_rom_loader #(.PACK_BYTES(RESERVE)) dut (
      .clk(clk), .reset(reset), .pack_base(pack_base),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
      .ioctl_wait(ioctl_wait),
      .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_addr(mem_addr),
      .mem_din(mem_din), .mem_be(mem_be), .mem_burstcount(mem_burstcount),
      .mem_write(mem_write),
      .rom_ready(rom_ready), .load_error(load_error), .saw_download(saw_download));

  integer errors = 0;
  integer accepted = 0;
  integer latency = 3;              // the backend answers several cycles late, as sdram.v does
  integer wait_count = 0;

  reg [31:0] got_addr[0:15];
  reg [31:0] got_data[0:15];

  // A BACKEND THAT IS NOT INSTANTANEOUS: a single dword write, accepted only after `latency`
  // cycles of valid, which is the shape sdram.v's own header describes rather than the
  // one-cycle answer every integrated tier models.
  always @(posedge clk) begin
    if (reset) begin
      mem_ready <= 1'b0;
      wait_count <= 0;
    end else if (mem_valid && !mem_ready) begin
      if (wait_count + 1 >= latency) begin
        mem_ready <= 1'b1;
        wait_count <= 0;
      end else begin
        wait_count <= wait_count + 1;
      end
    end else begin
      mem_ready <= 1'b0;
      wait_count <= 0;
    end
  end

  always @(posedge clk) begin
    if (mem_valid && mem_ready && accepted < 16) begin
      got_addr[accepted] = mem_addr;
      got_data[accepted] = mem_din;
      accepted = accepted + 1;
    end
  end

  // ==== STIMULUS ====
  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk);
      @(negedge clk);
      ioctl_addr = addr;
      ioctl_dout = data;
      ioctl_wr = 1;
      @(negedge clk);
      ioctl_wr = 0;
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);

    // --- The LAST LEGAL WORD of the reserve, worked through the loader and to the backend. This is
    // the accept side, and it is the side the existing bench does not send. The reserve's final
    // word spans two ioctl addresses: 0x3FFE carries ioctl_addr[1] set and lands in the word's HIGH
    // sixteen bits, 0x3FFC carries bit 1 clear and lands in the LOW half at the same word address.
    // Both must reach the backend, which is what 'the reserve's last word loaded' means.
    reset = 0;
    ioctl_index = 16'd0;
    ioctl_download = 1;
    @(negedge clk);
    send_word(RESERVE - 27'd2, 16'hA55A);   // high half, bit 1 set
    send_word(RESERVE - 27'd4, 16'h1234);   // low half, same word
    ioctl_download = 0;
    repeat (12) @(posedge clk);

    if (!rom_ready || load_error) begin
      $display("FAIL last legal word: ready=%b error=%b (the reserve's final word was rejected)",
               rom_ready, load_error);
      errors = errors + 1;
    end
    if (accepted != 2) begin
      $display("FAIL last legal word: accepted=%0d writes, expected 2 -- the boundary's accept",
               accepted);
      $display("     side is not enforced: the reserve's last word never reached the backend");
      errors = errors + 1;
    end else if (got_addr[0] !== (pack_base + 32'h0000_3FFC) ||
                 got_addr[1] !== (pack_base + 32'h0000_3FFC) ||
                 got_data[0] !== 32'hA55A_0000 || got_data[1] !== 32'h0000_1234) begin
      $display("FAIL last legal word: addr=%08x/%08x data=%08x/%08x, expected both at %08x as",
               got_addr[0], got_addr[1], got_data[0], got_data[1], pack_base + 32'h0000_3FFC);
      $display("     A55A0000 (the 0x3FFE byte, high half) then 00001234 (the 0x3FFC byte, low half)");
      errors = errors + 1;
    end

    // --- The FIRST ILLEGAL ADDRESS, at exactly the reserve bound. It must fail closed: no write at
    // all, load_error set, and rom_ready never published, because the CPU is released by rom_ready
    // and a bound this loader accepted is a pack it did not fully hold.
    accepted = 0;
    ioctl_download = 1;
    @(negedge clk);
    send_word(RESERVE, 16'hDEAD);
    ioctl_download = 0;
    repeat (8) @(posedge clk);

    if (!load_error) begin
      $display("FAIL reserve bound: load_error is clear after an address at exactly PACK_BYTES");
      errors = errors + 1;
    end
    if (rom_ready) begin
      $display("FAIL reserve bound: rom_ready published after a rejected address, so the CPU");
      $display("     would be released holding a pack the loader refused to complete");
      errors = errors + 1;
    end
    if (accepted != 0) begin
      $display("FAIL reserve bound: accepted=%0d writes at or above the reserve, expected 0",
               accepted);
      errors = errors + 1;
    end

    // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_PACK_BOUNDARY: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_PACK_BOUNDARY: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog, so a hang is a named failure rather than a runner timeout.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_PACK_BOUNDARY: FAIL (watchdog: the bench did not finish)");
  end

endmodule

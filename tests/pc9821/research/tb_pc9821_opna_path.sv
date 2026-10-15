`timescale 1ns/1ps

// tb_pc9821_opna_path - a THROWAWAY measurement bench (tests/pc9821/research/, NOT in the
// gate; see tests/pc9821/research/README.md). It does not assert a contract: it drives the
// real pc9821_opna with one steady source at a time and dumps the board's own snd_l as a
// (time, value) trace, one line per CHANGE, so a discontinuity in the synthesis path can be
// read off the samples rather than inferred from the code.
//
// The traces it writes:
//   opna_path_fm.txt      a single FM carrier held at a fixed pitch and full level (ALG 7)
//   opna_path_ssg.txt     one SSG tone channel at max level
//   opna_path_noise.txt   the SSG noise generator at max level (the fastest thing snd_l does)
//   opna_path_eg.txt      a keyed FM carrier with a MOVING envelope (the zipper test)
//   opna_path_rhythm.txt  one ADPCM-A instrument playing a constant-step ROM pattern
//   opna_path_all.txt     FM + SSG tone + one ADPCM-A drum at once
//
// The order matters: the ADPCM-A drum plays until its own end address, so the rhythm phases
// run LAST and the FM/SSG/EG traces are rhythm-free.
//
// The traces correspond to the task's stages 1/2/4/5: the FM operator path, the SSG sum, the
// ADPCM gain and the wrapper mix. It is deliberately NOT a gate bench: a human
// reads the numbers.
//
// Build: the command tests/pc9821/research/README.md shows for the SDRAM probe, with the OPNA
// source list and --top-module tb_pc9821_opna_path.

module tb_pc9821_opna_path;
  reg clk = 0;
  always #10 clk = ~clk;              // 20 ns = 50 MHz, the core's clk_sys

  reg reset = 1;
  reg [15:0] io_addr = 0;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;
  wire       io_rd_wait;
  reg        extend = 1;             // 0xA460 bit 0, set so the ext pair answers
  reg  [5:0] joystick = 6'b111111;
  wire signed [19:0] snd_l, snd_r;
  wire       irq;

  reg         rhythm_we = 1'b0;
  reg  [11:0] rhythm_waddr = 12'd0;
  reg  [15:0] rhythm_wdata = 16'd0;

  pc9821_opna #(.SYS_CLOCK_HZ(50_000_000)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .extend(extend),
    .joystick(joystick),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(rhythm_we), .rhythm_waddr(rhythm_waddr), .rhythm_wdata(rhythm_wdata)
  );

  integer ffm, fssg, fnoi, feg, frhy, fall;

  // ---- the write queue's own pacing: hold off until pc9821_opna's BUSY clears, exactly as
  // a driver's WAITREADY does. 0x188's bit 7 is the board's BUSY (chip + queue).
  task automatic busy_wait;
    integer guard;
    begin
      io_addr = 16'h0188; io_wr = 0; io_rd = 0;
      @(negedge clk);
      guard = 0;
      while (io_dout[7] && guard < 200000) begin
        @(negedge clk);
        guard = guard + 1;
      end
    end
  endtask

  // One host write. 0x188/0x18A select/data of the base bank; 0x18C/0x18E of the extended.
  task automatic opna_wr(input [15:0] portnum, input [7:0] data);
    begin
      busy_wait;
      @(negedge clk);
      io_addr = portnum; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      opna_wr(16'h0188, reg_index);
      opna_wr(16'h018A, data);
    end
  endtask

  // Dump snd_l over `cycles` clocks, one line per change: "<time> <value>".
  task automatic dump_l(input integer fd, input integer cycles);
    integer n;
    reg signed [15:0] prev;
    begin
      prev = snd_l;
      $fwrite(fd, "%0t %0d\n", $time, snd_l);
      for (n = 0; n < cycles; n = n + 1) begin
        @(posedge clk);
        if (snd_l !== prev) begin
          $fwrite(fd, "%0t %0d\n", $time, snd_l);
          prev = snd_l;
        end
      end
    end
  endtask

  integer n;

  initial begin
    // ---- reset, then let the OPNA's 16-clk&cen stretcher finish ----------------
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (4000) @(posedge clk);

    ffm  = $fopen("opna_path_fm.txt", "w");
    fssg = $fopen("opna_path_ssg.txt", "w");
    fnoi = $fopen("opna_path_noise.txt", "w");
    feg  = $fopen("opna_path_eg.txt", "w");
    frhy = $fopen("opna_path_rhythm.txt", "w");
    fall = $fopen("opna_path_all.txt", "w");

    // =================================================================
    // PHASE 1: one FM carrier, fixed pitch, full level, ALG 7 (op1 a carrier)
    // =================================================================
    sound_o(8'h28, 8'h00);   // key off
    sound_o(8'h30, 8'h01);   // DT=0 MUL=1
    sound_o(8'h40, 8'h00);   // TL=0
    sound_o(8'h50, 8'h1F);   // AR=31 (fast attack)
    sound_o(8'h60, 8'h00);   // DR=0
    sound_o(8'h70, 8'h00);   // SR=0
    sound_o(8'h80, 8'h0F);   // SL=0 RR=15
    sound_o(8'h90, 8'h00);   // SSG-EG off
    sound_o(8'hB0, 8'h07);   // ALG=7 FB=0
    sound_o(8'hB4, 8'hC0);   // L+R
    sound_o(8'hA4, 8'h22);   // block 4, fnum high (FIRST)
    sound_o(8'hA0, 8'h69);   // fnum low -> commits block+fnum
    sound_o(8'h28, 8'hF0);   // key on ch1, all four operators
    repeat (200000) @(posedge clk);
    dump_l(ffm, 400000);
    sound_o(8'h28, 8'h00);   // key off
    repeat (200000) @(posedge clk);

    // =================================================================
    // PHASE 2: one SSG tone channel at max level
    // =================================================================
    sound_o(8'h00, 8'h00);   // tone A period fine
    sound_o(8'h01, 8'h01);   // tone A period coarse
    sound_o(8'h07, 8'h3E);   // tone A on, B/C and all noise off
    sound_o(8'h08, 8'h0F);   // channel A level max
    repeat (50000) @(posedge clk);
    dump_l(fssg, 400000);
    sound_o(8'h08, 8'h00);
    sound_o(8'h07, 8'h3F);
    repeat (100000) @(posedge clk);

    // =================================================================
    // PHASE 3: the SSG NOISE generator at max level - the worst case for how fast snd_l
    // moves, which is what sizes the sample_86 crossing into the CLK_AUDIO domain. Register
    // 7 is active low: 0x07 = all three tones off, all three noises on; each level register
    // 0x0F = level 15 with no envelope.
    // =================================================================
    sound_o(8'h06, 8'h01);   // noise period (fast)
    sound_o(8'h07, 8'h07);   // all tones off, all noises on
    sound_o(8'h08, 8'h0F);   // A level max
    sound_o(8'h09, 8'h0F);
    sound_o(8'h0A, 8'h0F);
    repeat (50000) @(posedge clk);
    dump_l(fnoi, 400000);
    sound_o(8'h08, 8'h00);
    sound_o(8'h09, 8'h00);
    sound_o(8'h0A, 8'h00);
    sound_o(8'h07, 8'h3F);
    repeat (100000) @(posedge clk);

    // =================================================================
    // PHASE 4: one FM carrier with a MOVING envelope (DR/SR/RR set), the zipper-noise test
    // for stage 1's envelope generator. A wrong step size shows as a coarse staircase in
    // attenuation, not as a smooth exponential decay.
    // =================================================================
    sound_o(8'h28, 8'h00);
    sound_o(8'h40, 8'h00);   // TL=0
    sound_o(8'h50, 8'h14);   // AR=20
    sound_o(8'h60, 8'h0A);   // DR=10
    sound_o(8'h70, 8'h0A);   // SR=10
    sound_o(8'h80, 8'h4F);   // SL=4, RR=15
    sound_o(8'hA4, 8'h22);
    sound_o(8'hA0, 8'h69);
    sound_o(8'h28, 8'hF0);   // key on
    dump_l(feg, 2000000);    // ~40 ms, long enough for the decay to run
    sound_o(8'h28, 8'h00);
    repeat (200000) @(posedge clk);

    // =================================================================
    // PHASE 5: one ADPCM-A instrument (bass drum) on a constant-step ROM pattern.
    // Nibble 4 makes the decoder a near-constant ramp, so the board output should be a slow
    // monotone staircase plus the 12-bit accumulator wrap, not a spike train.
    // =================================================================
    for (n = 0; n < 4096; n = n + 1) begin
      @(negedge clk);
      rhythm_we = 1'b1;
      rhythm_waddr = n[11:0];
      rhythm_wdata = 16'h4444;
    end
    @(negedge clk);
    rhythm_we = 1'b0;

    sound_o(8'h11, 8'h3F);   // rhythm total level: no attenuation
    sound_o(8'h18, 8'hDF);   // instrument 0: level 31, both pans
    repeat (20000) @(posedge clk);
    sound_o(8'h10, 8'h01);   // trigger instrument 0
    dump_l(frhy, 400000);
    sound_o(8'h10, 8'h00);
    repeat (200000) @(posedge clk);

    // =================================================================
    // PHASE 6: ALL THREE at once (FM carrier + SSG tone + rhythm), the combination the
    // operator's "crackle" is heard in. Any clamp or discontinuity that only appears in
    // the sum is here.
    // =================================================================
    sound_o(8'h00, 8'h00);
    sound_o(8'h01, 8'h01);
    sound_o(8'h07, 8'h3E);   // SSG tone A on
    sound_o(8'h08, 8'h0F);
    sound_o(8'h11, 8'h3F);
    sound_o(8'h18, 8'hDF);
    sound_o(8'h40, 8'h00);
    sound_o(8'h50, 8'h1F);
    sound_o(8'h60, 8'h00);
    sound_o(8'h70, 8'h00);
    sound_o(8'h80, 8'h0F);
    sound_o(8'hA4, 8'h22);
    sound_o(8'hA0, 8'h69);
    sound_o(8'h28, 8'hF0);   // FM key on
    sound_o(8'h10, 8'h01);   // rhythm trigger
    repeat (100000) @(posedge clk);
    dump_l(fall, 600000);
    sound_o(8'h28, 8'h00);
    sound_o(8'h10, 8'h00);

    $fclose(ffm);
    $fclose(fssg);
    $fclose(fnoi);
    $fclose(feg);
    $fclose(frhy);
    $fclose(fall);
    $display("OPNA_PATH: traces written");
    $finish;
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_OPNA_PATH: TIMEOUT");
  end

endmodule

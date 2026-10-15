`timescale 1ns/1ps

// tb_pc9821_rhythm_probe - MEASUREMENT bench (not in the gate): dumps the ADPCM-A (RHYTHM)
// path's every 666 kHz slot so a discontinuity can be located, and so the decode can be
// checked against the references OFFLINE.
//
// WHY. The owner reports a pop/click on the rhythm channel only, before the CDC crossing.
// The three quantities that could carry it are dumped per cen6 (one line per 666 kHz slot):
//
//   dec  = the decoder's output (jt10_adpcm's `pcm`, the sign-extended 12-bit accumulator)
//   sum  = the six-drum sum (jt08_adpcm_acc's pcm_out, 20-bit)
//   fm   = the FM+ADPCM accumulator (jt08_acc's u_left.snd, 20-bit) - the pre-CDC node
//
// plus the counter/driver state (on1/on2, done1/done2, clr2/clr6, skip1/skip6, gate1/gate6,
// half1, sumup5/sumup6, addr1/addr6, aon/aoff, the aon/aoff shift registers, aon_cmd_cpy,
// decon, match) so an event can be traced to the bit that caused it.
//
// STIMULUS (the run that produced the .log beside this file): the 8 KiB ROM image is written
// through the pack-loader port as ALL ZEROS, which decodes to +2 per nibble - a PURE RAMP, so
// the decoder NEVER overloads and any step in the drum bus is a defect rather than the
// authentic 12-bit wrap (AUDIO_AUDIT.md RP-1). All six drums are then triggered at full level
// (0x11 = 0x3F total level, 0x18-0x1D = 0xDF per drum, 0x10 = 0x3F key-on) and the run
// continues for 80 ms, i.e. past the bass drum's and the snare's end-of-sample.
//
// WHAT IT SHOWED (AUDIO_AUDIT.md RP-2/RP-5): 1478 drum-bus updates, one per 36 cen6 (18.5 kHz),
// no falling step, largest step 96 LSB (the six drums' +15 LSB each per round), and the
// FM+ADPCM node holding exactly the drum bus (1479 updates against 1478, the extra being the
// power-up transient at cen 13).
//
// Build/run (see tests/pc9821/research/README.md for the pattern): the file list is every
// source in src/opna/opna.qip plus src/pc9821/common/pc9821_dpram.sv and this file, with
// --top-module tb_pc9821_rhythm_probe.

module tb_pc9821_rhythm_probe;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  reg clk = 0;
  always #10 clk = ~clk;          // 50 MHz

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  wire [7:0] io_dout;
  wire       io_rd_wait, irq;
  wire signed [19:0] snd_l, snd_r;
  reg  [5:0] joystick = 6'b111111;
  reg        rhythm_we = 0;
  reg [11:0] rhythm_waddr = 12'd0;
  reg [15:0] rhythm_wdata = 16'd0;

  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .extend(1'b0),
    .joystick(joystick),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(rhythm_we), .rhythm_waddr(rhythm_waddr), .rhythm_wdata(rhythm_wdata)
  );

  // ---- taps ----
  wire signed [15:0] pcmdec = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_decoder.pcm;
  wire signed [19:0] drumsum = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_acc_left.pcm_out;
  wire signed [19:0] fmplus = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_acc.u_left.snd;
  wire [13:0] ch0_addr = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.addr1;
  wire ch0_on = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.on1;
  wire ch0_done = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.done1;
  wire ch0_clr = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.clr1;
  // the six-drum round: channel 0's slot
  wire [5:0] cur_ch = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.cur_ch;
  wire [5:0] en_ch = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.en_ch;
  wire cen6 = dut.u_opna.u_jt08.u_jt12.clk_en_666;

  integer fd2;
  integer dumped = 0;
  integer ncen = 0;
  initial begin
    fd2 = $fopen("rhythm_cen.txt", "w");
  end

  // Every 666 kHz slot for the first 3000 slots: the counter's and driver's control state,
  // so an unexpected stop/restart can be traced to the bit that caused it.
  wire aon_c  = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.aon;
  wire aoff_c = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.aoff;
  wire on1_c  = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.on1;
  wire on2_c  = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.on2;
  wire done1_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.done1;
  wire done2_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.done2;
  wire clr2_c = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.clr2;
  wire clr6_c = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.clr6;
  wire skip1_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.skip1;
  wire skip6_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.skip6;
  wire gate1_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.gate1;
  wire gate6_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.gate6;
  wire half1_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.half1;
  wire sumup5_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.sumup5;
  wire sumup6_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.sumup6;
  wire [13:0] addr1_c = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.addr1;
  wire [13:0] addr6_c = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_cnt.addr6;
  wire [5:0]  sr_aon = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.aon_sr;
  wire [5:0]  sr_aoff= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.aoff_sr;
  wire [7:0]  cmd_cpy= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.aon_cmd_cpy;
  wire        decon_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.decon;
  wire        match_c= dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.match;
  always @(posedge clk) begin
    if (!reset && cen6 && (ncen < 60000)) begin
      $fwrite(fd2, "%0d ch=%02x aon=%b aoff=%b on1=%b on2=%b done1=%b done2=%b clr2=%b clr6=%b skip1=%b skip6=%b gate1=%b gate6=%b half1=%b sumup5=%b sumup6=%b addr1=%04x addr6=%04x sraon=%02x sraoff=%02x cmd=%02x decon=%b match=%b sum=%0d dec=%0d fm=%0d\n",
              ncen, cur_ch, aon_c, aoff_c, on1_c, on2_c, done1_c, done2_c, clr2_c, clr6_c,
              skip1_c, skip6_c, gate1_c, gate6_c, half1_c, sumup5_c, sumup6_c,
              addr1_c, addr6_c, sr_aon, sr_aoff, cmd_cpy, decon_c, match_c, drumsum, pcmdec, fmplus);
      ncen = ncen + 1;
    end
  end

  task automatic write_port(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk); io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk); io_wr = 0; io_din = 8'h00;
    end
  endtask

  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      write_port(16'h0188, reg_index);
      write_port(16'h018A, data);
    end
  endtask

  function automatic [7:0] rom_byte(input integer a);
    begin
      rom_byte = 8'h00;   // a pure +2-per-nibble ramp: NO overload, so any step in the drum bus is a defect
    end
  endfunction

  integer n;
  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2000) @(posedge clk);

    // The image: word W = bytes 2W (low) and 2W+1 (high), as the pack loader presents it.
    for (n = 0; n < 4096; n = n + 1) begin
      @(negedge clk);
      rhythm_we    = 1'b1;
      rhythm_waddr = n[11:0];
      rhythm_wdata = { rom_byte(2*n + 1), rom_byte(2*n) };
    end
    @(negedge clk);
    rhythm_we = 1'b0;
    repeat (100) @(posedge clk);

    // Full level on drum 0 (bass) and the total level, then trigger it.
    sound_o(8'h11, 8'h3F);             // total level
    repeat (2000) @(posedge clk);
    sound_o(8'h18, 8'hDF);             // drum 0: L+R pan, level 0 (max)
    repeat (2000) @(posedge clk);
    sound_o(8'h19, 8'hDF); repeat (2000) @(posedge clk);
    sound_o(8'h1A, 8'hDF); repeat (2000) @(posedge clk);
    sound_o(8'h1B, 8'hDF); repeat (2000) @(posedge clk);
    sound_o(8'h1C, 8'hDF); repeat (2000) @(posedge clk);
    sound_o(8'h1D, 8'hDF); repeat (2000) @(posedge clk);
    sound_o(8'h10, 8'h3F);             // trigger ALL SIX drums
    // 4 M cycles = 80 ms: the bass drum is 448 bytes = 896 nibbles = 48 ms, so the
    // natural end-of-sample is inside this window as well as the explicit key-off.
    repeat (4_000_000) @(posedge clk);
    $display("NOTE rhythm_probe: %0d cen6 slots dumped to rhythm_cen.txt", ncen);
    $finish;
  end
endmodule

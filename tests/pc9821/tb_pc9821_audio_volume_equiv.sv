// tb_pc9821_audio_volume_equiv - the ten-channel volume stage's area rewrite against its pre-rewrite text.
//
// ==== WHAT THIS PROVES ====
// The ten-channel volume stage's area rewrite (each consumed channel's product captured once per epoch into its own field instead of shifted through a ten-deep output chain, and the sample and volume selects built over the consumed channels only) delivers, on every valid strobe, the same samples_out fields as the pre-rewrite stage (pc9821_audio_volume_ref.sv, the module as of 3b134fe4) for every consumed channel, and the same valid strobe on every clock: over random 20-bit samples and random volume codes that change on EVERY clock (so the instants each channel is sampled at are pinned, not only the values), for the all-channels-consumed configuration (every field) and for the configuration z486_mister.sv instantiates (master, -86 and CD fields).
//
// ==== DUT ====
// pc9821_audio_volume (src/pc9821/audio/pc9821_audio_volume.sv) with USED all ones and with
// USED = 10'h3CC (channels 2, 3, 6, 7, 8, 9: cd_r/cd_l, snd86_r/l, master_r/l) vs
// pc9821_audio_volume_ref (tests/pc9821/pc9821_audio_volume_ref.sv), same inputs. The reference is
// the pre-change text, not a model of the hardware; the stage's law is pinned by
// tb_pc9821_audio_volume_table and tb_pc9821_audio_mix.
//
// ==== CHECKS ====
// CHK-1 valid equal on every clock, for both configurations.
// CHK-2 on every valid, every consumed field of samples_out equal (all ten, then the six).
// CHK-3 the run was not vacuous: many valid strobes, and the fields were not all equal to zero.
//
// ==== VERDICT ====
// PASS when no check differs; FAIL names the first differing clock.
//
`timescale 1ns/1ps
module tb_pc9821_audio_volume_equiv;
  localparam integer NUM_CH = 10, SW = 20;
  localparam integer CLOCKS = 400000;
  localparam [NUM_CH-1:0] USED6 = 10'h3CC;

  reg clk = 0;
  always #5 clk = ~clk;

  reg [NUM_CH*5-1:0]  vol = 0;
  reg [NUM_CH*SW-1:0] smp = 0;
  wire [NUM_CH*SW-1:0] o_ref, o_all, o_six;
  wire v_ref, v_all, v_six;

  pc9821_audio_volume_ref #(.NUM_CH(NUM_CH), .SAMPLE_WIDTH(SW)) ref0 (
    .clk(clk), .volumes_in(vol), .samples_in(smp), .samples_out(o_ref), .valid(v_ref));
  pc9821_audio_volume #(.NUM_CH(NUM_CH), .SAMPLE_WIDTH(SW)) dut_all (
    .clk(clk), .volumes_in(vol), .samples_in(smp), .samples_out(o_all), .valid(v_all));
  pc9821_audio_volume #(.NUM_CH(NUM_CH), .SAMPLE_WIDTH(SW), .USED(USED6)) dut_six (
    .clk(clk), .volumes_in(vol), .samples_in(smp), .samples_out(o_six), .valid(v_six));

  integer errors = 0, cyc = 0, n_valid = 0, n_nz = 0, k;
  reg [31:0] g = 32'hC0FFEE11;

  always @(posedge clk) begin
    cyc <= cyc + 1;
    g <= {g[30:0], g[31] ^ g[21] ^ g[1] ^ g[0]};
    // new inputs on every clock
    smp <= {g[19:0] ^ {cyc[7:0], 12'h0}, ~g[19:0], g[15:0] * 20'd7, {4{g[7]}}, g[15:0],
            g[11:0] ^ 12'hABC, 8'h0, g[31:20], g[23:4], 20'sh7FFFF, 20'sh80000, ~g[27:8]};
    vol <= {g[4:0], g[9:5], g[14:10], g[19:15], g[24:20], g[29:25], g[3:0], g[8], g[13:9], g[18:14]}
           ^ {(NUM_CH*5){cyc[9]}} ^ {NUM_CH{cyc[4:0]}};
    if (v_all !== v_ref || v_six !== v_ref) begin
      errors = errors + 1;
      if (errors <= 10) $display("FAIL CHK-1 clk %0d: valid differs", cyc);
    end
    if (v_ref) begin
      n_valid = n_valid + 1;
      for (k = 0; k < NUM_CH; k = k + 1) begin
        if (o_all[k*SW +: SW] !== o_ref[k*SW +: SW]) begin
          errors = errors + 1;
          if (errors <= 10) $display("FAIL CHK-2 clk %0d: all-channels field %0d differs", cyc, k);
        end
        if (USED6[k] && o_six[k*SW +: SW] !== o_ref[k*SW +: SW]) begin
          errors = errors + 1;
          if (errors <= 10) $display("FAIL CHK-2 clk %0d: z486_mister configuration field %0d differs", cyc, k);
        end
        if (o_ref[k*SW +: SW] != 0) n_nz = n_nz + 1;
      end
    end
  end

  initial begin
    repeat (CLOCKS) @(posedge clk);
    if (n_valid < CLOCKS / NUM_CH - 5) begin errors = errors + 1; $display("FAIL CHK-3 only %0d valid strobes", n_valid); end
    if (n_nz < n_valid) begin errors = errors + 1; $display("FAIL CHK-3 the fields were mostly zero (%0d)", n_nz); end
    if (errors == 0) begin
      $display("TB_PC9821_AUDIO_VOLUME_EQUIV: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_AUDIO_VOLUME_EQUIV: FAIL (%0d errors)", errors);
  end

  initial begin
    #(10 * (CLOCKS + 1000));
    $fatal(1, "TB_PC9821_AUDIO_VOLUME_EQUIV: TIMEOUT");
  end
endmodule

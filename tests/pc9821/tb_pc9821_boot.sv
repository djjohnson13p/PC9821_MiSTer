`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_BOOT:
  // The diagnostic pack boots through the real CPU, memory and I/O path and reaches its own result marker. The cycle count is ASSERTED, not printed: the real backend must reach the marker at exactly 930544 clk_sys (or 875223 with the deliberately-selected +FAST_MEM stub), so a timing regression fails the tier instead of moving a line nothing reads (r13/333 finding 5). REGRESSION PIN, NOT CONFORMANCE: the two counts are tripwires fitted to this tree's own runs - non-regression evidence, never correctness evidence - and a DELIBERATE timing change is blessed by re-running with +REBASE_CYCLES (which prints the new measured count instead of asserting the old one) and editing the two constants once in the same change, so a timing change cannot be laundered through by re-measuring silently (review benches N9).


module tb_pc9821_boot;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  // Counted so the PASS line can state how much of the 20,000,000-cycle bound this
  // tier actually uses. Real backend timing makes every transaction several cycles
  // longer than the instantaneous stub did, so the margin is worth printing rather
  // than discovering when the next change is added.
  integer tb_cycles = 0;
  always @(posedge clk_sys) tb_cycles = tb_cycles + 1;
  // r13/333 finding 5: the boot's deterministic cycle count IS the regression guard. The
  // production tier (real backend, no plusargs -- what run_boot.sh and gate.py boot) reaches
  // its own result marker at exactly BOOT_CYCLES_REAL clk_sys; the deliberately-selected
  // +FAST_MEM immediate stub (see the BACKEND block) reaches it at BOOT_CYCLES_FAST. Both are
  // asserted where the count is reported below, so a timing change of ANY size is a fatal
  // failure rather than a printed note the gate never reads. Each number was MEASURED on this
    // tree, not chosen. The current pair (930544 / 875223) includes post.s's explicit GDT/IDT
    // initialization, which retimed the boot by +12 / +5 when it made the triple-fault stage
    // independent of low-RAM power-up state (boot-firmware review F6); moving it again means
    // re-measuring and moving the literal in tests/pc9821/run_boot.sh and the docs with it.
    //
    // RE-PINNED 2026-10-11 930530 -> 930544 / 875207 -> 875223 at the OWNER'S instruction: all +14 / +16
    // from the z486 fork's fac8d54 (specdev: a speculative branch-target fetch never reads non-cacheable
    // memory, so the boot's BIOS-ROM branch targets are fetched on demand); bisected per fork commit,
    // Dhrystone unchanged. Measured with +REBASE_CYCLES.
    //
    // RE-PINNED 2026-10-05 930535 -> 930530 / 875223 -> 875207 at the OWNER'S instruction.
    // ATTRIBUTION IS A GROUP, NOT A CHANGE: the move predates the memory-window fix (which
    // cannot affect this tier - it boots ram_size 32 MiB, where the retired device window's
    // range was already uncached), and it accumulated across the recent z486 revendors and
    // rebuilds without anyone re-running this tier. Both counts were MEASURED with
    // +REBASE_CYCLES, not extrapolated.
    //
    // REGRESSION PIN, NOT CONFORMANCE (review benches N9): nothing external validates
    // these magnitudes - they are tripwires against UNINTENDED timing moves, not machine
    // conformance claims. The blessed-update mechanism is +REBASE_CYCLES: run the tier
    // with it once after a DELIBERATE timing change, take the printed measured count,
    // and edit these two constants in the same change (the run then passes on the new
    // count; without the plusarg every count move stays fatal).
    localparam integer BOOT_CYCLES_REAL = 930544;
    localparam integer BOOT_CYCLES_FAST = 875223;
    reg rebase_cycles = 1'b0;
  reg reset = 1;
  reg hps_apply_reset = 0;
  // Fixed BCD RTC (2026-09-12 12:34:56, Friday) so the calendar path is
  // deterministic: {weekday, year, month, day, hour, minute, second}.
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;

  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait;

  wire [31:0] ext_mem0_addr, ext_mem0_din;
  wire [31:0] ext_mem0_dout;
  wire [3:0] ext_mem0_be;
  wire [7:0] ext_mem0_burstcount;
  wire ext_mem0_valid, ext_mem0_write;
  wire ext_mem0_ready;
  wire ext_mem0_resp_valid;
  // 0 (the default): the REAL backend timing. 1: the immediate stub this tier used
  // to hard-wire, reachable deliberately with +FAST_MEM. See the BACKEND block.
  reg  fast_mem = 1'b0;

  wire [7:0] debug_post_code;
  wire debug_post_write, debug_bios_loaded;
  wire [15:0] cpu_cs;
  wire [31:0] cpu_eip, cpu_cs_base;
  wire [7:0] video_r, video_g, video_b;
  wire video_ce, video_blank_n, video_hsync, video_vsync;

  // ---- the `out 0xF0` CPU-mode reset, measured where the CPU sees it --------
  // The contract: after `out 0xF0,0` the CPU resets, and its FIRST fetch is the
  // reset vector of the window mapped at that moment. z486's `addr`/`valid`/
  // `io` outputs are the CPU-side physical bus, so the first non-I/O read after
  // the CPU actually LEAVES reset is the measurement: the PC-98 A20 gate clears
  // bit 20 only (Xe10 A20MAP), so it is 0xFFEF_FFF0, which the platform serves
  // from the BIOS window (this pack's offset 0x7FF0, `ljmp 0xF800, start`), and
  // the CS then changes to F800 so the payload re-runs.
  //
  // Latching on "any non-I/O read after the request" is the wrong event class:
  // the payload's own tail fetch (the `hlt` at F800:0x7x) is a non-I/O read
  // that happens BEFORE the CPU leaves reset, so a future run could satisfy the
  // assertion on that address instead of the vector. The gate below is the
  // system's reset hold: pc9821_system drives z486's reset_n from
  // pc9821_cpu_reset_gate, so its hold reaching 0 after the request is the exact
  // instant the CPU comes out of reset.
  wire cpu_reset_req = dut.cpu_reset_req;
  // The CPU's own SHUTDOWN request (z486's triple-fault reset), which the
  // diagnostic pack raises once at the top of its POST. It must be consumed
  // INSIDE the core: with it raised, the CPU must restart with no stimulus
  // from this bench at all (no `reset`, no `hps_apply_reset`). Before r12/12 it
  // left the core as BUTTONS[1] and came back only through the HPS.
  wire soft_reset_req = dut.software_reset;
  reg  soft_reset_seen = 1'b0;
  integer soft_reset_wait = 0;
  reg  reset_req_seen = 1'b0;
  reg  reset_released = 1'b0;
  reg  post_reset_read_seen = 1'b0;
  reg [31:0] post_reset_read_addr = 32'h0000_0000;
  reg [15:0] post_reset_read_cs   = 16'h0000;
  reg  reset_vector_cs_seen = 1'b0;
  reg [7:0]  post_10_count = 8'd0;
  reg  post_reset_returned = 1'b0;
  always @(posedge clk_sys) begin
    if (cpu_reset_req) reset_req_seen <= 1'b1;
    if (soft_reset_req) soft_reset_seen <= 1'b1;
    // The shutdown must be consumed locally. If the request is raised and the
    // CPU-reset hold is never re-armed, the request went nowhere -- the r11/14
    // defect, where it left as BUTTONS[1] and only came back through the HPS.
    // Bounded so the regression names itself instead of timing out the bench.
    if (soft_reset_seen && !reset_released) begin
      soft_reset_wait = soft_reset_wait + 1;
      if (soft_reset_wait > 100_000)
        $fatal(1, "the CPU's shutdown did not reset the CPU: software_reset pulsed but the reset gate hold never re-armed");
    end
    if (reset_req_seen && (dut.cpu_reset_gate.hold == 4'd0)) reset_released <= 1'b1;
    if (reset_released && !post_reset_read_seen &&
        dut.z_valid && !dut.z_io && !dut.z_write) begin
      post_reset_read_seen <= 1'b1;
      post_reset_read_addr <= {dut.z_addr, 2'b00};
      post_reset_read_cs   <= cpu_cs;
      $display("POSTRESETFETCH cyc=%0d addr=%08x cs=%04x eip=%08x top_bank=%0d a20=%0d",
               $time, {dut.z_addr, 2'b00}, cpu_cs, cpu_eip,
               dut.iobus.top_bank, dut.iobus.a20_enable);
      // The CPU-mode reset leaves A20 masked, and the PC-98 gate clears physical
      // bit 20 only (Xe10 A20MAP: BIT20-ONLY, docs/probes/A20MAP-XE10.TXT), so
      // the reset fetch goes out at FFEFFFF0; the platform answers it from the
      // BIOS through the FFEE8000-FFEFFFFF window (MAME pc9821.cpp:688-689).
      // Tripped HERE so a wrong address reports this contract, not a bare
      // boot timeout.
      if ({dut.z_addr, 2'b00} !== 32'hFFEF_FFF0)
        $fatal(1, "the first fetch after the CPU-mode reset was not the bit-20-masked reset vector: addr=%08x (bit-20 clear gives ffeffff0, a 1 MiB wrap gives 000ffff0)",
               {dut.z_addr, 2'b00});
    end
    // The vector's `ljmp 0xF800,start` must land the CPU on the firmware bank:
    // only reachable after the reset fetch above, because the reset state's CS
    // is F000.
    if (post_reset_read_seen && (cpu_cs == 16'hF800)) reset_vector_cs_seen <= 1'b1;
    if (debug_post_write) begin
      if (debug_post_code == 8'h10) post_10_count <= post_10_count + 8'd1;
      if (debug_post_code == 8'h70) post_reset_returned <= 1'b1;
    end
  end

  // Pixels the framework would see. Reported: nothing has checked that this core emits a
  // non-zero pixel, and four scanout defects once left TRAM correct with a black screen.
  integer nonblack = 0;
  always @(posedge clk_sys)
    if (video_ce && video_blank_n && (video_r || video_g || video_b))
      nonblack <= nonblack + 1;

  reg [15:0] pack_words [0:17'h187ff];
  // The backend's storage lives in sdram_backend_model now. WORDS_LOG2 = 24 covers
  // the 34 MB this tier uses -- 32 MiB of guest RAM, the pack at pack_base, then
  // GVRAM above that -- so 2**24 words is 64 MB and nothing aliases. The array this
  // replaced held 2**23 words, one word short of the pack at 32 MiB, so addr[24:2]
  // dropped the bit that placed it and the pack aliased onto address 0.
  localparam integer BACKEND_WORDS_LOG2 = 24;
  // The OSD guest RAM size, as pc9821_system.sv codes it: log2(MiB), so 3'd5 is
  // 32 MiB, the size this bench's pack and checks assume. ram_size_max is the
  // installed module's ceiling and is where the pack is placed (r13/47): this bench
  // models a 64 MB module whose ceiling is this same 32 MiB, so the pack base is
  // unchanged from before the split and only the guest size moves below it.
  reg [2:0] ram_size = 3'd5;
  reg [2:0] ram_size_max = 3'd5;
  reg [31:0] pack_base_after_load;

  // The BIOS set: 0 = PC-9821Xe10 (the measured strap, this bench's pack), 1 = Xe.
  reg [3:0] bios_set = 4'd0;

  pc9821_system #(
      .SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4),
      .ENABLE_X87(1'b0),
      // The shipped configuration: the CD-ROM drive (with CD-DA) on bank 1's master, no disc mounted
      // (build_profile.py's default since cd-default; owner 2026-10-10: the golden boots the CD build).
      .CDROM_EN(1'b1), .CDROM_AUDIO_EN(1'b1)
  // ==== DUT ====
  ) dut (
      // Video runs on the dot clock; the bench drives it at clk_sys with
      // The dot rate is an enable on clk_sys inside the system, so
      // there is no separate video clock to drive here.
      .clk_sys(clk_sys),
      .reset(reset), .hps_apply_reset(hps_apply_reset),
      .rtc(rtc),
      .ext_mem_busy(1'b0),
      .ext_mem0_addr(ext_mem0_addr), .ext_mem0_din(ext_mem0_din),
      .ext_mem0_dout(ext_mem0_dout),
      .ext_mem0_resp_valid(ext_mem0_resp_valid),
      .ext_mem0_be(ext_mem0_be), .ext_mem0_burstcount(ext_mem0_burstcount),
      .ext_mem0_ready(ext_mem0_ready),
      .ext_mem0_valid(ext_mem0_valid), .ext_mem0_write(ext_mem0_write),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
      .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
      .ps2_key(11'd0), .ram_size(ram_size),
      .bios_set(bios_set),
      .ram_size_max(ram_size_max),
      // 5 MHz: this bench boots the real firmware and so must not change the display's
      // GDC line step. The strap decode and the step have their own benches.
      .bios_setup(1'b0),
      // The debug UART FIFO and its accept handshake live in the top level (z486_mister.sv),
      // which this tier does not build - and nothing here reads dbg_uart_byte either. Tying
      // accept high lets the report emitter free-run at one byte per clk_sys, which is the
      // stream the pre-r13/326 logic produced and leaves the boot result unchanged.
      .dbg_uart_accept(1'b1),
      .trace_trig(),
      .debug_post_code(debug_post_code), .debug_post_write(debug_post_write),
      .debug_bios_loaded(debug_bios_loaded), .cpu_cs(cpu_cs),
      .cpu_eip(cpu_eip), .cpu_cs_base(cpu_cs_base),
      .video_ce(video_ce), .video_blank_n(video_blank_n),
      .video_hsync(video_hsync), .video_vsync(video_vsync),
      .video_r(video_r), .video_g(video_g), .video_b(video_b)
  );

  // ==== BACKEND ====
  // This tier used to answer the CPU ITSELF: `ext_mem0_ready` hard-wired to 1'b1
  // and a response registered for the next cycle, so every access completed one
  // cycle after it was asked. That is not the machine. src/memory/sdram.v accepts
  // ONE request at a time and only in IDLE (sdram.v:359-379), and answers a
  // single-word read SIX cycles later -- measured, not read off a comment, by
  // tests/pc9821/tb_pc9821_sdram.sv, which prints "a 1-word read was answered 6
  // cycles after the accept". A backend that answers in one cycle cannot exhibit a
  // defect that depends on WHEN the answer arrives, and the route-isolation
  // regression was exactly that: an ownership record held for one cycle while the
  // backend answered several later. It passed every bench in this tree and was
  // found on hardware.
  //
  // So the backend is sdram_backend_model, the shared model
  // tb_pc9821_gvram_fill uses, and this tier runs against REAL timing by default.
  // ACCEPT_TO_RESP is stated here rather than left to the model's default because
  // the default is the model's business and this contract is the tier's. The value
  // is not a guess: that parameter sets the model's host-side latency -- cycles
  // from seeing `ready` to seeing `resp_valid` -- and it was MEASURED at 1, 3, 4,
  // 5, 6, 7, 8, 9 for parameters 0..7, so 4 produces exactly the controller's six,
  // and 0 produces one, which is the stub this replaced. REGRESSION PIN, NOT
  // CONFORMANCE (review benches N9): 4 is fitted to the controller's own six, not
  // to a measured HPS/host-bridge round trip (the lost-week class that was found on
  // hardware is the measurement still owed here); to sweep the legal host latencies
  // deliberately, edit the parameter below across 0..7 with +REBASE_CYCLES and
  // require the guest-visible handshake contract (the marker is REACHED, no wedge)
  // to hold across the whole sweep - only the exact cycle pin is 4-specific.
  //
  // Both instances are driven by the same signals, so whichever is selected sees
  // every access and the two stores stay identical; the mux picks whose handshake
  // the DUT talks to. The 128-bit line form has no producer in the design (cache
  // fills complete as burstcount==4 word responses), so the model's line outputs
  // are left open.
  wire         fast_ready, fast_resp_valid;
  wire [31:0]  fast_dout;
  wire         slow_ready, slow_resp_valid;
  wire [31:0]  slow_dout;

  assign ext_mem0_ready           = fast_mem ? fast_ready           : slow_ready;
  assign ext_mem0_dout            = fast_mem ? fast_dout            : slow_dout;
  assign ext_mem0_resp_valid      = fast_mem ? fast_resp_valid      : slow_resp_valid;

  sdram_backend_model #(
      .ACCEPT_TO_RESP(0), .WRITE_BUSY(0), .LINE_RESP(0),
      .WORDS_LOG2(BACKEND_WORDS_LOG2)
  ) u_mem_fast (
      .clk(clk_sys), .reset(reset),
      .valid(ext_mem0_valid), .ready(fast_ready), .write(ext_mem0_write),
      .addr(ext_mem0_addr), .din(ext_mem0_din), .din_hi(32'd0), .be(ext_mem0_be),
      .burstcount(ext_mem0_burstcount),
      .dout(fast_dout), .resp_valid(fast_resp_valid),
      .busy(), .accepts(), .beats()
  );

  sdram_backend_model #(
      .ACCEPT_TO_RESP(4), .WRITE_BUSY(3), .LINE_RESP(0),
      .WORDS_LOG2(BACKEND_WORDS_LOG2)
  ) u_mem_slow (
      .clk(clk_sys), .reset(reset),
      .valid(ext_mem0_valid), .ready(slow_ready), .write(ext_mem0_write),
      .addr(ext_mem0_addr), .din(ext_mem0_din), .din_hi(32'd0), .be(ext_mem0_be),
      .burstcount(ext_mem0_burstcount),
      .dout(slow_dout), .resp_valid(slow_resp_valid),
      .busy(), .accepts(), .beats()
  );
  // ==== STIMULUS ====

  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk_sys);
      ioctl_addr = addr;
      ioctl_dout = data;
      ioctl_wr = 1;
      @(negedge clk_sys);
      ioctl_wr = 0;
    end
  endtask

  integer i;
  integer post_count = 0;
  reg reached_done = 0;
  reg irq_ok = 0;
  always @(posedge clk_sys) if (debug_post_write) begin
    $display("POST %02x CS:EIP=%04x:%08x", debug_post_code, cpu_cs, cpu_eip);
    post_count = post_count + 1;
    // 0x5A is the TRAM banner, 0x60 is the VSYNC interrupt self-test passing
    // (the Touhou games' INT 0Ah dance: arm 64h, take IRQ2, EOI 00h, re-arm).
    if (debug_post_code == 8'h5A) reached_done = 1;
    if (debug_post_code == 8'h60) irq_ok = 1;
    if (debug_post_code == 8'hE1)
      $fatal(1, "diagnostic RAM test failed");
    if (debug_post_code == 8'hE2)
      $fatal(1, "VSYNC interrupt never reached the CPU: the PIC did not " +
                "deliver IRQ2 to vector 0Ah");
    // NOTE: one literal per $fatal, not `".." + ".."`: concatenating literals
    // with `+` makes Verilator print the message as a huge decimal integer
    // (measured on the 0xE4 path), which is useless in a failure log.
    if (debug_post_code == 8'hE3)
      $fatal(1, "A20 masked did not alias 1 MiB onto physical 0 (the ITF's own BANK4@0xF8358 check)");
    if (debug_post_code == 8'hE5)
      $fatal(1, "0x9894 bit 3 set after out 0xF0,0: the ITF's 0xFCAED gate would divert");
    if (debug_post_code == 8'hE6)
      $fatal(1, "the CPU's shutdown left it running: the triple-fault reset was not consumed locally");
  end
  // ==== CHECKS ====

  initial begin
    // +FAST_MEM restores the old stub deliberately, so the same stimulus can be run
    // both ways. The default is the realistic backend.
    if ($test$plusargs("FAST_MEM")) fast_mem = 1'b1;
    if ($test$plusargs("REBASE_CYCLES")) rebase_cycles = 1'b1;
    $readmemh("diagnostic_pack.mem", pack_words);
    repeat (10) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;
    // The OSD RAM size is a CONFIG-TIME setting. pc9821_system samples it while the
    // loader has not published rom_ready -- the pack is written to pack_base ==
    // guest_ram_bytes, so the size has to be the one the pack was placed at -- and
    // freezes it there. Both halves are asserted here: before the download the
    // register follows the OSD, and after the load a change is refused.
    ram_size = 3'd2;                       // 4 MiB
    repeat (4) @(posedge clk_sys);
    if (dut.guest_ram_bytes !== 32'h0040_0000)
      $fatal(1, "the OSD RAM size was not taken before the pack load: guest_ram_bytes=%08x",
             dut.guest_ram_bytes);
    ram_size = 3'd5;                       // 32 MiB, the size this bench boots
    repeat (4) @(posedge clk_sys);
    if (dut.guest_ram_bytes !== 32'h0200_0000)
      $fatal(1, "the OSD RAM size did not follow the selection: guest_ram_bytes=%08x",
             dut.guest_ram_bytes);
    ioctl_download = 1;

    for (i = 0; i < 16'h4000; i = i + 1)
      send_word(i * 2, pack_words[i]);
    for (i = 0; i < 2048; i = i + 1)
      send_word(27'h0030000 + i * 2, pack_words[17'h18000 + i]);

    ioctl_download = 0;
    // Bounded wait. The cycle bound in this bench sits AFTER this point, so a bare
    // wait here is unbounded: a pack/loader regression would hang until the runner's
    // wall clock (30 minutes) instead of failing in seconds with a name. Poll with a
    // bound, the same idiom the other benches use for device handshakes.
    begin : wait_for_pack
      integer pack_poll = 0;
      while (!debug_bios_loaded && pack_poll < 2_000_000) begin
        @(posedge clk_sys);
        pack_poll = pack_poll + 1;
      end
      if (!debug_bios_loaded)
        $fatal(1, "the ROM pack was never loaded (2M cycles)");
    end
    // The pack is placed at the MODULE CEILING (ram_size_max), not at the selected
    // guest size (r13/47), so a post-load OSD change leaves the pack exactly where it
    // is. Record the fixed base; the warm-reset phase at the end of this branch
    // asserts it does not move and that the pack's SDRAM bytes are unchanged.
    pack_base_after_load = dut.pack_base;
    if (pack_base_after_load !== 32'h0200_0000)
      $fatal(1, "the pack was not placed at the module ceiling: pack_base=%08x", pack_base_after_load);
    $display("RAM SIZE pack base is the module ceiling: pack_base=%08x (the guest size may change below it)",
             pack_base_after_load);
    ram_size = 3'd5;

    fork
      begin
        wait (reached_done);
        // The interrupt self-test runs after the banner, so wait for it rather
        // than sampling a fixed number of cycles later. The overall timeout in
        // the sibling branch bounds the wait.
        wait (irq_ok);
        repeat (20) @(posedge clk_sys);
        // Read straight out of the backend model's store, the same way this tier
        // already reads the TRAM below it: either instance holds the same bytes,
        // because both are driven by every access.
        if (u_mem_slow.mem[24'h000400 >> 2] !== 32'h5A3C0BAD)
          $fatal(1, "low RAM signature mismatch: %08x", u_mem_slow.mem[24'h100]);
        if (dut.u_crtc.u_text_mem.u_tram.ram[0] !== 8'h5A ||
            dut.u_crtc.u_text_mem.u_tram.ram[1] !== 8'h00 ||
            dut.u_crtc.u_text_mem.u_tram.ram[14'h2000] !== 8'hE1)
          $fatal(1, "TRAM banner signature mismatch");
        // The machine's battery-backed memory switches sit at 0xA3FE2 + i*4 in
        // the tail of text VRAM -- measured on a real PC-9821Xe10 and the model
        // NP2kai uses. Firmware that validates them (the authentic NEC ITF)
        // refuses to boot without them, so their presence is part of the boot
        // contract, not an implementation detail.
        if (dut.u_crtc.u_text_mem.u_tram.ram[14'h3FE2] !== 8'h48 ||
            dut.u_crtc.u_text_mem.u_tram.ram[14'h3FE6] !== 8'h05 ||
            dut.u_crtc.u_text_mem.u_tram.ram[14'h3FEA] !== 8'h0c ||
            dut.u_crtc.u_text_mem.u_tram.ram[14'h3FEE] !== 8'h00 ||
            dut.u_crtc.u_text_mem.u_tram.ram[14'h3FF2] !== 8'h01 ||
            dut.u_crtc.u_text_mem.u_tram.ram[14'h3FFE] !== 8'h81)
          $fatal(1, "memory switches missing from the text VRAM tail");
        if (post_count < 4) $fatal(1, "missing POST milestones");
        // The shutdown phase ran and the CPU was reset by it: the request was
        // raised, and the reset-vector fetch below is the proof the platform
        // consumed it with no external stimulus.
        if (!soft_reset_seen)
          $fatal(1, "the pack's shutdown phase never raised the CPU's triple-fault request");
        $display("SHUTDOWN-CONSUMED software_reset pulsed; the CPU restarted locally");
        // The masked reset's own assertion, on the event the contract is about. The
        // reset-vector FETCH is checked the cycle it appears (see the always
        // block above); here the follow-through: it is fetched with the reset
        // CS F000, and the vector's ljmp must then change CS to F800.
        if (post_reset_read_cs != 16'hF000)
          $fatal(1, "the reset vector was fetched with CS=%04x, not the reset CS F000",
                 post_reset_read_cs);
        if (!reset_vector_cs_seen)
          $fatal(1, "the reset vector's ljmp did not change CS to F800: the CPU did not re-enter the pack");
        $display("POST-RESET FETCH addr=%08x cs=%04x -> CS=F800 (the masked reset vector re-entered the pack)",
                 post_reset_read_addr, post_reset_read_cs);
  // ==== VERDICT ====
        if (!irq_ok)
          $fatal(1, "the interrupt self-test never passed (no POST 60)");
        // The dead evidence channel the boot-firmware review found: POST 0x10 is emitted exactly
        // twice per boot - once after the triple-fault re-entry and once after the `out 0xF0`
        // re-entry (post.s emits it right after tf_once_done, which both re-entries pass) - and
        // it was counted but never asserted, so a regression that skipped one re-entry's marker
        // would pass. Assert the count.
        if (post_10_count !== 8'd2)
          $fatal(1, "POST 0x10 was emitted %0d times, want exactly 2 (after the triple-fault re-entry and after the out 0xF0 re-entry)",
                 post_10_count);
        $display("POST10 count=%0d (the triple-fault and out-0xF0 re-entries each emitted one)",
                 post_10_count);
        // The old video_off / FB_FORCE_BLANK port is gone with the ao486 framebuffer shell;
        // z486_mister.sv now ties FB_FORCE_BLANK = 1'b0, so there is nothing to assert here.
        $display("CYCLES used=%0d of 20000000 (%0d%% of the bound), backend=%s",
                 tb_cycles, tb_cycles / 200_000, fast_mem ? "FAST_MEM stub" : "real timing");
        // r13/333 finding 5: the exact comparison the tier was missing. Displaying the count
        // let a timing regression move the boot by any amount under the 20M-cycle timeout and
        // stay green; this makes the production count (and the +FAST_MEM alternative) fatal.
        // +REBASE_CYCLES is the BLESSED-UPDATE escape (review benches N9): a deliberate
        // timing change runs once with it, takes the printed measured count into the two
        // constants in the same change, and every OTHER run keeps the exact pin.
        if (rebase_cycles) begin
          $display("REBASE_CYCLES: measured %0d (%s) - bless by editing BOOT_CYCLES_%s to this value in the same change",
                   tb_cycles, fast_mem ? "FAST_MEM stub" : "real timing", fast_mem ? "FAST" : "REAL");
        end else if (fast_mem) begin
          if (tb_cycles !== BOOT_CYCLES_FAST)
            $fatal(1, "CYCLES used=%0d: the +FAST_MEM immediate-stub boot must be exactly %0d",
                   tb_cycles, BOOT_CYCLES_FAST);
          $display("CYCLES ASSERTED: the +FAST_MEM immediate-stub boot is exactly %0d clk_sys (deliberate alternative; the production path is %0d)",
                   BOOT_CYCLES_FAST, BOOT_CYCLES_REAL);
        end else begin
          if (tb_cycles !== BOOT_CYCLES_REAL)
            $fatal(1, "CYCLES used=%0d: the real-backend boot must be exactly %0d (a timing regression moved it)",
                   tb_cycles, BOOT_CYCLES_REAL);
          $display("CYCLES ASSERTED: the real-backend boot is exactly %0d clk_sys",
                   BOOT_CYCLES_REAL);
        end
        $display("VIDEO nonblack_pixels=%0d", nonblack);
        // ==== the OSD RAM size re-applies on a WARM (OSD) RESET ====
        // r13/47: an OSD Reset IS a platform reset. The guest size must follow the OSD
        // selection on that reset -- it no longer waits for a core reload -- while
        // pack_base must NOT move, because the pack is already in SDRAM and the HPS
        // does not re-send it. The pack dword read back at the fixed base before and
        // after is the "still readable" half: the bytes did not move.
        begin : ram_size_warm_reset
          reg [31:0] pack_word_before, pack_word_after;
          pack_word_before = u_mem_slow.mem[pack_base_after_load >> 2];
          ram_size = 3'd4;                       // 16 MiB, down from the 32 this run boots
          reset = 1;
          repeat (4) @(posedge clk_sys);
          reset = 0;
          repeat (4) @(posedge clk_sys);
          if (dut.cfg_ram_mib !== 7'd16)
            $fatal(1, "the OSD RAM size did not re-derive on the reset: cfg_ram_mib=%0d",
                   dut.cfg_ram_mib);
          if (dut.guest_ram_bytes !== 32'h0100_0000)
            $fatal(1, "guest_ram_bytes did not follow the OSD on the reset: %08x",
                   dut.guest_ram_bytes);
          if (dut.pack_base !== pack_base_after_load)
            $fatal(1, "the warm reset moved the pack: pack_base %08x -> %08x",
                   pack_base_after_load, dut.pack_base);
          pack_word_after = u_mem_slow.mem[pack_base_after_load >> 2];
          if (pack_word_after !== pack_word_before)
            $fatal(1, "the pack at the fixed base changed across the reset: %08x -> %08x",
                   pack_word_before, pack_word_after);
          $display("RAM SIZE re-derived on a warm reset: cfg_ram_mib=%0d guest=%08x pack_base=%08x (fixed, pack dword %08x readable)",
                   dut.cfg_ram_mib, dut.guest_ram_bytes, dut.pack_base, pack_word_after);
        end
        $display("TB_PC9821_BOOT: PASS");
        $finish;
      end
      begin
        repeat (20_000_000) @(posedge clk_sys);
        $fatal(1, "boot timeout CS:EIP=%04x:%08x", cpu_cs, cpu_eip);
      end
    join
  end

endmodule

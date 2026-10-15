`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMA_FLUSH_COHERENCY: a floppy sector the real FDC and uPD71071 DMA write into a buffer the CPU has already cached is visible on the CPU's next read - every DMA-side completion (the block's memory-side terminal count, and the FDC's result drain for the EOT end that never reaches one) requests one whole-L1 cache_flush, and the re-fetch returns the sector's own bytes where an unflushed read returns the stale cached dword. A real 486 snoops EADS# per external write and software does not flush after a floppy DMA, so without the trigger the disk buffer is stale (memmap-audit ramroute P1-1).
//
// WHY THIS EXISTS (the audit's P1-1). The DMA writes SDRAM behind the CPU's back
// and nothing invalidated the L1: the only cache_flush triggers were the iobus's
// mapping changes and 0x043F=0xA0, and pc9821_system ties the z486's snoop port
// off (.snoop_addr(32'd0), .snoop_valid(1'b0) - "no DMA snoop on this platform").
// Software does not flush after a floppy DMA, so a disk buffer the CPU had read or
// executed came back stale. The fix's two completion events are tested here against
// the REAL chain end to end:
//   * the TC end - the uPD71071's memory-side terminal count (pc9821_dmac's
//     mem_tc), which fires only after the block's LAST byte has been accepted;
//   * the EOT end - the FDC's command-result drain (pc9821_fdc's res_done), for a
//     command that ends without a terminal count (the DMA count is left
//     unexhausted, so mem_tc never fires for it). The bench PROVES that case ran
//     without a terminal count (the DMA status nibble stays clear) and that the
//     flush came anyway.
//
// THE SEAM, stated so nobody over-reads this: the transfer runs through the real
// pc9821_iobus (real FDC, real uPD71071, real port choreography) and the CPU side
// is the real z486 `memory` with both L1s against sdram_backend_model at real
// sdram.v timing. The DMA's bus-master port is taken at its ACCEPT into the same
// backend storage the CPU reads - the shape an EGC/GRCG hardware writer has in
// tb_pc9821_cpu_vram_coherency - because what is under test is the coherency
// (cached line vs external write), not the SDRAM schedule; the DMA's route to the
// backend is pc9821_memory_subsystem's own story (tb_pc9821_memory_subsystem).
//
// FAIL-FIRST: before the fix there is no DMA-side flush trigger at all, so this
// bench compiles and runs and FAILS at "the CPU's next read" with the stale cached
// dword (0xA5A51234 where the sector's bytes are), and the flush-count check below
// then names the missing request.

`default_nettype none

module tb_pc9821_dma_flush_coherency;
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz, the same clk_sys the fit uses
  reg reset = 1;

  // ==== the CPU-side port interface (the iobus's, as tb_pc9821_fdc_2dd_bank drives it) ====
  reg  [31:0] cpu_addr = 0, cpu_din = 0;
  reg  [3:0]  cpu_be = 0;
  reg         cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;

  // ==== the device fabric (no device is under test through it) ====
  reg  [7:0]  debug_status = 8'hA5;
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  reg   [7:0] device_io_dout = 8'hC3;
  reg         device_rd_wait = 1'b0;
  reg         device_rd_hold = 1'b0;
  reg         device_wr_wait = 1'b0;

  // ==== the strap inputs and system-port outputs (.* needs every name) ====
  reg  [3:0]  bios_set = 4'd0;
  reg         gdc_clock_5m = 1'b0;
  reg         triple_fault_reset = 1'b0;
  reg         cal_cdat = 0;
  reg  [6:0]  cfg_ram_mib = 7'd0;
  reg         cfg_seed_en = 1'b0;
  wire        sdip_seed_pulse;
  reg         egc_gate = 1'b0;
  reg  [10:0] gdc_ff2_state = 11'd0;
  reg  [24:0] ps2_mouse = 25'd0;
  wire [3:0]  top_bank;
  wire [1:0]  ems_state;
  wire        sound_extend, beep_mute;
  wire [1:0]  beep_vol;
  wire        fdc_irq;
  wire        fdc_irq10;
  wire        mouse_irq;
  wire [7:0]  win0_sel;
  wire        sys16m_en, ide_rom_enable, top_shadow_en, bios_ram_gate;
  wire        ide_ram_gate;
  wire        a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire  [7:0] post_code;
  wire        post_write;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire  [3:0] dbg_gate;
  wire  [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi, dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd, dbg_last_io_wr;
  wire  [7:0] dbg_fdc_state;
  wire  [7:0] dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;

  // ==== the core side of the native flush: the REAL z486 `memory` below ====
  wire cache_flush_req;
  wire cache_flush_busy;
  wire cache_flush_done;

  // ==== the floppy media seam (pc9821_fdd_media's side), modelled below ====
  wire [3:0]  fdd_present;
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire  [7:0] fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx;
  wire        fdd_ready, fdd_rdy, fdd_hdrv, fdd_err;
  wire  [7:0] fdd_dout, fdd_hr, fdd_hn, fdd_hs;

  // ==== the uPD71071's bus-master memory port, taken at its accept below ====
  wire [31:0] dma_mem_addr, dma_mem_din;
  wire  [3:0] dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  reg         dma_mem_ready = 1'b0;
  reg  [31:0] dma_mem_dout = 32'd0;
  reg         dma_mem_resp_valid = 1'b0;
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;


  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here


  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),.*);

  // ==== DUT ====
  // The CPU side of the coherency: the real z486 `memory` (both L1s and the native
  // whole-L1 cache_flush walk), exactly the harness tb_pc9821_cpu_vram_coherency
  // drives, with the iobus's cache_flush_req/busy/done as its platform flush.
  reg  [31:0] mcpu_addr = 32'h0;
  reg  [31:0] mcpu_wdata = 32'h0;
  reg   [3:0] mcpu_be = 4'hF;
  reg         mcpu_write = 1'b0;
  reg         mcpu_is_vga = 1'b0;
  reg         mcpu_valid = 1'b0;
  wire        m_req_accepted, m_req_complete, m_read_complete;
  wire [31:0] m_rdata;

  wire [31:2] m_addr;
  wire  [3:0] m_be;
  wire  [7:0] m_burst;
  wire [31:0] m_dout;
  wire [31:0] m_din;
  wire [127:0] m_line_din;
  wire        m_valid, m_write, m_io, m_inta, m_ready;
  wire        m_resp_valid, m_line_resp_valid, m_line_read;
  wire [31:0] mem_accepts, mem_beats;

  memory #(
      .PROTECT_UMA_ROM(0),
      .DCACHE_SET_BITS(6),          // the shipped size (z486_mister.sv DCACHE_SET_BITS)
      .ICACHE_SET_BITS(6),
      .ENABLE_X87(1'b0),
      .ENABLE_DEVICE_MMIO(1'b1), .DEVICE_MMIO_MASK(32'hFE00_0000),
      .APERTURE_ENABLE(1'b1),
      .ALIAS_ENABLE(1'b1),
      .WIN0_ENABLE(1'b1),
      .VGA_ENABLE(1'b1), .VGA_PRE_WRAP(1'b0),
      .A20_MASK_OFF(32'h000F_FFFF)
  ) u_mem (
      .clk(clk), .reset_n(~reset), .a20_enable(1'b1),
      // L1 on, FPU present: z486 drives these from cache_off_req/x87_off_req, which pc9821_system ties low
      .cache_enable(1'b1), .x87_off(1'b0),
      .device_mmio_enable(1'b1), .device_mmio_base(32'h0200_0000),
      .ram_cache_top(32'hFFFF_FFFF), .win0_unmapped(1'b0),
      .dcache_req_valid(mcpu_valid),
      .dcache_req_phys_addr_raw(mcpu_addr),
      .dcache_req_preread_offset(mcpu_addr[11:0]),
      // The real paging unit drives this from the demand itself (paging_unit.sv:
      // `early_idx_drive || pretrans_present || req_mem_present || dcache_req_valid_r`),
      // so a demand always owns the preread over a VIPT probe. Tying it to 1'b0 made
      // the core's own invariant fire (`l1_cache.sv:589: L1 pipelined store accepted
      // without preread priority`) on ANY pipelined store, so this bench never ran
      // past its first store. Model the rule the stub can express: a presented
      // demand reserves the port.
      .dcache_req_preread_priority(mcpu_valid),
      .dcache_req_write(mcpu_write),
      .dcache_req_be(mcpu_be),
      .dcache_req_wdata(mcpu_wdata),
      .dcache_direct_wdata(mcpu_wdata),
      .dcache_req_is_io(1'b0),
      .dcache_req_is_inta(1'b0),
      .dcache_req_is_x87(1'b0),
      .dcache_req_is_vga_mem(mcpu_is_vga),
      .dcache_req_accepted(m_req_accepted),
      .dcache_req_complete(m_req_complete),
      .dcache_read_complete(m_read_complete),
      .dcache_rdata(m_rdata),
      .fast_store_valid(1'b0), .fast_store_phys_addr_raw(32'h0),
      .fast_store_be(4'h0), .fast_store_wdata(32'h0), .fast_store_accepted(),
      .dcache_vipt_probe_valid(1'b0), .dcache_vipt_probe_offset(12'h0),
      .dcache_vipt_probe_ready(), .dcache_vipt_probe_accepted(),
      .dcache_vipt_probe_direct_accepted(),
      .dcache_vipt_resolve_valid(1'b0), .dcache_vipt_resolve_phys_addr_raw(32'h0),
      .dcache_vipt_resolve_hit(), .dcache_vipt_resolve_data(),
      .x87_req_selected(), .x87_req_accepted(1'b0), .x87_req_complete(1'b0),
      .x87_read_complete(1'b0), .x87_rdata(32'h0),
      .icache_req_valid(1'b0), .icache_req_phys_addr_raw(32'h0),
      .icache_req_accepted(), .icache_req_complete(), .icache_rdata(),
      // The DMA snoop stays tied off: the fix is the completion-triggered
      // whole-L1 cache_flush (the audit's sanctioned form), not per-write EADS#.
      .snoop_addr(32'd0), .snoop_valid(1'b0),
      .cache_flush(cache_flush_req), .cache_flush_busy(cache_flush_busy),
      .cache_flush_done(cache_flush_done),
      .addr(m_addr), .be(m_be), .burstcount(m_burst), .line_read(m_line_read),
      .din(m_din), .line_din(m_line_din), .dout(m_dout),
      .valid(m_valid), .ready(m_ready), .write(m_write), .io(m_io),
      .resp_valid(m_resp_valid), .line_resp_valid(m_line_resp_valid), .inta(m_inta)
  );

  // The backend, at real sdram.v timing (tb_pc9821_cpu_vram_coherency's binding).
  sdram_backend_model #(
      .ACCEPT_TO_RESP(2), .WRITE_BUSY(2), .LINE_RESP(0), .WORDS_LOG2(21)
  ) backend (
      .clk(clk), .reset(reset), .valid(m_valid), .ready(m_ready), .write(m_write),
      .addr({m_addr, 2'b00}), .din(m_dout), .din_hi(32'd0), .be(m_be), .burstcount(m_burst),
      .dout(m_din), .resp_valid(m_resp_valid),
      .line_dout(m_line_din), .line_resp_valid(m_line_resp_valid),
      .busy(), .accepts(mem_accepts), .beats(mem_beats)
  );

  // ==== STIMULUS ====
  localparam [15:0] P_MSR_2HD  = 16'h0090,
                    P_DATA_2HD = 16'h0092,
                    P_MSR_2DD  = 16'h00C8,
                    P_DATA_2DD = 16'h00CA,
                    P_STRAP    = 16'h00BE,
                    P_DMA_STAT = 16'h0011,
                    P_DMA_MASK = 16'h0015,
                    P_DMA_MODE = 16'h0017,
                    P_DMA_CLRFF= 16'h0019,
                    P_DMA_MASTER = 16'h001B;

  // The media model, tb_pc9821_fdc_2dd_bank's: one image in unit 0, a sector of
  // 128<<N bytes whose byte k is (R ^ k) - so a transferred sector is checkable
  // byte for byte against the command's own R.
  reg        m_xfer, m_hdrv, m_err;
  reg [15:0] m_ptr;
  reg  [7:0] m_last_r, m_last_c, m_last_n;
  reg [15:0] m_reqs;
  wire [15:0] m_secbytes = (m_last_n[7:4] != 4'd0) ? 16'd32768 : (16'd128 << m_last_n[3:0]);

  assign fdd_present = 4'b0001;      // one image, in unit 0
  assign fdd_ready = !m_xfer;
  assign fdd_rdy   = m_xfer;
  assign fdd_err   = m_err;
  assign fdd_hdrv  = m_hdrv;
  assign fdd_dout  = m_xfer ? (m_last_r ^ m_ptr[7:0]) : 8'h00;
  assign fdd_hr    = fdd_idx + 8'd1;
  assign fdd_hn    = 8'h3;
  assign fdd_hs    = 8'h2;

  always @(posedge clk) begin
    if (reset) begin
      m_xfer <= 1'b0; m_hdrv <= 1'b0; m_err <= 1'b0;
      m_ptr <= 16'd0; m_last_r <= 8'h00; m_last_c <= 8'h00; m_last_n <= 8'h00;
      m_reqs <= 16'd0;
    end else begin
      if (fdd_req) begin
        m_err  <= 1'b0;
        m_hdrv <= 1'b0;
        m_reqs <= m_reqs + 16'd1;
        if (fdd_req_hdr) m_hdrv <= 1'b1;
        else begin
          m_xfer   <= 1'b1;
          m_ptr    <= 16'd0;
          m_last_r <= fdd_r;
          m_last_c <= fdd_c;
          m_last_n <= fdd_n;
        end
      end
      if (m_xfer && fdd_adv) begin
        if (m_ptr + 16'd1 >= m_secbytes) m_xfer <= 1'b0;
        m_ptr <= m_ptr + 16'd1;
      end
    end
  end

  // The bus-master memory model: one byte per dma_mem_req, accepted the cycle
  // after it is presented, landing in the SAME backend storage the CPU reads -
  // the external-writer seam (see the header). The byte comes from the lane
  // mem_be names, exactly pc9821_dmac's own lane decode, so a wrong lane shows up.
  integer    dma_writes = 0;
  reg [3:0]  dma_bad_be = 4'h0;

  wire [7:0] mem_lane_byte = (dma_mem_addr[1:0] == 2'd0) ? dma_mem_din[7:0]   :
                             (dma_mem_addr[1:0] == 2'd1) ? dma_mem_din[15:8]  :
                             (dma_mem_addr[1:0] == 2'd2) ? dma_mem_din[23:16] :
                                                           dma_mem_din[31:24];

  always @(posedge clk) begin
    dma_mem_ready <= 1'b1;                     // the backend accepts in the request cycle
    if (!reset && dma_mem_req && dma_mem_we) begin
      // The hardware-writer seam: the byte lands in the backend's own storage.
      if (dma_mem_be[0]) backend.mem[dma_mem_addr[22:2]][7:0]   <= mem_lane_byte;
      if (dma_mem_be[1]) backend.mem[dma_mem_addr[22:2]][15:8]  <= mem_lane_byte;
      if (dma_mem_be[2]) backend.mem[dma_mem_addr[22:2]][23:16] <= mem_lane_byte;
      if (dma_mem_be[3]) backend.mem[dma_mem_addr[22:2]][31:24] <= mem_lane_byte;
      if (dma_mem_be !== (4'b0001 << dma_mem_addr[1:0])) dma_bad_be <= dma_bad_be | 4'h1;
      dma_writes = dma_writes + 1;
    end
  end

  // One byte port access through the iobus fabric: cpu_valid held until cpu_ready,
  // the byte on the addressed lane, the address in cpu_addr[15:2].
  reg [7:0] rd_val;
  task automatic port_wr(input [15:0] p, input [7:0] d);
    reg [1:0] lane;
    begin
      lane = p[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, p[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, d} << (lane * 8);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic port_rd(input [15:0] p);
    reg [1:0] lane;
    begin
      lane = p[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, p[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1 rd_val = cpu_dout[{lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  localparam integer WAIT_CAP = 20000;
  localparam integer W_IRQ11 = 0, W_IRQ10 = 1, W_DRQ = 2;
  integer cyc;

  task automatic wait_level(input integer which, output integer waited);
    integer reached;
    begin
      waited  = 0;
      reached = 0;
      while (!reached && (waited < WAIT_CAP)) begin
        case (which)
          W_IRQ11: reached = (dut.fdc_irq   === 1'b1);
          W_IRQ10: reached = (dut.fdc_irq10 === 1'b1);
          default: reached = (dut.fdc_drq   === 1'b1);
        endcase
        if (!reached) begin
          @(negedge clk);
          waited = waited + 1;
        end
      end
    end
  endtask

  // The uPD71071 programmed through its own window, tb_pc9821_fdc_2dd_bank's
  // dmac_arm (the firmware's own sequence: master clear, address halves, bank,
  // count halves, mode 0x04|ch = port-to-memory, unmask).
  task automatic dmac_arm(input [1:0] ch, input [23:0] addr, input [15:0] count);
    begin
      port_wr(P_DMA_MASTER, 8'h00);
      port_wr(P_DMA_CLRFF,  8'h00);
      port_wr(16'h0001 + {12'd0, ch, 2'b00}, addr[7:0]);
      port_wr(16'h0001 + {12'd0, ch, 2'b00}, addr[15:8]);
      port_wr(16'h0021 + {13'd0, ((ch - 2'd1) & 2'd3), 1'b0}, addr[23:16]);
      port_wr(16'h0003 + {12'd0, ch, 2'b00}, count[7:0]);
      port_wr(16'h0003 + {12'd0, ch, 2'b00}, count[15:8]);
      port_wr(P_DMA_MODE, {4'b0000, 2'b01, ch});   // din[3:2] = 01: port -> memory
      port_wr(P_DMA_MASK, {6'b000000, ch});        // din[2] = 0 clears that channel's mask
    end
  endtask

  // READ DATA with MF=0: {hd,us}, C, H, R, N, EOT, GPL, DTL (NP2kai FDC_ReadData).
  task automatic read_data_cmd(input [15:0] data_port, input [7:0] unit_head,
                               input [7:0] c, input [7:0] h, input [7:0] r,
                               input [7:0] n, input [7:0] eot);
    begin
      port_wr(data_port, 8'h06);
      port_wr(data_port, unit_head);
      port_wr(data_port, c);
      port_wr(data_port, h);
      port_wr(data_port, r);
      port_wr(data_port, n);
      port_wr(data_port, eot);
      port_wr(data_port, 8'h00);   // GPL
      port_wr(data_port, 8'h00);   // DTL
    end
  endtask

  // Drain the seven-byte result. The drain's LAST byte is the FDC-complete leg's
  // event (pc9821_fdc's res_done), so this task is part of the fix's own trigger
  // choreography, not just cleanup.
  task automatic drain_result(input [15:0] data_port);
    integer k;
    begin
      for (k = 0; k < 7; k = k + 1) port_rd(data_port);
    end
  endtask

  // One CPU request through the real z486 `memory` (tb_pc9821_cpu_vram_coherency's
  // task, renamed onto the mcpu_* side). A read completes on the response; a write
  // completes at the accept and is posted to the store queue.
  task automatic mreq(input [31:0] a, input wr, input [3:0] be, input [31:0] wd,
                      output [31:0] rdata);
    integer g;
    begin
      @(negedge clk);
      mcpu_addr = a; mcpu_wdata = wd; mcpu_be = be; mcpu_write = wr;
      mcpu_is_vga = (a[31:17] == 15'h5);
      mcpu_valid = 1'b1;
      g = 0;
      while (!m_req_accepted && g < 20000) begin @(negedge clk); g = g + 1; end
      if (!m_req_accepted) $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: no accept for %08x", a);
      rdata = 32'h0;
      if (!wr) begin
        g = 0;
        while (!m_read_complete && g < 200000) begin @(negedge clk); g = g + 1; end
        // The bound is generous ON PURPOSE: post-fix the flush walk holds
        // cpu_ready low for its 136 cycles (z486's flush_block), so a read issued
        // behind a just-launched walk is slow but never lost.
        if (!m_read_complete) $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: no response for %08x", a);
        rdata = m_rdata;
      end
      @(negedge clk);
      mcpu_valid = 1'b0; mcpu_write = 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic wr_dword(input [31:0] a, input [31:0] d);
    reg [31:0] sink;
    begin mreq(a, 1'b1, 4'hF, d, sink); end
  endtask

  task automatic rd_dword(input [31:0] a, output [31:0] d);
    begin mreq(a, 1'b0, 4'hF, 32'h0, d); end
  endtask

  // Is this address served from an L1 line? Read it, then read it again: a hit
  // makes no new backend accept; a miss always does.
  task automatic probes_cached(input [31:0] a, output cached);
    reg [31:0] sink;
    reg [31:0] acc_before;
    begin
      rd_dword(a, sink);
      repeat (16) @(posedge clk);
      acc_before = mem_accepts;
      rd_dword(a, sink);
      repeat (8) @(posedge clk);
      cached = (mem_accepts == acc_before) ? 1'b1 : 1'b0;
    end
  endtask

  // The sector's expected dword at a transferred offset: media byte k is (R ^ k)
  // with R = 1 (the media model above), so byte k of the sector is 8'h01 ^ k[7:0].
  function automatic [31:0] media_dword(input [15:0] off);
    begin
      media_dword = {8'h01 ^ (off[7:0] + 8'd3), 8'h01 ^ (off[7:0] + 8'd2),
                     8'h01 ^ (off[7:0] + 8'd1), 8'h01 ^ (off[7:0] + 8'd0)};
    end
  endfunction

  // The flush-request record: how many whole-L1 walks the DMA side asked for, and
  // how many DMA bytes had reached the backend when the FIRST one was requested
  // (the fix's ordering contract: the request comes after the block's writes).
  integer flush_pulses = 0;
  integer flush_writes_at_first = -1;
  always @(posedge clk) begin
    if (!reset && cache_flush_req) begin
      if (flush_pulses == 0) flush_writes_at_first = dma_writes;
      flush_pulses = flush_pulses + 1;
    end
  end

  task automatic clear_flush_record;
    begin
      flush_pulses = 0;
      flush_writes_at_first = -1;
    end
  endtask

// ==== CHECKS ====

  integer errors = 0;
  integer checks = 0;
  integer case1_flushes = 0, case2_flushes = 0;
  reg [31:0] rdv;
  reg        cached;

  task automatic chk_dword(input [31:0] got, input [31:0] want, input [8*120-1:0] tag);
    begin
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: got %08x, want %08x", tag, got, want);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: watchdog timeout (no verdict reached)");
  end

  initial begin
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // The 2DD window and its channel, exactly tb_pc9821_fdc_2dd_bank's DMA case.
    port_wr(P_STRAP, 8'h02);

    // ================================================================ CASE 1:
    // a TC-ended transfer over a buffer the CPU has already cached.
    // (a) the CPU writes two dwords (two cache lines' worth is one line + its
    //     neighbour) and reads them back, so the L1 really holds them.
    wr_dword(32'h0000_2000, 32'hA5A5_1234);
    wr_dword(32'h0000_2004, 32'hDEAD_BEEF);
    wr_dword(32'h0000_2010, 32'h1111_2222);
    rd_dword(32'h0000_2000, rdv);
    chk_dword(rdv, 32'hA5A5_1234, "case1 pre-DMA read of the cached dword");
    probes_cached(32'h0000_2000, cached);
    checks = checks + 1;
    if (!cached) begin
      $display("FAIL case1 setup: 00002000 was NOT cached - the fail-first case proves nothing");
      errors = errors + 1;
    end

    // (b) the transfer: 128 bytes (N=0) over DMA channel 3, TC-ended (the count
    //     is exactly the sector).
    dma_writes = 0;
    dma_bad_be = 4'h0;
    clear_flush_record;
    dmac_arm(2'd3, 24'h002000, 16'd127);
    read_data_cmd(P_DATA_2DD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
    wait_level(W_IRQ10, cyc);
    if (cyc >= WAIT_CAP)
      $fatal(1, "case1: the READ DATA never completed within %0d cycles", WAIT_CAP);
    port_rd(P_DMA_STAT);
    if (rd_val !== 8'h08)
      $fatal(1, "case1: the DMA status reads %02x, expected 08 - channel 3's terminal count (this case is the TC end)",
             rd_val);
    drain_result(P_DATA_2DD);

    // (c) THE FAIL-FIRST ASSERTION (the audit's symptom): the CPU's next read of
    //     the buffer sees the SECTOR's bytes, not the stale cached dword.
    rd_dword(32'h0000_2000, rdv);
    chk_dword(rdv, media_dword(16'd0), "case1 the CPU's first read after the DMA (must be the sector's bytes)");
    rd_dword(32'h0000_2004, rdv);
    chk_dword(rdv, media_dword(16'd4), "case1 the neighbouring dword after the DMA");
    rd_dword(32'h0000_2010, rdv);
    chk_dword(rdv, media_dword(16'd16), "case1 the second line's dword after the DMA");

    // (d) the flush contract: a walk was REQUESTED, after the block's bytes had
    //     landed (the terminal count fires at S_FIN, past the last accept).
    checks = checks + 1;
    if (flush_pulses == 0) begin
      $display("FAIL case1: no cache_flush request followed the DMA terminal count - the disk buffer stays stale (memmap-audit P1-1)");
      errors = errors + 1;
    end
    checks = checks + 1;
    if (flush_pulses > 0 && flush_writes_at_first < 128) begin
      $display("FAIL case1: the cache_flush request came with only %0d of 128 bytes landed", flush_writes_at_first);
      errors = errors + 1;
    end
    case1_flushes = flush_pulses;
    if (dma_bad_be != 4'h0)
      $fatal(1, "case1: mem_be disagreed with the address's lane on at least one byte");

    // ================================================================ CASE 2:
    // an EOT-ended transfer - NO terminal count - so the flush can only come from
    // the FDC-complete leg (pc9821_fdc's result drain).
    dma_writes = 0;
    dma_bad_be = 4'h0;
    clear_flush_record;
    wr_dword(32'h0000_3000, 32'hA5A5_1234);     // re-establish a stale cached line
    wr_dword(32'h0000_3004, 32'hDEAD_BEEF);
    rd_dword(32'h0000_3000, rdv);
    chk_dword(rdv, 32'hA5A5_1234, "case2 pre-DMA read of the cached dword");
    probes_cached(32'h0000_3000, cached);
    checks = checks + 1;
    if (!cached) begin
      $display("FAIL case2 setup: 00003000 was NOT cached - the fail-first case proves nothing");
      errors = errors + 1;
    end

    // The DMA count is programmed for TWO sectors (256 bytes) but the command's
    // EOT ends it after ONE (128 bytes): the count never expires, so the uPD71071
    // reports NO terminal count and mem_tc never fires.
    dmac_arm(2'd3, 24'h003000, 16'd255);
    read_data_cmd(P_DATA_2DD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
    wait_level(W_IRQ10, cyc);
    if (cyc >= WAIT_CAP)
      $fatal(1, "case2: the READ DATA never completed within %0d cycles", WAIT_CAP);
    port_rd(P_DMA_STAT);
    if (rd_val !== 8'h00)
      $fatal(1, "case2: the DMA status reads %02x, expected 00 - this case must end WITHOUT a terminal count (the EOT end), or it proves nothing",
             rd_val);
    drain_result(P_DATA_2DD);
    repeat (8) @(negedge clk);

    rd_dword(32'h0000_3000, rdv);
    chk_dword(rdv, media_dword(16'd0), "case2 the CPU's first read after the EOT-ended DMA (must be the sector's bytes)");
    rd_dword(32'h0000_3004, rdv);
    chk_dword(rdv, media_dword(16'd4), "case2 the neighbouring dword after the EOT-ended DMA");

    checks = checks + 1;
    if (flush_pulses == 0) begin
      $display("FAIL case2: no cache_flush request followed the EOT-ended transfer (no terminal count fires for it) - the FDC-complete leg is missing");
      errors = errors + 1;
    end
    checks = checks + 1;
    if (flush_pulses > 0 && flush_writes_at_first < 128) begin
      $display("FAIL case2: the cache_flush request came with only %0d of 128 bytes landed", flush_writes_at_first);
      errors = errors + 1;
    end
    case2_flushes = flush_pulses;
    if (dma_bad_be != 4'h0)
      $fatal(1, "case2: mem_be disagreed with the address's lane on at least one byte");

    $display("NOTE dma_flush_coherency: %0d check(s), %0d mismatch(es), case1 flushes=%0d case2 flushes=%0d",
             checks, errors, case1_flushes, case2_flushes);

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_FLUSH_COHERENCY: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_DMA_FLUSH_COHERENCY: FAIL (%0d errors)", errors);
    end
  end

endmodule

`default_nettype wire

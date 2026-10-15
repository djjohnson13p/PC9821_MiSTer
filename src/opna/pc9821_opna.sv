// PC-9801-86 board glue around the vendored YM2608 (OPNA): one chip behind a two-address
// host port pair, banked by an A1 pin.
//   0x188 read chip status         | write register-select latch, low bank
//   0x18A read SSG/register shadow | write the selected register
//   0x18C read extended status     | write extended register-select
//   0x18E read extended data       | write extended data
// 0x18C/0x18E answer 0xFF until 0xA460 bit 0 enables the extension (NP2kai board86.c,
// pcm86io.c); 0x18A reads follow NP2kai's board shadow (opna_i18a), which master.lib's
// read-modify-write of SSG register 7 depends on (r12/06 P0-3). 0x188 is the chip's own
// status, so bit 7 is its BUSY and clears in bounded time (the games' WAITREADY, r12/06 P0-2).
// Clocking: the chip's 7.9872 MHz as a 32-bit DDS carry on clk (NP2kai OPNA_CLOCK doubled).
// Register writes are latched and presented to the chip at its own rate, because the vendored
// FM register file is a sample-rate operator scan that drops a write not held until its slot
// (the directly-latched SSG/ADPCM banks are immune).

`default_nettype none

module pc9821_opna #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        reset,        // synchronous, active high

    // Device bus, driven by pc9821_iobus. Only 0x0188/0x018A/0x018C/0x018E
    // are routed here (pc9821_system's opna_cs), so only addr[2:1] can vary:
    // pc9821_iobus decodes the rest of the 16-bit bus before it reaches this port.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [15:0] io_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        io_wr,
    input  wire        io_rd,
    input  wire  [7:0] io_din,
    output reg   [7:0] io_dout,
    output wire        io_rd_wait,
    // Write back-pressure: asserted when the register-write queue cannot accept
    // a write this cycle. pc9821_iobus holds the guest's I/O access in its wait
    // state until this clears, so a no-polling write burst STALLS the CPU instead
    // of silently dropping writes past the queue (the drop boundary T9a measured:
    // 94 of 160 lost at the new IO_MIN_HOLD cadence). NP2kai applies every write;
    // stalling is the only faithful equivalent now that the chip's register file
    // is fed at its own scan rate.
    output wire        io_wr_wait,

    // 0xA460 bit 0: the -86's extension enable. Latched by pc9821_iobus.
    input  wire        extend,

    // The board's joystick read: register 0x0E returns these six switch lines, active low
    // -- up, down, left, right, button 1, button 2. They are the 9-pin connector's, so they
    // come from pc9821_gameport, which owns the connector (NP2kai sound/fmboard.c
    // fmboard_getjoy, reached from every one of its OPNA boards; cbus/board86.c:60-68).
    input  wire  [5:0] joystick,

    // Stereo output: the WIDE FM+ADPCM+SSG sum. `jtopna` delivers the FM+ADPCM
    // sum already clamped at its junction (jt08_acc restores ymfm's clamp16 on
    // the complete FM+ADPCM-A+ADPCM-B sum, ymfm_opn.cpp:1410-1414, then sign-
    // extends it to 20 bits) and leaves the SSG on a separate word; the two are
    // added here at the SSG level the upstream PC-88 board mix sets
    // (psg_snd << 2 - the measurement-derived board-trim correction is
    // DEFERRED per owner 2026-09-24; see the comment at the sum itself for the
    // measured range and the open owner question). The SSG is then
    // AC-COUPLED before the join: a 1-pole high-pass modelling the -86 board's
    // C7C1 series coupling capacitor,
    // which removes the SSG's unipolar DC so it joins the mix zero-mean. The
    // result is delivered in 20 bits (clamped FM+ADPCM [+-32,767] + zero-mean
    // SSG [+-6,138]). The SSG is added AFTER the FM clamp, exactly as ymfm adds
    // it after its clamp16. The LAST saturation of the whole -86 chain is the
    // FINAL DAC (z486_mister's mix_dry saturator, NP2kai's _saturation_s16),
    // which catches this tail.
    output wire signed [19:0] snd_l,
    output wire signed [19:0] snd_r,

    // Timer IRQ, active high, to the 8259's slave IR4 (system IRQ12, vector 0x14).
    output wire        irq,

    // Rhythm ROM pack-loader write port (pc9821_rhythm_loader -> jtopna ->
    // RHYTHM_ROM). With no user-supplied image the ROM reads as zeros, and that
    // is NOT silence: an all-zero ADPCM-A nibble is code 0 at step 0, a +2 delta
    // per sample, so every drum becomes a loud DC-carrying sawtooth (AGENTS.md
    // "Firmware pack (runtime inputs)"; tools/build_pack.py warns on a zero
    // region and tools/check_pack.py fails on one). See
    // src/opna/rhythm_rom/RHYTHM_ROM.v and the layout in tools/build_pack.py.
    input  wire        rhythm_we,
    input  wire [11:0] rhythm_waddr,
    input  wire [15:0] rhythm_wdata
);

  // ------------------------------------------------------------------
  // Clock enable: 7.9872 MHz on clk.
  // The numerator MUST be 64-bit: 2**32 * 7_987_200 overflows 32 bits, and the
  // truncation is the point of the accumulator. The quotient fits in 32 bits for
  // any SYS_CLOCK_HZ above 7.9872 MHz - it is 686_095_255 at 50 MHz - because
  // CEN_STEP = 2**32 * 7.9872e6 / SYS_CLOCK_HZ, so raising SYS_CLOCK_HZ lowers it.
  // ------------------------------------------------------------------
  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */
  localparam [31:0] CEN_STEP =
      (64'd4_294_967_296 * 64'd7_987_200) / (SYS_CLOCK_HZ + 64'd0);
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */

  reg  [31:0] cen_acc;
  wire [32:0] cen_sum = {1'b0, cen_acc} + CEN_STEP;
  wire        cen     = cen_sum[32];

  always @(posedge clk) begin
    if (reset) cen_acc <= 32'd0;
    else       cen_acc <= cen_sum[31:0];
  end

  // ------------------------------------------------------------------
  // Reset: jt12 wants rst held for at least six clk&cen cycles
  // (jt12/hdl/jt08.v:23), so stretch it on the chip's own clock enable.
  // ------------------------------------------------------------------
  reg [4:0] rst_cnt;
  // op_rst is a REGISTER clocked by this same clk and stretched for 16 cen cycles, and jt12
  // consumes it as an asynchronous reset (`always @(posedge clk, posedge rst)`). That is safe
  // precisely because the source is a clean flop output: assertion AND deassertion are both
  // synchronous to clk, so there is no window in which the reset can be sampled mid-transition.
  // The warning fires because the same signal is used synchronously here and asynchronously
  // there - not because anything is unsynchronised.
  /* verilator lint_off SYNCASYNCNET */   // registered reset, synchronous release - see above
  reg       op_rst;
  /* verilator lint_on SYNCASYNCNET */

  always @(posedge clk) begin
    if (reset) begin
      rst_cnt <= 5'd16;
      op_rst  <= 1'b1;
    end else if (cen) begin
      if (rst_cnt != 5'd0) begin
        rst_cnt <= rst_cnt - 5'd1;
        op_rst  <= 1'b1;
      end else begin
        op_rst  <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // Register-write buffer. See the header: the vendored FM register file can
  // only absorb one operator write per operator scan, so host writes are
  // queued and handed to the chip one at a time, spaced by the chip's own
  // BUSY window. The directly-latched banks ride the same queue (their
  // register-select must still reach the chip before their data), which only
  // costs latency.
  // ------------------------------------------------------------------
  // The host port's own addressing: the card decodes 0x188..0x18F and uses
  // port bit 1 (CPU A1) as the chip's A0 and port bit 2 (CPU A2) as the
  // extension-bank select, so 0x188/0x18A are A0=0/1 of the base bank and
  // 0x18C/0x18E the same of the extended bank. Port bit 0 is the byte lane and
  // is always 0 at these four addresses (pc9821_iobus presents the odd byte of
  // a 16-bit access as its own port and leaves it open bus, as NP2kai does).
  wire [1:0] op_addr   = {io_addr[2], io_addr[1]};
  wire       op_ext    = io_addr[2];
  wire       op_sel    = !op_ext || extend;   // 0x18C/0x18E gated by 0xA460[0]

  // B-4: 0xA460 bit 0 dropping reconfigures the FM to 3-channel mono (NP2kai
  // extendchannel(0), cbus/board86.c:79-94). The matching drum key-off is the
  // queue injection declared beside the queue below.
  wire       ch3_mono  = ~extend;

  localparam integer WRQ_DEPTH = 64;   // power of two; one full six-channel FM setup
  localparam integer WRQ_BITS  = 6;    // log2(WRQ_DEPTH)
  // The gap after a stretched chip write, in `cen` cycles. One operator scan is
  // 24 of the chip's clock enables and the vendored BUSY is 32 (jt12_mmr.v:576-590),
  // and clk_en = cen/6 with the fixed 1/6 divider (jt12_div.v:60-62, mask_div=1),
  // so 36 enables = 216 cen covers both. Registers the chip latches on the bus
  // write itself (SSG, ADPCM-A/B, timers, LFO, the 0x1x selects) need only a
  // couple of cycles, so they keep the board's own latency.
  localparam integer DRAIN_GAP = 216;
  localparam integer SHORT_GAP = 2;

  // The queue storage is ONE 64x11 M10K, not three per-slot arrays (704 flip-flops
  // with one 11-bit write enable per slot, r13/113). A word is
  // {stretch, addr[1:0], data[7:0]}; one write port and a registered read port make
  // it a simple dual port. no_rw_check is safe because the queue never reads the
  // slot it is writing: while it holds an entry the read pointer differs from the
  // write pointer, and at full it refuses writes (wrq_push is gated on wrq_cnt[WRQ_BITS]).
  (* ramstyle = "M10K, no_rw_check" *) reg [10:0] wrq_mem [0:WRQ_DEPTH-1];
  reg  [WRQ_BITS-1:0] wrq_wr, wrq_rd;
  reg  [WRQ_BITS:0]   wrq_cnt;
  wire                wrq_empty = (wrq_cnt == 0);

  // The register-select shadow the board model answers 0x18A from, and that
  // this buffer reads to tell an FM register (0x30-0xB6) from a directly
  // latched one. Declared here because the buffer uses it above its writer.
  reg [7:0] sel_lo;      // last value written to 0x188: the register select
  reg [7:0] sel_hi;      // last value written to 0x18C: the EXTENDED select (addrh)

  reg  [1:0]          dr_state;   // 0 = idle, 1 = present, 2 = wait
  reg  [7:0]          dr_gap;
  reg  [10:0]         dr_word;    // the block RAM's registered read output
  reg                 dr_fire;    // armed chip write (lands on the first host-free cycle)
  wire [1:0]          dr_addr = dr_word[9:8];
  wire [7:0]          dr_data = dr_word[7:0];
  wire                dr_str  = dr_word[10];

  wire                host_wr  = io_wr && op_sel;
  wire                host_rd  = io_rd && op_sel;
  // S1: the chip write lands only on a host-free cycle. An armed dr_fire that
  // meets a host read's S_BYTE (or a host write) HOLDS instead - the host owns
  // the chip port that cycle (the addr/din muxes and wr_n are gated with dr_go
  // below) and the queued write retries the next cycle. Nothing is dropped and
  // jt12_dout can never latch the data-port case during a status read.
  wire                dr_go = dr_fire && !host_rd && !io_wr;

  // The one definition of which register the vendored FM register file can only
  // absorb at its own scan slot. Everything 0x30-0xB6 is the FM register file
  // (operator slots 0x30-0x9F through the sample-rate scan, channel slots
  // 0xA0-0xB6 through jt12_reg_ch, which also latches on the clock enable), on
  // either bank. 0x28 is not an operator slot, but it is the one register
  // jt12_mmr presents as a LEVEL - up_keyon, held until the next data write
  // (jt12_mmr.v:333-339) - and jt12_kon samples it only at the clock enable
  // (jt12_kon.v:70-78), so it needs the same hold to outlast the write behind
  // it. Only the BASE bank's 0x28 is key-on: jt12_mmr's REG_KON arm gates on
  // !part && !addr[1] (jt12_mmr.v:333).
  function automatic is_fm_register(input [0:0] bank, input [7:0] sel);
    is_fm_register = ((sel >= 8'h30) && (sel <= 8'hB6)) ||
                     (!bank && (sel == 8'h28));
  endfunction
  // Only a DATA write (A0=1, the chip's data port) is held: a register-select
  // write (A0=0) is latched by the chip on the bus write itself. The bank picks
  // which select latch the write used.
  wire                wrq_stretch = op_addr[0] &&
      is_fm_register(op_addr[1], op_addr[1] ? sel_hi : sel_lo);
  // BUSY covers the whole drain (queued work, the present cycle and the gap
  // after it), so a guest that polls still is throttled even if the chip's own
  // busy flag were not readable.
  wire                wrq_busy = (wrq_cnt != 0) | (dr_state != 2'd0);
  // LOCAL CHANGE (B-4): NP2kai's extendchannel(0) keys off every rhythm drum by
  // writing rhythm register 0x10 = 0xff when 0xA460 bit 0 drops (cbus/board86.c:79-94).
  // That write is injected through the SAME queue as a host write - first the
  // register select (0x10), then the data (0xff) - so the chip sees the key-off
  // exactly as if software had written it. The board's sel_lo/last_data shadow is
  // deliberately left alone: NP2kai's rhythm_setreg writes the rhythm unit
  // directly, not the OPNA register shadow.
  reg         ext_prev;
  reg  [1:0]  ext_inj;       // 0 idle, 1 first word (select), 2 second word (data)
  wire        ext_drop      = ext_prev && !extend;
  wire        ext_inj_busy  = (ext_inj != 2'd0);
  // The injected pair must not be split by a host write landing between its two
  // words, so host writes wait (io_wr_wait below) and the injection yields to a
  // host write already presented rather than racing it.
  wire        inj_push      = ext_inj_busy && !wrq_cnt[WRQ_BITS] && !host_wr;
  wire  [1:0] inj_addr      = (ext_inj == 2'd1) ? 2'b00 : 2'b01;
  wire  [7:0] inj_data      = (ext_inj == 2'd1) ? 8'h10 : 8'hFF;
  wire        wrq_push      = host_wr && !wrq_cnt[WRQ_BITS] && !ext_inj_busy;
  wire        wrq_pop       = dr_go;   // the pop moves only when the fire completes
  wire        any_push      = wrq_push || inj_push;
  wire [10:0] push_word     = inj_push ? {1'b0, inj_addr, inj_data}
                                        : {wrq_stretch, op_addr, io_din};
  // The queue-full back-pressure. `wrq_push` keeps its !full guard as the last
  // resort (a master that ignores io_wr_wait - a bare bench driving this module -
  // still loses the write rather than corrupting the queue), but the iobus never
  // presents such a write: it waits in S_IOWAIT while this is high. The same
  // wait also holds a host write while the two-word key-off injection is in
  // flight, so the pair is atomic with respect to the chip.
  assign                io_wr_wait = op_sel && (wrq_cnt[WRQ_BITS] || ext_inj_busy);

  always @(posedge clk) begin
    if (reset) begin
      wrq_wr  <= {WRQ_BITS{1'b0}};
      wrq_rd  <= {WRQ_BITS{1'b0}};
      wrq_cnt <= {(WRQ_BITS + 1){1'b0}};
      dr_state <= 2'd0;
      dr_gap   <= 8'd0;
      dr_fire  <= 1'b0;
      ext_prev <= 1'b0;
      ext_inj  <= 2'd0;
    end else begin
      if (any_push) wrq_wr <= wrq_wr + 1'b1;
      // LOCAL CHANGE (B-4): on a 0xA460 bit-0 drop, arm the two-word rhythm
      // key-off injection; it advances one word per queue push.
      ext_prev <= extend;
      case (ext_inj)
        2'd0: if (ext_drop) ext_inj <= 2'd1;
        2'd1: if (inj_push) ext_inj <= 2'd2;
        2'd2: if (inj_push) ext_inj <= 2'd0;
        default: ext_inj <= 2'd0;
      endcase
      case (dr_state)
        // The word is already in dr_word (the read port below registers it every
        // clk), so entering the present state needs no load of its own.
        2'd0: if (!wrq_empty && dr_gap == 8'd0)
                dr_state <= 2'd1;
        // The fire is armed one cycle ahead and RETRIES until its cycle is
        // host-free: a host read of 0x188 (the BUSY poll) or a host write
        // landing on the armed fire cycle owns the chip port (host priority),
        // so the fire holds - wrq_rd/wrq_pop do not move until the fire cycle
        // actually completes - and lands the next idle cycle instead of
        // corrupting the read (S1).
        2'd1: if (!dr_fire) begin
                if (!host_rd && !io_wr) dr_fire <= 1'b1;
              end else if (dr_go) begin
                dr_fire  <= 1'b0;
                wrq_rd   <= wrq_rd + 1'b1;
                dr_gap   <= dr_str ? DRAIN_GAP[7:0] : SHORT_GAP[7:0];
                dr_state <= 2'd2;
              end
        2'd2: if (cen) begin
                if (dr_gap == 8'd0) dr_state <= 2'd0;
                else                dr_gap <= dr_gap - 8'd1;
              end
        default: dr_state <= 2'd0;
      endcase
      wrq_cnt <= wrq_cnt + {WRQ_BITS{1'b0}} + any_push - {WRQ_BITS{1'b0}} - wrq_pop;
    end
  end

  // The write port, in its own block so the array infers as one M10K rather than a
  // flip-flop file (r13/110's split). wrq_wr is the write address register.
  always @(posedge clk)
    if (any_push) wrq_mem[wrq_wr] <= push_word;

  // The read port: the block's own registered output, so the drain's read stays one
  // clk deep exactly as the register array's dr_* load was. It reads every clk;
  // wrq_rd is stable unless the drain advances it, so the word it presents on the
  // idle-to-present edge is the one the register array would have latched there.
  always @(posedge clk)
    dr_word <= wrq_mem[wrq_rd];

  // ------------------------------------------------------------------
  // The chip's host port. A1 = io_addr[1] is the extended bank select, A0 =
  // io_addr[0] the address/data select, which is exactly `jtopna`'s addr[1:0].
  // A host write is one clk cycle (pc9821_iobus's S_BYTE strobe); a read is
  // answered one cycle later, which is why io_rd_wait is asserted and
  // pc9821_iobus takes its S_DEVWAIT cycle.
  // ------------------------------------------------------------------
  assign io_rd_wait = io_rd && op_sel;

  wire [7:0] op_dout;
  wire       op_irq_n;
  wire signed [19:0] fm_l, fm_r;
  wire [11:0] psg_snd;

  jtopna u_opna (
    .rst            (op_rst),
    .clk            (clk),
    .cen            (cen),
    // The chip only ever sees a chip write from the drain, and only ever sees
    // a read from a host read cycle (the same routing that keeps host writes
    // out of the chip while they sit in the buffer). Both muxes and wr_n are
    // gated with dr_go (S1): on a fire cycle the host claims, the chip sees the
    // host's own access alone and the write retries next cycle.
    .din            (dr_go ? dr_data : io_din),
    .addr           (dr_go ? dr_addr : op_addr),
    .cs_n           (~(host_rd | dr_go)),
    .wr_n           (~dr_go),
    .rd_n           (~host_rd),
    .dout           (op_dout),
    .irq_n          (op_irq_n),
    .IOA_in         (8'hFF),
    .IOB_in         (8'hFF),
    /* verilator lint_off PINCONNECTEMPTY */   // unwired on a PC-9801-86, see the notes here
    .IOA_out        (),
    .IOB_out        (),
    .IOA_oe         (),
    .IOB_oe         (),
    // No ADPCM-B sample RAM is wired yet: the chip reads zeros there, so
    // ADPCM-B is silent until that memory lands.
    .adpcm_addr     (),
    .adpcm_roe      (),
    .adpcm_din      (8'h00),
    .adpcm_wr       (),
    .adpcm_dout     (),
    /* verilator lint_on PINCONNECTEMPTY */
    .fm_snd_right   (fm_r),
    .fm_snd_left    (fm_l),
    .psg_snd        (psg_snd),
    .rhythm_we      (rhythm_we),
    .rhythm_waddr   (rhythm_waddr),
    .rhythm_wdata   (rhythm_wdata),
    .ch3_mono       (ch3_mono)
  );

  // ------------------------------------------------------------------
  // Port read model (NP2kai cbus/board86.c:55-76).
  // ------------------------------------------------------------------
  reg [7:0] last_data;   // last byte written through any data port: NP2kai's s.data

  // ------------------------------------------------------------------
  // The 16-byte SSG read shadow. It is ONE block RAM, not 128 flip-flops plus a
  // 16:1 read mux: one write port and one registered read is a simple dual port,
  // and a block memory holds it for no logic ALMs at all -- where the flop array
  // costs 2.00 registers per ALM (res-mlab-REPORT: 256 flops = exactly 128 ALMs)
  // on top of the mux -- while block RAM is the resource this design does NOT
  // bind on. Registers -> block RAM is the profitable direction, and M10K is the
  // right end of it: an MLAB IS a LAB, so parking the array there would spend the
  // BINDING resource to buy back the free one (res-mlab-REPORT section 0).
  //
  // THE READ IS REGISTERED, one clk behind sel_lo, and that is free at this
  // port: sel_lo moves on its OWN 0x188/0x18C bus access, never on the 0x18A
  // read that answers from it, and that read is already a waited one
  // (io_rd_wait) whose byte is captured a cycle after the strobe.
  //
  // THE TWO THINGS THAT WOULD SILENTLY BLOCK THE INFERENCE ARE ABSENT BY
  // CONSTRUCTION (the kbd_lut trap, res-mlab-REPORT section 7.2): the array
  // carries NO reset -- a reset blocks inference exactly as a power-up value on
  // its read register does -- and ssg_rd_q carries no power-up value. A memory's
  // power-up contents are therefore the board's reset values, and a LATER reset
  // is put back through the array's own port by ssg_seed below.
  //
  // no_rw_check: the guest's 0x18A write can land on the address the read port
  // presents that cycle, and what the read returns then is don't-care -- ssg_rd_q
  // samples it and refreshes on the next clk, long before any access answers
  // from it (wrq_mem declares the same thing for the same reason).
  // ------------------------------------------------------------------
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] ssg_reg [0:15];

  integer i;

  // The array's POWER-UP contents are the board's reset values, because a memory
  // cannot be reset (see above). NP2kai opna_reset seeds three of the SSG shadow
  // bytes (sound/opna.c:135-140):
  // reg[7] = 0xbf, reg[14] = 0xff, reg[15] = 0xff. THE MACHINE REFUTES THE
  // reg[7] SEED. Probe OPNAPRO selects SSG register 7 and reads 0x00
  // (docs/probes/OPNA.TXT section CHIPID, `0x18A with 0x188=07 (SSG register 7;
  // the references' reset seed is BF): 00`) on a card the same block proves
  // present (0x188 = FF answers the -86 chip ID 0x01), so the byte is the
  // chip's and not open bus; both software models answer 0xbf and are wrong.
  // The die-shot LLE is with the machine: an SSG read returns the register
  // itself (fmopna_impl.c:2232-2235) and reset loads it from an internal bus
  // that is 0 (:2114-2130). ymfm's SSG resets all-zero as well
  // (ymfm_ssg.cpp:44-47 with ssg_engine::reset :86-93).
  // r12/06 section 2.1c argued the other way: master.lib's js_start
  // (rec98 libs/master.lib/js_start.asm:67-72, read reg 7 / and 3Fh / or 80h /
  // write back) turns a 0x00 read into 0x80 - every SSG tone and noise source
  // ROUTED - and that was read as corruption. The capture shows 0x80 is the
  // hardware's own outcome, and it is what makes js_start mean "start the
  // SSG": from a 0xbf read the write-back is 0xbf, i.e. all six sources
  // DISCONNECTED and an SSG that stays silent however the guest programs its
  // periods and amplitudes.
  // SCOPE: this is the BOARD's read shadow, the read the guest sees. The
  // CHIP's own copy of the register (the vendored jt49 regarray[7], a LOCAL
  // PATCH at src/opna/jt49/hdl/jt49.v:240) still powers up 0xBF, so shadow and
  // chip disagree until the guest writes reg 7; that is an AUDIO-side decision
  // with its own bench (tb_pc9821_opna_ssg_powon) and is deliberately NOT
  // changed with this read-back fix.
  // Register 0x0E is SHADOW-ONLY here - 0x18A answers it from the joystick
  // (opna_i18a, above), so this byte can never be read back - but NP2kai holds
  // 0xFF there and an exact shadow is the point of this block (opna-audit F7).
  initial begin
    for (i = 0; i < 16; i = i + 1) ssg_reg[i] = 8'h00;   // incl. reg 7: the machine's 0x00
    ssg_reg[14] = 8'hFF;
    ssg_reg[15] = 8'hFF;
  end

  reg [7:0] ssg_rd_q;
  // BYTE-IDENTICAL TO THE FORM THAT INFERS. The array's one read port stays exactly
  // `ssg_rd_q <= ssg_reg[sel_lo[3:0]]`, with no reset and no power-up value on the register
  // (a reset here, or an initial value there, is what silently puts a table back in LUTs -
  // the RAM-inference trap). Everything the reset fix needs lives on the READ MUX in
  // io_dout and on the write port below, not on this line.
  always @(posedge clk) ssg_rd_q <= ssg_reg[sel_lo[3:0]];

  // The reset a memory cannot take, written back through its OWN port: one entry per clk for
  // the 16 clk AFTER the reset lifts (during the reset the counter holds 0 and re-writes entry
  // 0 with the same 0x00).
  //
  // THE SWEEP IS THE RESET, AND IT IS ATOMIC FROM THE GUEST'S SIDE BY CONSTRUCTION
  // (v-reset-audit F1/F2). A bare 16-clk sweep has NEITHER of the two facts below; both are
  // module state, and neither is a margin against the CPU reset gate's hold:
  //   * ssg_ok[a] means entry a's array word is THIS epoch's byte - the sweep has reached it,
  //     or the guest wrote it since this reset. A read of an entry that is neither answers the
  //     reset image (ssg_reset_byte) instead of the array, so the FIRST 0x18A read after a
  //     reset can never see a pre-reset byte. F1: a read of register 0x0F right after a reset
  //     answered the pre-reset 0x80 while the flop form installed 0xFF.
  //   * the sweep does not touch an entry the guest has written (ssg_ok set by the write path),
  //     so a byte the guest writes is never clobbered by it. F2: a write of reg 0x0A four clk
  //     into the sweep read back the reset 0x00 - same-cycle write priority saved only the
  //     write's own cycle, and the sweep still visited entry 10 later.
  // So a guest write arriving inside the window STICKS (it is not deferred and not lost), and
  // the read side answers the INTENDED post-reset value for the entries the sweep has not
  // reached. Nothing here depends on the ~1-clk margin between the 16-clk sweep and the CPU
  // reset gate's 15-cycle hold, which the audit found nothing pinning.
  //
  // THE REJECTED ALTERNATIVE, recorded because it is the obvious first idea: hold the guest off
  // the device until the sweep finishes (drive io_wr_wait / a read-hold from the sweep's done
  // signal). That fixes F1 and leaves F2 intact - it only DEFERS a write, and the module still
  // clobbers one presented inside the window, so F2's own minimal case (a direct 0x18A write
  // four clk into the sweep) still reads back 0x00 across cycles. Satisfying both findings at
  // the module boundary, for a bare master as well as through pc9821_iobus, is strictly better
  // than pinning an integration margin. The cost of this form is ssg_ok's 16 flops; the
  // 16-entry array and its inference are untouched.
  function automatic [7:0] ssg_reset_byte(input [3:0] ad);
    ssg_reset_byte = (ad >= 4'hE) ? 8'hFF : 8'h00;   // entries 14 and 15 carry 0xFF
  endfunction

  reg  [4:0] ssg_seed;                       // 0..15 = the entry being restored; 16+ = done
  reg [15:0] ssg_ok;                         // entry's array word is this epoch's byte
  wire       ssg_seed_we = (ssg_seed < 5'd16);
  wire [3:0] ssg_seed_ad = ssg_seed[3:0];
  wire [7:0] ssg_seed_da = ssg_reset_byte(ssg_seed_ad);
  // The guest's shadow write: 0x18A is the data port and only sel_lo < 0x10 names one of the
  // sixteen shadow entries (0x18A answers everything at or above 0x10 from last_data).
  wire       ssg_guest_we = !reset && io_wr && op_sel && (op_addr == 2'b01) &&
                            (sel_lo < 8'h10);

  always @(posedge clk) begin
    if (reset) begin
      ssg_seed <= 5'd0;
      ssg_ok   <= 16'd0;
    end else begin
      // The sweep visits every entry and skips the ones the guest already wrote; a
      // same-cycle collision leaves that entry's stale word in the array with ssg_ok
      // still low, so the read mux answers the reset image for it and the stale word is
      // never observable (and a later guest write to it sets ssg_ok and is read back).
      if (ssg_seed_we) ssg_seed <= ssg_seed + 5'd1;
      if (ssg_guest_we)
        ssg_ok[sel_lo[3:0]] <= 1'b1;
      else if (ssg_seed_we && !ssg_ok[ssg_seed_ad])
        ssg_ok[ssg_seed_ad] <= 1'b1;
    end
  end

  // The shadow's write port, in its own block so the array reads as a plain
  // simple dual port (wrq_mem's write port is split out the same way). The guest keeps
  // priority on the cycle it collides, and the sweep skips an entry it must not clobber.
  always @(posedge clk) begin
    if (ssg_guest_we)
      ssg_reg[sel_lo[3:0]] <= io_din;
    else if (ssg_seed_we && !ssg_ok[ssg_seed_ad])
      ssg_reg[ssg_seed_ad] <= ssg_seed_da;
  end

  always @(posedge clk) begin
    if (reset) begin
      sel_lo    <= 8'h00;
      sel_hi    <= 8'h00;
      last_data <= 8'h00;
    end else begin
      // 0x188 sets the low-bank register latch AND the data shadow.
      // NP2kai's opna_o188 (cbus/board86.c:14-19) assigns BOTH s.addrl and
      // s.data, and opna_i18a returns s.data for every low address that is not
      // 0x0E, 0xFF or below 0x10. So a 0x188 write alone must make a following
      // 0x18A read answer the byte just written; with the shadow untouched it
      // would answer whatever the last 0x18A write put there instead.
      if (io_wr && op_sel && (op_addr == 2'b00)) begin
        sel_lo    <= io_din;
        last_data <= io_din;
      end
      // 0x18C is the extended bank's register latch. It is reached only when
      // the extension is on -- pc9821_iobus and `op_sel` above already gate
      // that, matching NP2kai's opna_o18c, which guards on s.extend. Like
      // opna_o188 it also moves the data shadow a 0x18E read answers from
      // (opna_o18c: s.addrh = dat; s.data = dat;) -- without that, a 0x18C
      // write followed by a 0x18E read answers the previous 0x18A/0x18E byte
      // instead of the select byte just written.
      if (io_wr && op_sel && (op_addr == 2'b10)) begin
        sel_hi    <= io_din;
        last_data <= io_din;
      end
      // 0x18A writes the byte into the chip and into the shadow the read
      // answers from (the shadow's own write port is beside its declaration).
      if (io_wr && op_sel && (op_addr == 2'b01))
        last_data <= io_din;
      // 0x18E is the extended bank's data byte, and NP2kai's opna_o18e
      // (cbus/board86.c:92-110) only reads the CHIP for addrh 0x08 and 0x0F;
      // every other extended address returns s.data. Answering the chip for all
      // of them is a wider read than the board gives.
      if (io_wr && op_sel && (op_addr == 2'b11))
        last_data <= io_din;
    end
  end

  always @* begin
    case (op_addr)
      // Chip status, with this glue's own BUSY folded in: the guest's WAITREADY
      // must wait for the queued writes to reach the chip, not just for the
      // chip's own busy flag.
      2'b00: io_dout = op_dout | {wrq_busy, 7'b0};    // chip status
      // The board's joystick register, register 0x0E: the connector's six switch lines,
      // active low (NP2kai fmboard_getjoy, which returns its result masked to 0x3F). The
      // two upper bits stay 1: NP2kai ORs the chip's own interrupt flags into them
      // (sound/fmboard.c:92-93), and the machine's measured idle byte is 0xFF (probes/JOY.TXT),
      // so only the six switch lines are this register's live part.
      2'b01: io_dout = (sel_lo == 8'h0E) ? {2'b11, joystick} :
                       (sel_lo == 8'hFF) ? 8'h01 :    // the -86 chip ID
                       // The shadow read, through the sweep above: an entry this epoch's
                       // sweep has not restored (and the guest has not written) still holds
                       // its PRE-reset byte in the array, so the read answers the reset
                       // image instead. ssg_rd_q is the array's own plain registered read.
                       (sel_lo < 8'h10)  ? (ssg_ok[sel_lo[3:0]] ? ssg_rd_q
                                                                 : ssg_reset_byte(sel_lo[3:0]))
                                         : last_data;
      // Extended status. Bit 7 is the chip's BUSY (jt12_dout 2'b10: {busy, 0,
      // adpcmb_flag2, flag_B, flag_A}), so the glue's queue folds in exactly as it
      // does at 0x188: a guest polling 0x18C must wait for the queued writes to
      // reach the chip, not just for the chip's own busy flag (r13/276).
      2'b10: io_dout = extend ? (op_dout | {wrq_busy, 7'b0}) : 8'hFF;   // extended status
      // Extended data: the chip answers only for addrh 0x08 and 0x0F; every
      // other extended register reads back the data shadow (NP2kai opna_o18e).
      default: io_dout = extend ? ((sel_hi == 8'h08 || sel_hi == 8'h0F) ? op_dout
                                                                       : last_data)
                                : 8'hFF;
    endcase
  end

  // ------------------------------------------------------------------
  // Output: the clamped FM+ADPCM junction + the AC-coupled (zero-mean) SSG,
  // carried in 20 bits. The FM+ADPCM sum was already clamped to 16 bits at the
  // jt08_acc junction (ymfm's clamp16, ymfm_opn.cpp:1407-1413); the SSG joins
  // here, after that clamp, and the chain's LAST saturation is the final DAC
  // (z486_mister's mix_dry).
  //
  // THE JOIN IS psg * 33/16 = the upstream PC-88 board-mix BASELINE (psg << 2)
  // times the -86 board's SSG:FM summing ratio, MEASURED from the owner's
  // paired SNDTEST captures.
  //   * baseline = psg << 2: upstream PC-88's heard board mix joins the SSG at
  //     `psg_snd => sndPSG(13 downto 2)` (PC88MiSTer.vhd:2505, joined at
  //     :2509-2513) and qemu's closed ratio SSG_ch:FM_op = 8,160:8,192 = 1.0
  //     (pc98-opna.c:372 `PSG_calc(s->ssg) << 1` over emu2149's
  //     voltbl[vol] << 4) puts one max SSG channel at 1,023 << 2 = 4,092 in our
  //     junction units (jt49_exp's LUT peaks at 1,023), where our chip-side
  //     junction runs at HALF qemu's absolute scale - the FM operator is
  //     +/-4,096 (jt08_acc `opext >>> 1`; qemu's `lt >>= 1 ... // shift right
  //     verified on real YM2608`, hw/audio/fmopn.c:3023-3025) and a full drum
  //     is +/-15,352 (((2047<<4)*15)>>5 & ~3; jt08_adpcm_gain = ymfm
  //     adpcm_a_channel::output, ymfm_adpcm.cpp:223-243), where qemu's
  //     junction carries 8,192 and 30,720 (fmopn.c init_tables "13 bits
  //     here"; :2689 + out_adpcm<<1).
  //   * the -86 board trim, MEASURED (the die stops at its pins: the SSG is
  //     `o_analog`, a separate mono ANALOG pin, fmopna_impl.c:2438-2441, while
  //     FM+ADPCM leave as the YM3016 DAC word - so the ratio between the two
  //     paths is the BOARD's analog summing network and is in NO chip model).
  //     The owner ran SNDTEST (the same register stimulus) on the real Xe10 twice and on this core once, with
  //     un-normalised line-out recordings; the WITHIN-SIDE ratio
  //     SSG(max)/FM(max) is immune to the two recorders' unrelated gains. It is
  //     measured on each segment's own STEADY-STATE plateau by class (SEG 07's
  //     440 Hz square against SEG 01's 440 Hz sine; the plateau reader and the
  //     pairing are tools/sndtest_balance.py, output in
  //     docs/probes/SNDTEST-balance-2026-09-25.txt):
  //       XE10 + PMD -8.79 dB   XE10 no PMD -8.79 dB   this core -3.03 dB
  //     and the INDEPENDENT second pairing (the SSWP 100 Hz row against the
  //     FSWP 100 Hz row, both nominal 0 dB) agrees to 0.05 dB on every file
  //     (-8.75, -8.74, -2.99). The machine reproduced itself to 0.01 dB across
  //     the two sessions, so 5.76 dB of SSG leg is hot and the FM leg is taken
  //     as right - which is also the physically sensible direction (the board's
  //     summing network attenuates the SSG against the FM).
  //     psg_snd * 33/16 = 2.0625 is -5.756 dB off the psg << 2 baseline, i.e.
  //     it lands this core at -8.77 dB against the machine's -8.79 (0.02 dB),
  //     where the nearest single-shift constant (psg << 1, -6.02 dB) lands at
  //     -9.03 and misses by 0.26 dB - real, not noise, at a repeatability of
  //     0.01-0.05 dB. Verified against the module before landing:
  //     tb_pc9821_opna_sndtest_balance measures -2.99 dB with the old join,
  //     i.e. the capture and the RTL agree to 0.04 dB on this side.
  //     The analog capture chain cannot have distorted this ratio materially:
  //     the machine's own SSG sweep is flat within 0.35 dB from 100 Hz to 4 kHz
  //     and its FM sweep within 0.1 dB to 2 kHz (the chains' own response was
  //     measured too), the SSG square's
  //     harmonics are intact on the machine (its 3rd is -9.5 dB, the ideal
  //     -9.54), and the FM at 440 Hz is a sine whose power is below 1 kHz.
  //     tb_pc9821_opna_sndtest_balance is the fail-first for this number, with
  //     the expected ratio taken from the capture rows above.
  //   * the drum/FM side is unchanged and die-exact (drum-hit/bed matches the
  //     machine to 0.0 +/- 0.3 dB paired; the die's gain laws are 0-mismatch
  //     against YM2608-LLE).
  //   * the owner's re-ranking is recorded: for the FM/SSG BALANCE the upstream
  //     PC-88 Verilog is the baseline OVER NP2kai's absolute SSG gain (a
  //     software mix knob) - and the real machine outranks both for the board
  //     trim ("when the real hardware says something different from both, the
  //     hardware wins"). ymfm's s_amplitudes[31] = 16,382/ch (its MixTo1 2/3
  //     mix puts a max channel at 0.333 of its clamp rail, 6.4-7.5 dB above
  //     the machine's ~0.14-0.16, 20*log10(0.333/0.14..0.16)) and NP2kai's vol_ssg absolutes are
  //     deliberately unused. The A-11 `<< 3` history is why both the
  //     baseline and the correction are stated separately above: the units
  //     question (qemu-full vs our half-scale junction) and the board-trim
  //     question (recordings) are different errors and only the latter is
  //     addressed here.
  // The -86 board AC-COUPLES the SSG before it is summed into the YM3016 FM/DAC
  // output: the SSG leaves pin 27 with a ~2 V DC offset (a YM2149-style unipolar
  // output, which jt49 models), passes the series coupling capacitor C7C1, and
  // only then is summed equally into L/R.
  // A series cap is a 1-pole high-pass:
  //   y[n] = x[n] - x[n-1] + a*y[n-1],  a = 1 - 2^-N
  // clocked on the SSG's own sample rate. The SSG sample word (jt49's `sound`,
  // jt49.v:174-193) updates once every 4 clk_en_ssg pulses; jt12_div divides cen
  // by 4 for the SSG at the YM2608 reset setting (jt12_div.v:60-99), so that is
  // once every 16 cen = 7.9872 MHz / 16 = 499.2 kHz. N=14 puts the cutoff at
  // fc = fs*2^-N/2pi ~= 4.85 Hz - coupling-cap-like and well below 20 Hz (the
  // exact -86 cap value is not published; see the lane FIX_REPORT).
  //
  // The filter runs on the JOIN-SCALE integer, not the raw 12-bit psg_snd: one
  // max channel (jt49_exp's LUT peak 1,023) is then a 0..2,109 square wave the
  // mix carries (three channels: 0..6,329), which is what the AC coupling has
  // to centre. The join's floor is <=15/16 LSB on values that are not multiples
  // of 16 - at most -62 dB relative to a max channel - and the coupling removes
  // whatever DC is left either way. The
  // accumulator keeps SSG_DC_F=16 fractional bits so
  // the a=1-2^-N leak term is never truncated to zero (the DC-blocker precision
  // trap): the DC component scaled by 2^F is far above 2^N, so (state >>> N) is
  // non-zero and the DC is actually removed, not merely shrunk. The state is a
  // continuous DSP register clocked by a clock-enable (ssg_cen), which the
  // Single-Cycle Event Discipline permits; ssg_cen is a 1-clk pulse with exactly
  // one consumer (this filter).
  localparam integer SSG_DC_N = 14;   // a = 1 - 2^-14; fc ~= 4.85 Hz at 499.2 kHz
  localparam integer SSG_DC_F = 16;   // accumulator fractional bits (2^-16 per LSB)

  reg  [3:0]         ssg_div;         // cen / 16 = the SSG sample rate (499.2 kHz)
  reg  signed [17:0] ssg_x_prev;      // previous join-scale SSG sample (psg * 33/16)
  reg  signed [31:0] ssg_hp_state;    // 1-pole high-pass state, 16 fractional bits
  wire               ssg_cen = cen & (ssg_div == 4'd15);
  // THE JOIN UNIT (the big comment above): psg_snd * 33/16 - the psg << 2
  // baseline times the MEASURED board trim 33/64. The multiply is 12x6 bits;
  // the three-channel maximum 3,069 joins at 6,329, inside the 18-bit signed
  // path (131,071) with ssg_d likewise bounded.
  localparam [5:0]   SSG_JOIN_NUM   = 6'd33; // join = psg_snd * SSG_JOIN_NUM / 16
  localparam integer SSG_JOIN_SHIFT = 4;
  wire [17:0]        ssg_prod = psg_snd * SSG_JOIN_NUM;       // 0..135,135
  wire signed [17:0] ssg_x    = ssg_prod >> SSG_JOIN_SHIFT;   // >>4 -> 0..8,445
  wire signed [17:0] ssg_d    = ssg_x - ssg_x_prev;           // ±8,445, fits 18-bit signed
  wire signed [31:0] ssg_dw   = $signed({{14{ssg_d[17]}}, ssg_d});  // sign-extend to the accumulator width
  // The AC-coupled (zero-mean) SSG term at the mix join, sign-extended to 20 bits.
  wire signed [19:0] ssg_ac  = { {4{ssg_hp_state[31]}}, ssg_hp_state[31:16] };

  always @(posedge clk) begin
    if (reset) begin
      ssg_div      <= 4'd0;
      ssg_x_prev   <= 18'sd0;
      ssg_hp_state <= 32'sd0;
    end else begin
      if (cen) ssg_div <= ssg_div + 4'd1;
      if (ssg_cen) begin
        ssg_x_prev   <= ssg_x;
        ssg_hp_state <= (ssg_dw <<< SSG_DC_F) + ssg_hp_state - (ssg_hp_state >>> SSG_DC_N);
      end
    end
  end

  wire signed [19:0] mix_l = fm_l + ssg_ac;
  wire signed [19:0] mix_r = fm_r + ssg_ac;

  assign snd_l = mix_l;
  assign snd_r = mix_r;

  assign irq = ~op_irq_n;

endmodule

`default_nettype wire

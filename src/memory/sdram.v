// SDRAM controller for Tang and MiSTer SDRAM modules -- nand2mario
//
// A 32-bit low-latency controller for 32/64/128MB MiSTer SDRAM modules; a 128MB module holds
// two complementary-CS 64MB chips. The timings below are derived from FREQ, up to 133 MHz.
//
// Latencies (CAS = 2 below 100 MHz, 3 at 100 MHz and up; CAS_I below):
// - Read latency is T_RCD + CAS + 2*burst_cnt - 1 cycles from ACT to last data.
// - Write latency: ACT at t0, low-half write at t=T_RCD, high-half write at t=T_RCD+2
//   (auto-precharge on the high half), ack after T_WR+T_RP from the high half.
// - Read burst of at most 15 dwords; one crossing a row boundary is split AT it, one ACT each.
// - Write is a single 32-bit word with byte-enable support, EXCEPT PORT 0's TWO-word pair:
//   burst_cnt == 2 holds the row open for two columns, the second on din0_hi, and is split
//   the same way when its row cannot hold it whole. A write on any OTHER port
//   is one word whatever its count says (`ef_wr_burst`'s port term): only port 0 has an upper
//   payload word to write.
// - Refresh is done automatically at the next IDLE after the counter expires (refresh_allowed==1).
// - FOUR requesters are served ROUND-ROBIN, not by fixed priority (see the arbiter below).
//   The scheme that stood here starved the non-CPU requesters.
// - PORT 0's GATHER-RMW SESSION (G3): a write with `gath0` set carries up to
//   GATHER_K same-row partial stores (the PEGC posted store buffer's drain; entry 0 on
//   addr0/din0/be0, entries 1.. on gath0_extra), and is serviced as ONE session:
//   one ACT, one length-1 half READ per half any entry's be touches with SOME but not
//   ALL of its bytes, one DQ turnaround, one merged half WRITE per touched half
//   (auto-precharge on the last), one precharge exit. The row stays open across the
//   reads and the writes, so K byte stores cost one ACT and one precharge between them
//   instead of the single-RMW path's per-store re-ACT. Entries must share the physical
//   row of entry 0 (asserted below); only port 0 can gather.

module sdram
#(
    parameter         FREQ = 64_800_000,
    parameter         HAS_DQM = 1'b1,     // 1: DQM is a SEPARATE pin (conventional SDRAM wiring).
    // 1: DQM rides A[12:11] (the MiSTer 128MB XSDS module wires the chips' DQML/DQMH to A11/A12),
    // so the byte mask is placed on a[12:11] during a WRITE and no read-modify-write is needed.
    // Mutually exclusive with HAS_DQM. See docs/sdram-dqm-wiring.md.
    parameter         ADQM = 1'b0,
    parameter         FAST_GRADE = 1'b1,  // 1: Alliance -6 speed grade, 0: -7 speed grade
    // 1 keeps the speculative pre-ACT (+15-18% on the 4-way TDM mix); 0 compiles
    // its pnd_* reservation out, returning the row activate to the accept's serial path.
    parameter         PRE_ACT = 1'b1,
    // G3 gather-RMW session: the most entries one session carries (1..GATHER_MAX). The
    // caller's request count (burst_cnt0 with gath0) must never exceed it; the upper
    // gath0_extra slots are then read by nothing and fold out of the netlist.
    parameter integer GATHER_K = 4
)
(
    // SDRAM side interface (16-bit data bus)
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output     [1:0]  SDRAM_DQM,
    output reg [1:0]  SDRAM_BA,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output reg        SDRAM_nCS,
    output            SDRAM_CKE,    // always 1

    // Logic side interface (32-bit)
    input             clk,
    input             resetn,
    input             nce,            // for x2 wrapper, 1: do not accept new request or auto-refresh 
    input             refresh_allowed,      // set to 1 to allow auto-refresh
    output            busy,
    input       [1:0] sdram_size,    // 1/2/3 = 32/64/128MB; 0 uses 32MB geometry

    // 4 requesters, round-robin (valid/ready handshake; a request is held until ready)
    input             valid0,       // request valid (held until ready)
    output            ready0,       // 1-cycle pulse: request accepted
    input             wr0,          // 1: write (single dword), 0: read
    input      [26:0] addr0,        // byte address (bits [1:0] ignored)
    input      [31:0] din0,         // 32-bit write data
    // A CONTROLLER feature kept for tb_pc9821_sdram_wburst; the core's one caller is
    // pc9821_pegc_storebuf's pair drain (split_sdram_backend's mem0_din_hi).
    input      [31:0] din0_hi,      // port 0's two-word write: word 1 of the burst
    // PORT 0's GATHER-RMW SESSION request (the header): gath0 qualifies the request as a
    // gather of `burst_cnt0` (1..GATHER_K) same-row partial stores; entry 0 rides
    // addr0/din0/be0 and entry j (1..) is gath0_extra[(j-1)*GENT_W +: GENT_W] =
    // {addr[26:0], din[31:0], be[3:0]}. The extra entries' row bits are assertion-only
    // (the session serves every entry's own COLUMN against entry 0's row), so at
    // GATHER_K < 8 the unused upper slots are pruned whole.
    input             gath0,
    input      [440:0] gath0_extra,   // 7 x GENT_W; GENT_W/GATHER_MAX below
    output     [31:0] dout0,        // 32-bit read data, valid in the resp_valid0 cycle only
    input       [3:0] be0,          // byte enable
    output            resp_valid0,  // pulses when a 32-bit read word is ready
    input       [3:0] burst_cnt0,   // read burst dwords (max 15); write burst dwords when wr0
    output            burst_done0,  // pulses when read burst completes

    input             valid1,
    output            ready1,
    input             wr1,
    input      [26:0] addr1,
    input      [31:0] din1,
    output     [31:0] dout1,
    input       [3:0] be1,
    output            resp_valid1,
    input       [3:0] burst_cnt1,
    output            burst_done1,

    input             valid2,
    output            ready2,
    input             wr2,
    input      [26:0] addr2,
    input      [31:0] din2,
    output     [31:0] dout2,
    input       [3:0] be2,
    output            resp_valid2,
    input       [3:0] burst_cnt2,
    output            burst_done2,

    // Requester 3: the GVRAM scanout's line fetch. The
    // controller serves it round-robin like the other three; pc9821_gvram's own sb_* port
    // drives it through split_sdram_backend's mem3_*.
    input             valid3,
    output            ready3,
    input             wr3,
    input      [26:0] addr3,
    input      [31:0] din3,
    output     [31:0] dout3,
    input       [3:0] be3,
    output            resp_valid3,
    input       [3:0] burst_cnt3,
    output            burst_done3
);

localparam integer GATHER_MAX = 8;         // the widest gather the payload can carry
localparam integer GENT_W     = 27 + 32 + 4;  // {addr, din, be} per extra gather entry

function integer ns_to_cycles;
    input integer ns;
    integer prod;
    begin
        prod = ns * ((FREQ + 999) / 1000);
        ns_to_cycles = (prod + 1_000_000 - 1) / 1_000_000;
        if (ns_to_cycles < 1)
            ns_to_cycles = 1;
    end
endfunction

// Alliance AS4C64M8SD-7TCN Table 13 (the XS-DS module's -7 part, and the grade z486_mister.sv
// builds with FAST_GRADE=1'b0): tRP = 20ns, tRCD = 20ns, tRC = 67ns, tWR = 15ns. These were
// 21/21/63/14 -- generic -7 guesses; the datasheet supersedes them. The -6 column keeps this
// tree's historical 18/18/60/12 (no -6 datasheet in hand, and nothing in the build selects it).
localparam integer T_RP_NS = FAST_GRADE ? 18 : 20;
localparam integer T_RCD_NS = FAST_GRADE ? 18 : 20;
localparam integer T_RC_NS = FAST_GRADE ? 60 : 67;
localparam integer T_WR_NS = FAST_GRADE ? 12 : 15;

// CAS latency: CL2 strictly BELOW 100 MHz, CL3 at 100 MHz and up (owner decision 2026-10-13).
// Hardware evidence (two DE10-Nano boards, source 56eadc9a, clk_sys = SDRAM = 100 MHz, the
// disk-integrity probe): CL2 failed on one board for 9 of 11 placements; CL3 passed on both
// boards for 4 of the first 6 placements screened (the other 2 failed on both boards, the
// pattern of an internal-path placement failure, not the SDRAM). 95 MHz CL2 passed the full
// 8-item regression on both boards. Timing model: tools/profile_gen.py derive_sdram_phase
// gives a worst I/O slack of +0.246 ns at 80..95 MHz (out_hold; read capture in_setup +0.351
// at 95) but +0.035 ns at 100 MHz (in_setup, the read capture, slow 100C corner), and at
// 100 MHz CL2's tRCD/tRP = 2 cycles = 20 ns are exactly the -7 grade's minimum (Table 13
// above). The datasheet's CL2 minimum tCK for the -7 part is NOT cited in this tree (the
// strict XSDS model carries the -6 part's tCK_CL2_MIN = 10.0 ns): unverified, so this
// cutover rests on the hardware evidence.
localparam integer CAS_I   = (FREQ < 100_000_000) ? 2 : 3;
// T_RC and T_WR deliberately take NO <=75MHz shortcut either (review F6). The shortcut
// emitted 4 cycles of tRC and 1 of tWR for every FREQ <= 75MHz: at 75MHz that is 53.3ns /
// 13.3ns against the AS4C64M8SD-7's 67ns tRC and 15ns tWR, so it broke the -7 grade (and the
// -6 grade above 66.7MHz), including the module default 64.8MHz / FAST_GRADE=0 (4 cycles =
// 61.7ns < 67ns). ns_to_cycles is a correct ceiling at EVERY frequency (and gives the same or
// smaller values below ~60MHz, where the shortcut over-counted), so the shortcut is gone.
localparam integer T_WR_I  = ns_to_cycles(T_WR_NS);
localparam integer T_MRD_I = 2;
// T_RP and T_RCD never took the <=75MHz shortcut T_RC/T_WR used to (review F6 now removed
// that one too). The shortcut emitted ONE cycle for every FREQ <= 75MHz, which is only legal
// while one clock already covers tRCD/tRP: exactly 20ns at 50MHz for the -7 part (zero margin),
// and short at 64.8MHz (15.4ns < 20ns). ns_to_cycles derives the ceiling at every frequency.
localparam integer T_RP_I  = ns_to_cycles(T_RP_NS);
localparam integer T_RCD_I = ns_to_cycles(T_RCD_NS);
localparam integer T_RC_I  = ns_to_cycles(T_RC_NS);
localparam integer T_DAL_I = T_WR_I + T_RP_I;

// CAS and the timing intervals are declared at their MINIMUM width, and every comparison
// against them elsewhere in this file zero-extends the parameter. Verilator reports each one as
// WIDTHEXPAND; the extension is EXACT, because each value is bounded well inside 4 bits at any
// supported FREQ (T_RC is the largest, 9 cycles at 133 MHz). Widening these to match their
// comparands was tried and does NOT remove the warnings - it moves them onto the initialisers,
// because the values arrive through `integer` - so they are waived where they fire instead.
// T_WR had no reader at all: the write path reaches T_WR_I through T_DAL_I. Removed rather than
// left looking like a timing knob that nothing consults.
localparam [3:0] CAS   = CAS_I[3:0];
localparam [3:0] T_MRD = T_MRD_I[3:0];
localparam [3:0] T_RP  = T_RP_I[3:0];
localparam [3:0] T_RCD = T_RCD_I[3:0];
localparam [3:0] T_RC  = T_RC_I[3:0];

generate
if (FREQ > 133_000_000) begin : gen_freq_check
    initial
        $error("ERROR: This timing table is only characterized up to 133MHz.");
end
endgenerate

/* verilator lint_off PROCASSINIT */   // NO reset arm assigns busy_buf, so this initialiser IS
                                      // its power-up value and must be BUSY until the init
                                      // sequence finishes, or the controller accepts a request
                                      // before the SDRAM is out of its 200us calibration.
reg busy_buf = 1'b1;
/* verilator lint_on PROCASSINIT */
reg nce_r;
always @(posedge clk) nce_r <= nce;
reg busy_r;
always @(posedge clk) busy_r <= busy;
assign busy = ~nce_r ? busy_buf : busy_r;    // use busy_buf value the next cycle of CE

// Tri-state DQ
reg        dq_oen;          // 0: drive dq_out, 1: Hi-Z
reg [15:0] dq_out;
assign SDRAM_DQ = dq_oen ? {16{1'bZ}} : dq_out;
wire [15:0] dq_in = SDRAM_DQ;

// Single registered DQ capture.  This is the ONLY register that reads the DQ
// pins, so FAST_INPUT_REGISTER packs it into the IOB input cell -> deterministic,
// placement-independent read timing (previously rd_lo16/dout_word/dout_buf each
// read the raw pin, so only one could pack into the IOB and the rest captured
// through placement-dependent fabric routing).  dq_r lags dq_in by one cycle, so
// the READ/RMW_READ capture thresholds below are pushed out by 1.
reg  [15:0] dq_r;
always @(posedge clk) dq_r <= dq_in;

// Command/address
// THE COMMAND REGISTER MUST POWER UP IN NOP (2026-10-05). tb_pc9821_sdram_strict, driving this
// controller into the XSDS strict module model, caught the module being handed a
// MODE_REGISTER_SET at 5.5 ns. The cause is here: the strobes are combinational from `cmd`
// (assign below), `cmd` had no power-up value, and 3'b000 IS CMD_SetModeReg - so from the
// moment the FPGA configured until the reset arm clocked once, the module's pins carried CS=0
// with RAS=CAS=WE=0, an MRS whose address carried mode register 0 (an illegal CL0, a wrong
// burst length). The SDRAM controller guide warns that a violated power-up sequence "may lead to
// unpredictable start-up modes", and an unpredictable mode register IS a wrong CAS latency -
// stale or corrupt reads. The 200 us hold itself already existed (rst_cnt below, counted after
// resetn rises, so the FPGA's configuration time adds to it); this initialiser is the missing
// half. `a` is given one too so no address is left undefined either.
/* verilator lint_off PROCASSINIT */   // the initialisers ARE the power-up values (the note above);
                                      // the FSM then assigns both procedurally, as intended
reg [2:0]  cmd = 3'b111;   // NOP at power-up (see the note above; 3'b000 is CMD_SetModeReg)
reg [12:0] a = 13'd0;
// dqm_a: a TWIN of a[12:11] for the SDRAM_DQML/DQMH pins.
// Every full-width write of `a` goes through ax() into {dqm_a, a}, so dqm_a == a[12:11] on every
// cycle by construction (the two partial writes, a[10] and a[10:0], never touch bits 12:11), and
// the pins carry exactly what they carried when they were wired to a[12:11]. Its reason is
// Quartus 17.0.2: with one register driving both SDRAM_A[12:11] and SDRAM_DQM*, the fitter
// duplicates it into the two fast output registers, and on some netlists that duplication ends
// in the DTM internal error (dtm_node.cpp:772). dont_merge keeps
// synthesis from folding the twin back into a[12:11].
(* dont_merge *) reg [1:0] dqm_a = 2'b00;
/* verilator lint_on PROCASSINIT */
function [14:0] ax(input [12:0] v);
    ax = {v[12:11], v};
endfunction
reg [1:0]  dqm_mask;
assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
assign SDRAM_A  = a;
// MiSTer SDRAM modules repurpose the DQM connector pins as the upper
// address bits. Drive real byte masks only on conventional SDRAM wiring.
assign SDRAM_DQM = HAS_DQM ? dqm_mask : dqm_a;
`ifdef VERILATOR
always @(posedge clk)
    if (dqm_a !== a[12:11])
        $fatal(1, "sdram: dqm_a %b != a[12:11] %b (the DQM twin must equal it every cycle)",
               dqm_a, a[12:11]);
`endif
assign SDRAM_CKE= 1'b1;

// Per-port ready pulse (1 cycle, request accepted)
reg [3:0] ready_pulse;
assign ready0 = ready_pulse[0];
assign ready1 = ready_pulse[1];
assign ready2 = ready_pulse[2];
assign ready3 = ready_pulse[3];

// Read data path
// doutN IS VALID ONLY IN ITS resp_validN CYCLE (area-recovery, 2026-10-08). The only
// instantiation is sdram_sync_bridge, which keeps port 0's hold for its readers (ports 1-3 are
// read in their own resp_valid cycle); the clock bridge this was written against, removed since,
// likewise read ctrl_dout[p] solely under ctrl_resp[p] and kept its own per-port hold. So the four per-port holding registers this module used to keep - 128 flops in the
// clk_sdram domain plus a 2:1 mux per port - were never observed, and every port now
// presents the one completed word (proved differentially against the pre-change
// controller+bridge pair).
reg  [31:0] dout_word;             // most recent completed word (active port)
reg         data_resp_pulse;       // 1-cycle pulse when a 32-bit word completes

assign resp_valid0 = (req_id_buf == 2'd0) ? data_resp_pulse : 1'b0;
assign resp_valid1 = (req_id_buf == 2'd1) ? data_resp_pulse : 1'b0;
assign resp_valid2 = (req_id_buf == 2'd2) ? data_resp_pulse : 1'b0;
assign resp_valid3 = (req_id_buf == 2'd3) ? data_resp_pulse : 1'b0;

assign dout0  = dout_word;
assign dout1  = dout_word;
assign dout2  = dout_word;
assign dout3  = dout_word;

// Burst-done pulse (on final word of a read burst)
reg burst_done_pulse;
assign burst_done0 = (req_id_buf == 2'd0) ? burst_done_pulse : 1'b0;
assign burst_done1 = (req_id_buf == 2'd1) ? burst_done_pulse : 1'b0;
assign burst_done2 = (req_id_buf == 2'd2) ? burst_done_pulse : 1'b0;
assign burst_done3 = (req_id_buf == 2'd3) ? burst_done_pulse : 1'b0;

// FSM. ACT is the row-activate stage: IDLE latches the granted request and ACT issues the row
// from those latches one cycle later, so the arbiter -> address mux -> pin-register path is one
// register shorter. Every requester pays one
// clk_sdram cycle per
// accepted request for it, and REFRESH_DELAY below counts that cycle.
reg [3:0] state;
localparam INIT     = 4'd0;
localparam CONFIG   = 4'd1;
localparam IDLE     = 4'd2;
localparam ACT      = 4'd3;
localparam READ     = 4'd4;
localparam RMW_READ = 4'd5;
localparam WRITE    = 4'd6;
localparam REFRESH  = 4'd7;
localparam RMW_ACT  = 4'd8;
localparam WRITE_BURST = 4'd9;   // port 0's opt-in multi-word write (burst_cnt >= 2)
localparam WRITE_BURST_ACT= 4'd10;  // ... and the same for the write pair
localparam GATH_RD = 4'd11;      // G3 gather-RMW session: the half reads (row stays open)
localparam GATH_WR = 4'd12;      // ... and the merged half writes back to the same columns

// RAS# CAS# WE#
localparam CMD_SetModeReg  = 3'b000;
localparam CMD_AutoRefresh = 3'b001;
localparam CMD_PreCharge   = 3'b010;
localparam CMD_BankActivate= 3'b011;
localparam CMD_Write       = 3'b100;
localparam CMD_Read        = 3'b101;
localparam CMD_NOP         = 3'b111;

// Mode register: burst length = 1, sequential
localparam [2:0] BURST_LEN   = 3'b000;   // 1
localparam       BURST_MODE  = 1'b0;     // sequential
localparam [10:0] MODE_REG   = {4'b0000, CAS[2:0], BURST_MODE, BURST_LEN};

// Refresh period. tREFI is 64ms/8192 rows = FREQ/128000 cycles (390.625 at 50MHz), and the
// counter target must sit BELOW it by the whole gap from "refresh_cnt expired" to "REFRESH on
// the pins": two registered cycles (need_refresh, then cmd) plus one in-flight transaction,
// because a refresh is only issued from IDLE and an accepted burst cannot be interrupted. The
// longest legal transaction is a 15-dword read that SPLITS
// (the first row takes what fits, 1 dword worst case, then the second row's ACT and its 14 dwords),
// so the margin is both
// ACT/T_RCD/CAS chains, the second ACT's own cycle, and the ACT stage every transaction pays.
// Measured without this margin: the pin-to-pin interval was 392 cycles at rest -- 0.35% over
// tREFI, so the counter missed tREFI even when idle -- and 395 under a saturating 4-dword stream
// (1.1% over the 64ms budget). A pre-ACT reservation
// needs no term of its own: it is
// made only while no refresh is pending, and it adds one fixed three-cycle data drain plus that
// same longest READ before the refresh. The G3 gather session is the OTHER long transaction
// (GATHER_K entries of two-half read-merge-write under one ACT): its accept-to-IDLE is
// 1 + w0 + wtot + T_DAL_I - 2 with w0 <= T_RCD+CAS+2*GATHER_K and wtot <= 2*GATHER_K, so the
// same two-cycle margin is T_RCD+CAS+4*GATHER_K+T_DAL_I+1 -- below the read-split term at
// GATHER_K <= 7 and at every supported FREQ except the 133MHz corner, where the max binds.
localparam integer REFRESH_DELAY_READS = 3 + (T_RCD_I + CAS_I + 2*1 - 1)
                                      + (T_RCD_I + CAS_I + 2*14 - 1) + 2 + 1;
localparam integer REFRESH_DELAY_GATH = T_RCD_I + CAS_I + 4*GATHER_K + T_DAL_I + 1;
localparam integer REFRESH_DELAY  = (REFRESH_DELAY_GATH > REFRESH_DELAY_READS)
                                      ? REFRESH_DELAY_GATH : REFRESH_DELAY_READS;
localparam integer REFRESH_RAW    = (FREQ/1000) * 64 / 8192;
localparam integer REFRESH_TARGET = REFRESH_RAW - REFRESH_DELAY;
// At a test frequency (1MHz in tb_sdram_size) tREFI is shorter in cycles than the delay, so the
// margin cannot apply; keep the raw tREFI there or the refresh would re-arm during its own
// REFRESH state and starve every request.
localparam integer REFRESH_CYCLES = (REFRESH_TARGET < 1) ? REFRESH_RAW : REFRESH_TARGET;
localparam integer REFRESH_CNT_W = (REFRESH_CYCLES < 2) ? 1 : $clog2(REFRESH_CYCLES + 1);

reg cfg_now;
reg [3:0] cfg_cbr;         // init AutoRefreshes (CBR) issued so far for the current chip

reg [4:0]  cycle;             // small scheduler counter (saturates)
/* verilator lint_off UNUSEDSIGNAL */   // Only [25:2] are ever read. [26] is the second-chip
                                      // select and is latched separately as req_chip_buf; [1:0]
                                      // is the byte within the dword, which this controller
                                      // ignores by contract (see the addr0 port comment).
reg [26:0] addr_buf;
/* verilator lint_on UNUSEDSIGNAL */
reg [31:0] din_buf;
reg [31:0] din_hi_buf;        // port 0's two-word write payload, word 1 (word 0 is din_buf)
reg [3:0]  be_buf;
reg [1:0]  req_id_buf;
reg        req_wr_buf;        // granted request's wr/be/burst, held for the ACT stage below
reg [3:0]  burst_buf;
reg        wr_split;          // the pair starts in the row's LAST column, so it spans two rows
reg        wr_second;         // WRITE_BURST is writing the pair's second row
reg [2:0]  wr_seg_h;          // halves in the write burst's CURRENT row segment
// The two-word write: burst_cnt == 2 EXACTLY, ON PORT 0 ONLY. Any other count - and any other
// port, whose upper payload word does not exist - selects the single-word path, which is what a
// write's burst count has ALWAYS meant here: the controller writes one word and the count is
// ignored, so no existing caller's behaviour moves. The GVRAM was the only port-0 caller that
// presented 2 and it is M10K now, so nothing in the
// core presents it. THE PORT TERM IS THE FIX, not a tidiness change: without it a burst_cnt == 2
// write on ports 1/2/3 took this path as well, latched port 0's `din0_hi` as its second word (tied
// to 32'd0 in this machine) and wrote four zero bytes the caller never asked for. Latent until
// then - no live caller presents 2 (z486's L1 store drain 8'd1, its line fill 8'd4 on a READ, the
// loader and the PCM buffer 8'd1, the font reader 8) - so tb_pc9821_sdram's port-1 arm is the
// stimulus that reaches it, and split_sdram_backend's port-0 guard names the next caller that asks.
// A gather request is NEVER the pair: burst_buf is its entry count, not a burst shape.
wire [3:0] ef_wr_burst = ((req_id_buf == 2'd0) && !req_gath_buf && (burst_buf == 4'd2)) ? 4'd2 : 4'd1;
reg        req_gath_buf;        // the granted request is a gather session
reg        req_large_buf;
reg        req_chip_buf;
reg        init_chip;

// Speculative pre-ACT. Once the running read has issued every CAS its
// command bus is idle until the data drains, so the row of the NEXT request is activated then
// and `cycle` continues from it at the accept. The reservation is HELD, not acknowledged: ready
// still pulses at the accept, so the one-accept-per-transaction and response-order contract is
// unchanged; only the ACT and its T_RCD leave the accept's serial path.
reg        pnd_valid;         // a row is open for the request latched below
reg        pnd_go;            // issue that BankActivate this cycle
reg  [1:0] pnd_id;
reg [26:0] pnd_addr;
reg        pnd_chip;
reg        pnd_large;
reg  [4:0] pnd_age;           // cycles since the pre-ACT was issued

reg [REFRESH_CNT_W-1:0] refresh_cnt;
reg        need_refresh;

// READ pipeline counters (16-bit halfwords)
reg [4:0]  rd_total_halfs;    // = 2 * effective dword count (<= 30)
reg [4:0]  rd_seg_halfs;      // halves the burst's FIRST row holds; the rest needs a second ACT
reg        rd_row2;           // that second row has been opened (the split must fire once)
reg [4:0]  rd_issued;         // # of CAS commands already issued
reg [4:0]  rd_received;       // # of 16-bit words captured from dq
reg [8:0]  rd_col_base;       // starting dword column (0..511)
// The `cycle` value at which this read's FIRST CAS is issued: T_RCD for a normal ACT, the
// pre-ACT's elapsed age (never below T_RCD) for a reserved one. The data capture is keyed to
// THIS, not to the ACT, because a reserved read enters READ with `cycle` already past T_RCD.
reg [4:0]  rd_cas0;
reg [15:0] rd_lo16;           // latch low-half before composing 32-bit
reg [1:0]  rmw_issued;
reg [1:0]  rmw_received;
reg [1:0]  rmw_total_reads;
reg [1:0]  rmw_read_halfs;
reg [31:0] rmw_old_data;
reg [1:0]  wr_halfs;          // bit0=write low 16-bit half, bit1=write high 16-bit half

// ---- G3 gather-RMW session state (the header) ----
// One latched copy per session entry: the column it writes, its data and byte enables,
// and the read half that merges into it. gk_rmap/gk_wmap are REGISTERED at the accept
// (a pure function of the accepted be masks and entry count): read slot s is the s-th half
// any entry touches with SOME but not ALL of its bytes, write slot s is the s-th touched
// half, both in entry order, low half first. They are stable for the whole session, so the
// registered value equals the old combinational value at every consumer cycle (the
// first consumer, GATH_RD, is >= 2 cycles after the accept).
reg  [8:0] gk_col  [0:GATHER_MAX-1];
reg [31:0] gk_din  [0:GATHER_MAX-1];
reg  [3:0] gk_be   [0:GATHER_MAX-1];
reg [31:0] gk_old  [0:GATHER_MAX-1];
reg  [5:0] gk_ri, gk_rc;        // read slots issued / captured
reg  [5:0] gk_wc;               // write-phase cycle counter (the session outgrows `cycle`)
reg  [3:0] gk_rmap [0:2*GATHER_MAX-1];   // {entry[2:0], half}
reg  [3:0] gk_wmap [0:2*GATHER_MAX-1];
reg  [5:0] gk_rtot, gk_wtot;

// The slot maps and totals are computed at the ACCEPT (see the gk_latch block below),
// from the same per-entry be masks and entry count that latch there. Registering them
// moves the 7-level entry-count -> gk_wmap scan off the gk_be -> dq_out clk_sdram cone;
// they are pure functions of the accepted be masks and stable for the whole session, so
// the registered value equals the old combinational value at every consumer cycle (the
// first consumer, GATH_RD, is >= 2 cycles after the accept).

// The write stream's merge: write slot s writes the merged half of its entry - the read
// half with its be bytes replaced - and a half no entry byte touches is not written at
// all (it is not in the map). A half whose be fills it both ways merges to the new half
// alone, so a full-half entry needs no read and the one expression covers both.
//
// Class-1 depth cut (sdram-hunt, the gk_n -> gk_wmap -> dq_out clk_sdram cone): the
// per-byte new-vs-old select is hoisted OUT of the critical path into a per-entry
// pre-computed 32-bit merged word (gk_mword, a pure function of the gk_be/gk_din/
// gk_old registers), so the critical tail pays only the 4-entry word mux and a single
// half select instead of the array-read mux plus the two-level byte merge.
// Value-identical: gk_mword[ee] is byte_merge(din[ee], old[ee], be[ee]) and gk_wdat is
// the selected half of it, exactly the old expression. Proven over every free input by SAT
// (14 -> 12 4-LUT levels on the cone); tb_pc9821_gather_cone_equiv replays it.
//
// Class-2 pipeline (pegc-slotmap-pipeline, owner-authorized latency stage): the slot
// maps themselves are now REGISTERED at the accept, so the gk_n -> gk_wmap -> dq_out
// combinational cone above no longer exists (gk_wmap[gk_wc] reads a flop). The gk_mword
// hoist stays: it is the per-entry merged word the write tail selects a half of, and it
// keeps the tail at a 4-entry word mux plus one half select.
wire [31:0] gk_mword [0:GATHER_K-1];
generate
    genvar gme;
    for (gme = 0; gme < GATHER_K; gme = gme + 1) begin : gen_gk_mword
        assign gk_mword[gme] = {
            gk_be[gme][3] ? gk_din[gme][31:24] : gk_old[gme][31:24],
            gk_be[gme][2] ? gk_din[gme][23:16] : gk_old[gme][23:16],
            gk_be[gme][1] ? gk_din[gme][15:8]  : gk_old[gme][15:8],
            gk_be[gme][0] ? gk_din[gme][7:0]   : gk_old[gme][7:0]};
    end
endgenerate
wire  [2:0] gk_ws   = gk_wmap[gk_wc[3:0]][2:0];   // gk_wmap[s][3] is gi[2], always 0 (gi < GATHER_K)
wire  [1:0] gk_ws_e = gk_ws[2:1];   // entry index 0..3
wire        gk_ws_h = gk_ws[0];
wire [15:0] gk_wdat = gk_ws_h ? gk_mword[gk_ws_e][31:16] : gk_mword[gk_ws_e][15:0];

// ADQM (the "GD" gather): with the byte mask riding a[12:11] there is nothing to read and
// nothing to merge, so the session is ACT + one masked WRITE per touched half. The data is
// the entry's OWN half and the mask is its own byte enables; gk_rtot is forced to 0 at the
// accept, which makes GATH_RD issue no reads and turns gk_w0 into T_RCD.
wire [2:0]  gk_ws_gi  = {1'b0, gk_ws_e};   // gk_din/gk_be are [0:GATHER_MAX-1]; the entry is < GATHER_K
wire [15:0] gk_gd_dat  = gk_ws_h ? gk_din[gk_ws_gi][31:16] : gk_din[gk_ws_gi][15:0];
wire [1:0]  gk_gd_mask = gk_ws_h ? {~gk_be[gk_ws_gi][3], ~gk_be[gk_ws_gi][2]}
                                 : {~gk_be[gk_ws_gi][1], ~gk_be[gk_ws_gi][0]};

// The cycle of the first merged write: no read at all starts at T_RCD like the plain
// write arm; otherwise the stream starts once every read has LANDED (its capture is one
// dq_r stage behind the pins) and the last read's data has left the DQ bus. Write j is
// j cycles later and needs capture j, which lands j cycles later too, so one start
// covers the whole stream.
wire  [5:0] gk_w0 = (gk_rtot == 6'd0) ? {2'b0, T_RCD}
                    : {2'b0, T_RCD} + {2'b0, CAS} + ((gk_rtot > 6'd3) ? gk_rtot : 6'd3);
wire        gk_on = (state == GATH_RD) || (state == GATH_WR);

// S1-a look-ahead (timing-wins, 0 cycles): the merged write's command fields, one slot early.
// GATH_WR walks gk_wc 0,1,2,... one slot per cycle, and the slot map, the entries' columns
// and (ADQM) data/byte enables are all latched at the accept and stable for the session, so
// the fields of the slot the NEXT cycle writes are known a cycle ahead: slot gk_wc+1 inside
// GATH_WR, slot 0 in GATH_RD (whose last cycle is always the one before the first write; it
// is the only way into GATH_WR). The pins then load from these flops and the
// gk_wmap[gk_wc] read (fan-out ~45) with its entry mux leaves the clk_sdram cones into
// dq_out and a[] (base worst: gk_wmap -> Mux0 -> Selector145 -> 5.7 ns hop -> dq_out DDIO).
// Value-identical at every write; the SIM-ONLY check below holds it. The ADQM=0 merged data
// (gk_wdat) reads gk_old, which the read capture can still update in the cycle before a
// write, so it is not looked ahead (the shipped core is ADQM=1).
wire  [5:0] gk_wn    = (state == GATH_WR) ? (gk_wc + 6'd1) : 6'd0;
wire  [3:0] gk_wn_m  = gk_wmap[gk_wn[3:0]];
wire  [2:0] gk_wn_gi = {1'b0, gk_wn_m[2:1]};
wire  [8:0] gk_wn_col = gk_col[gk_wn_m[3:1]];
reg  [15:0] gk_la_dat;          // ADQM: the slot's own half (gk_gd_dat one slot early)
reg   [1:0] gk_la_mask;         // ADQM: its DQM on a[12:11] (gk_gd_mask one slot early)
reg   [9:0] gk_la_col16;        // the slot's 16-bit column (col16 one slot early)
reg         gk_la_last;         // the slot is the session's last write (auto-precharge)
always @(posedge clk) begin
    gk_la_dat   <= gk_wn_m[0] ? gk_din[gk_wn_gi][31:16] : gk_din[gk_wn_gi][15:0];
    gk_la_mask  <= gk_wn_m[0] ? {~gk_be[gk_wn_gi][3], ~gk_be[gk_wn_gi][2]}
                              : {~gk_be[gk_wn_gi][1], ~gk_be[gk_wn_gi][0]};
    gk_la_col16 <= {req_large_buf ? gk_wn_col : {1'b0, gk_wn_col[7:0]}, gk_wn_m[0]};
    gk_la_last  <= (gk_wn == (gk_wtot - 6'd1));
end

// Row-crossing splits and the row+1 carry (review F5). {bank,row} is addr[25:11] on the large
// geometry and addr[24:10] on the small one -- 15 bits either way -- so rc_next is the NEXT
// ROW as a plain increment of that field: row 8191 of a bank carries into row 0 of the NEXT
// bank instead of wrapping back into row 0 of the same one, and on a 128MB module (two
// complementary-CS chips) the bank wrap at chip 0's end carries into chip 1. The split paths'
// ACT uses rc_next, and -- just as importantly -- the second segment's READ/WRITE COMMANDS
// must carry the same bank/chip: before the carry they could keep addr_buf's bank because the
// next row was always in it.
// The next-row field, registered AT THE ACCEPT (a re-test of S4b's refuted
// candidate, this time measured with a SWEEP PER SIDE because one fit cannot
// resolve a delta inside the ~1.06 ns placement spread). The incrementer,
// its geometry mux and the rc_chip compare leave the READ/WRITE command mux that
// rd_row2/wr_second select; they now feed registers from the request payload
// instead of the pin mux from addr_buf. Exact because rc_base is a pure function of
// addr_buf/req_large_buf/req_chip_buf, which are latched at the SAME accept.
/* verilator lint_off UNUSEDSIGNAL */   // reason: rc_of reads the {bank,row} field
// only - bit 26 (the 128MB chip select) and bits 9:0 (the column) are NOT part of the
// next-ROW field, and the callers pass the whole 27-bit address.
function [14:0] rc_of(input [26:0] ad, input lg);
    rc_of = {lg ? ad[25:24] : ad[24:23],
             lg ? ad[23:11] : ad[22:10]} + 15'd1;
endfunction
// Compute each port's chip metadata before request arbitration. Keep the exact
// increment/equality/XOR expression: a reduction-AND changes X/Z semantics.
function rc_chip_of(input [26:0] ad, input [1:0] sz);
    reg [14:0] rc_n;
    begin
        rc_n = rc_of(ad, sz[1]);
        rc_chip_of = ((sz == 2'd3) && ad[26])
                   ^ ((sz == 2'd3) && (rc_n == 15'd0));
    end
endfunction
wire [3:0] port_rc_chip = {rc_chip_of(addr3, sdram_size),
                           rc_chip_of(addr2, sdram_size),
                           rc_chip_of(addr1, sdram_size),
                           rc_chip_of(addr0, sdram_size)};
/* verilator lint_on UNUSEDSIGNAL */
reg  [14:0] rc_next_buf;
reg         rc_chip_buf;

function [31:0] byte_merge(input [31:0] old_data, input [31:0] new_data, input [3:0] be);
    byte_merge = {be[3] ? new_data[31:24] : old_data[31:24],
                  be[2] ? new_data[23:16] : old_data[23:16],
                  be[1] ? new_data[15:8]  : old_data[15:8],
                  be[0] ? new_data[7:0]   : old_data[7:0]};
endfunction

// Simple refresh request. need_refresh is STICKY: it sets when the free-running refresh_cnt
// crosses REFRESH_CYCLES and clears only when a refresh is actually ISSUED (refresh_go). It
// used to clear whenever refresh_cnt wrapped through 0, so a refresh blocked past the wrap
// (by !refresh_allowed or nce) was silently DROPPED and the next attempt came a whole counter
// wrap later -- 1024 cycles at 100MHz (10.24us > tREFI) (review F3). Setting wins over clearing
// so a wrap that re-crosses REFRESH_CYCLES while one refresh is still pending cannot lose it.
// refresh_go is exactly the FSM's IDLE refresh branch: its condition, not a copy that can drift.
wire refresh_go = (state == IDLE) && ~nce && !pnd_take && need_refresh && refresh_allowed;
/* verilator lint_off WIDTHEXPAND */   // minimum-width timing parameters; see the note at their declaration
always @(posedge clk) begin
    if (!resetn) begin
        need_refresh<= 1'b0;
    end else begin
        if (refresh_cnt == REFRESH_CYCLES)
            need_refresh <= 1'b1;
        else if (refresh_go)
            need_refresh <= 1'b0;
    end
end

/* verilator lint_on WIDTHEXPAND */

// ---- The round-robin TDM arbiter ----
// rr_ptr is the requester with priority this turn. The winner is the lowest-indexed requester
// at or after rr_ptr; if none are requesting there, the search wraps to the ones before it. The
// pointer advances past the winner on every accept, so with all four requesting the order is a
// strict rotation 0,1,2,3,0,... and a requester waits at most the other three slots. Work is
// conserved: an idle slot is skipped, not held, so a lone requester runs at full rate.
reg [1:0] rr_ptr;
wire [3:0] req_vec = {valid3, valid2, valid1, valid0};
wire [3:0] rr_at_or_after = (rr_ptr == 2'd0) ? req_vec :
                            (rr_ptr == 2'd1) ? (req_vec & 4'b1110) :
                            (rr_ptr == 2'd2) ? (req_vec & 4'b1100) :
                                               (req_vec & 4'b1000);
wire [3:0] rr_sel = (rr_at_or_after != 4'b0000) ? rr_at_or_after : req_vec;
wire [1:0] rr_id = rr_sel[0] ? 2'd0 :
                   rr_sel[1] ? 2'd1 :
                   rr_sel[2] ? 2'd2 :
                   rr_sel[3] ? 2'd3 : 2'd0;   // 0 only when nothing requests (rr_valid low)
wire       rr_valid = |req_vec;

// ---- Bounded scanout priority: one guaranteed slot per rotation ----
// Round-robin alone already bounds a requester's wait at three accepts when all four ask, but
// that bound is a property of rr_ptr's phase rather than a rule. This makes it a rule for the
// scanout (requester 3, the GVRAM line fetch): once the rotation has passed it over SB_WAIT_MAX
// times it becomes the winner, so its slot cannot be postponed by where the pointer happens to
// sit. It is a DEADLINE, not a level - it can only bring the scanout forward to a slot the
// rotation already owed it, never hold one away from anyone else, so no requester starves. A
// strict fixed priority is what stopped the ITF's boot fill, and is not this.
localparam [1:0] SB_WAIT_MAX = 2'd3;
reg  [1:0] sb_wait;      // accepts granted to other requesters since the scanout was last served
wire       sb_deadline = valid3 && (sb_wait == SB_WAIT_MAX);
wire [1:0] arb_pick    = sb_deadline ? 2'd3 : rr_id;
wire       arb_new     = rr_valid | sb_deadline;
// A reserved request is served first: its row is already open, so it cannot be postponed behind
// a refresh (AutoRefresh needs every bank precharged). It is a slot the rotation already granted,
// so sb_wait is credited to it exactly as a normal accept would be.
wire       pnd_take    = PRE_ACT && (state == IDLE) && !nce && pnd_valid;
wire       arb_take    = (state == IDLE) && !nce && !pnd_valid &&
                         !(need_refresh && refresh_allowed) && arb_new;
wire [1:0] take_id     = pnd_take ? pnd_id : arb_pick;

// The pre-ACT latches `pnd_addr` at the reservation, so the ACT and the READ that follows use
// ONE row even if the request mux moves meanwhile: there is no row mismatch inside the take.
// The residual risk is that a port whose payload moved (port 0 carries two routes) is still
// credited, so assert the reserved port's presented address is unchanged at the take.
`ifdef VERILATOR
wire [26:0] pnd_live_addr = (pnd_id == 2'd0) ? addr0 : (pnd_id == 2'd1) ? addr1 :
                            (pnd_id == 2'd2) ? addr2 : addr3;
always @(posedge clk)
    if (resetn && pnd_take && (pnd_live_addr !== pnd_addr))
        $error("sdram: pre-ACT reservation taken with a moved payload: reserved=%h live=%h",
               pnd_addr, pnd_live_addr);

// THE GATHER REQUEST CONTRACT (second lines; the store buffer is the first). A gather is
// port 0's, is a write, carries 1..GATHER_K entries, and every entry shares entry 0's
// PHYSICAL row - {chip, bank, row} exactly as rc_base computes it below - because the
// session ACTs that row once and serves every entry's own column against it. The store
// buffer groups by that same key (pc9821_pegc_storebuf, sdram_size threaded to it), and a
// grouping bug that survives both would write the wrong row silently, so it is asserted
// here from the crossed payload rather than trusted.
/* verilator lint_off UNUSEDSIGNAL */   // ga[9:0] is the column; only the row key is checked here
function [15:0] gk_rowkey(input [26:0] ga);
    begin
        gk_rowkey = {((sdram_size == 2'd3) && ga[26]),
                     (sdram_size[1] ? ga[25:24] : ga[24:23]),
                     (sdram_size[1] ? ga[23:11] : ga[22:10])};
    end
endfunction
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */   // the loop counters vs the 4-bit burst count
always @(posedge clk) begin : gk_contract
    integer gi;
    /* verilator lint_off UNUSEDSIGNAL */   // lent's din/be are the entry's own payload; only its row key is checked here
    reg [62:0] lent;
    /* verilator lint_on UNUSEDSIGNAL */
    if (resetn && ready_pulse[0] && gath0) begin
        if (!wr0 || (burst_cnt0 == 4'd0) || (burst_cnt0 > GATHER_K[3:0]))
            $fatal(1, "sdram: gather request is wr0=%b with burst_cnt0=%0d (want a write of 1..%0d entries)",
                   wr0, burst_cnt0, GATHER_K);
        for (gi = 1; gi < GATHER_K; gi = gi + 1) begin
            if (gi < ((burst_cnt0 == 4'd0) ? 4'd1 : burst_cnt0)) begin
                lent = gath0_extra[(gi-1)*GENT_W +: GENT_W];
                if (gk_rowkey(lent[62:36]) !== gk_rowkey(addr0))
                    $fatal(1, "sdram: gather entry %0d is in row %h but entry 0 is in row %h -- one ACT cannot serve both",
                           gi, gk_rowkey(lent[62:36]), gk_rowkey(addr0));
            end
        end
    end
end
/* verilator lint_on WIDTHEXPAND */
`endif

always @(posedge clk) begin
    if (!resetn || !valid3) sb_wait <= 2'd0;
    else if (pnd_take || arb_take)
        sb_wait <= (take_id == 2'd3) ? 2'd0 :
                   ((sb_wait == SB_WAIT_MAX) ? SB_WAIT_MAX : sb_wait + 2'd1);
end

// Main FSM
/* verilator lint_off WIDTHEXPAND */   // the same minimum-width timing parameters
always @(posedge clk) begin
    automatic reg new_req;
    reg [1:0] req_id;
    reg [26:0] req_addr;
    reg req_rc_chip;
    reg [31:0] req_din;
    reg [3:0] req_be;
    reg req_wr;
    reg [3:0] req_burst;
    reg req_gath;              // the gather qualifier (port 0 only; asserted below)

    // defaults each cycle
    cmd               <= CMD_NOP;
    dqm_mask          <= 2'b00;
    data_resp_pulse  <= 1'b0;
    burst_done_pulse  <= 1'b0;
    ready_pulse    <= 4'b0000;

    // saturating cycle counter
    cycle <= (cycle == 5'd31) ? cycle : (cycle + 5'd1);
    refresh_cnt <= refresh_cnt + 1'b1;

    // Request arbiter: round-robin, one request accepted per turn, with the scanout's deadline
    // able to bring its owed slot forward (see arb_pick above)
    new_req = arb_new;
    req_id  = pnd_take ? pnd_id : arb_pick;
    case (req_id)
    2'd0: begin
        req_addr = addr0;
        req_rc_chip = port_rc_chip[0];
        req_din = din0;
        req_be = be0;
        req_wr = wr0;
        req_burst = burst_cnt0;
        req_gath = gath0;
    end
    2'd1: begin
        req_addr = addr1;
        req_rc_chip = port_rc_chip[1];
        req_din = din1;
        req_be = be1;
        req_wr = wr1;
        req_burst = burst_cnt1;
        req_gath = 1'b0;
    end
    2'd2: begin
        req_addr = addr2;
        req_rc_chip = port_rc_chip[2];
        req_din = din2;
        req_be = be2;
        req_wr = wr2;
        req_burst = burst_cnt2;
        req_gath = 1'b0;
    end
    default: begin
        req_addr = addr3;
        req_rc_chip = port_rc_chip[3];
        req_din = din3;
        req_be = be3;
        req_wr = wr3;
        req_burst = burst_cnt3;
        req_gath = 1'b0;
    end
    endcase;

    case (state)
    // Power-on wait -> CONFIG sequence
    INIT: begin
        if (cfg_now) begin
            state  <= CONFIG;
            cycle  <= 5'd0;
            cfg_cbr <= 4'd0;
        end
        busy_buf <= 1'b1;
        dq_oen   <= 1'b1;     // tri-state DQ during init
    end

    CONFIG: begin
        SDRAM_nCS <= init_chip;
        // t=0: PRECHG ALL. The cfg_cbr gate keeps this arm single-shot: `cycle` re-bases
        // to 0 after every CBR below and would otherwise re-issue the precharge.
        if ((cycle == 5'd0) && (cfg_cbr == 4'd0)) begin
            cmd   <= CMD_PreCharge;
            a[10] <= 1'b1;                // precharge all
        end
        // EIGHT AutoRefresh (CBR) cycles -- this was 2 (the JEDEC-generic minimum) and the
        // AS4C64M8SD-7TCN mandates more: section 3.2 Initialization, "A minimum of eight
        // Auto Refresh cycles (CBR) are also required. These may be done before or after
        // programming the Mode Register. Failure to follow these steps may lead to
        // unpredictable start-up modes." They stay BEFORE the Mode Register Set, the same
        // order this sequence always used. The first lands tRP after PRECHARGE ALL and each
        // of the rest tRC after its predecessor (tRFC = tRC = 67ns on this part), matching
        // the tRC-spaced pair this replaces.
        //
        // The 5-bit `cycle` saturates at 31 and cannot count T_RP + 8*T_RC + T_MRD (60 at
        // 100MHz), so instead of three fixed compare points the CBR slot re-bases `cycle`
        // after each refresh and cfg_cbr counts them off.
        if ((cfg_cbr < 4'd8) && (cycle == ((cfg_cbr == 4'd0) ? T_RP : T_RC))) begin
            cmd     <= CMD_AutoRefresh;
            cfg_cbr <= cfg_cbr + 4'd1;
            cycle   <= 5'd0;
        end
        // t=T_RC after the 8th CBR: Set Mode Register
        if ((cfg_cbr == 4'd8) && (cycle == T_RC)) begin
            cmd     <= CMD_SetModeReg;
            a[10:0] <= MODE_REG;
        end
        // t=...+T_MRD: done
        if ((cfg_cbr == 4'd8) && (cycle == (T_RC+T_MRD))) begin
            if ((sdram_size == 2'd3) && !init_chip) begin
                init_chip <= 1'b1;
                cfg_cbr <= 4'd0;
                cycle <= 5'd0;
            end else begin
                init_chip <= 1'b0;
                SDRAM_nCS <= 1'b0;
                state <= IDLE;
                busy_buf <= 1'b0;
                refresh_cnt <= 0;
            end
        end
    end

    IDLE: if (~nce) begin     // change state on when nce == 0
        busy_buf <= 1'b0;
        if (pnd_take) begin
            // The reserved request's row is already open, so it skips the ACT stage: `cycle`
            // continues from the pre-ACT, keeping T_RCD measured from that ACT on the pins.
            automatic reg [8:0] pb_col0 = pnd_large ? pnd_addr[10:2] : {1'b0, pnd_addr[9:2]};
            automatic reg [3:0] pb_burst = (req_burst == 0) ? 4'd1 : req_burst;
            automatic reg [9:0] pb_left = (pnd_large ? 10'd512 : 10'd256) - {1'b0, pb_col0};
            // The next-row field for THIS reserved request (see rc_of): computed here,
            // at the accept, so the pin mux reads a register.
            automatic reg [14:0] rc_n = rc_of(pnd_addr, pnd_large);
            addr_buf       <= pnd_addr;
            din_buf        <= req_din;
            din_hi_buf     <= din0_hi;
            be_buf         <= req_be;
            req_id_buf     <= pnd_id;
            req_large_buf  <= pnd_large;
            req_chip_buf   <= pnd_chip;
            rc_next_buf    <= rc_n;
            rc_chip_buf    <= pnd_chip ^ ((sdram_size == 2'd3) && (rc_n == 15'd0));
            req_wr_buf     <= 1'b0;
            burst_buf      <= req_burst;
            ready_pulse[pnd_id] <= 1'b1;
            rr_ptr         <= pnd_id + 2'd1;   // priority passes to the next slot
            busy_buf       <= 1'b1;
            rd_col_base    <= pnd_large ? pnd_addr[10:2] : {1'b0, pnd_addr[9:2]};
            rd_total_halfs <= {(req_burst == 0) ? 4'd1 : req_burst, 1'b0};
            // The reserved read's row split too:
            // the pre-ACT opened pnd_addr's row and the
            // take re-arms the segment counter from the SAME latch the ACT read arm uses, so a
            // crossing reserved burst splits exactly as an ordinary one does.
            rd_seg_halfs   <= (pb_left >= {6'd0, pb_burst}) ? {pb_burst, 1'b0}
                                                            : (pb_left[3:0] << 1);
            rd_row2        <= 1'b0;
            rd_issued      <= 5'd0;
            rd_received    <= 5'd0;
            cycle          <= (pnd_age == 5'd31) ? pnd_age : (pnd_age + 5'd1);
            rd_cas0        <= (pnd_age >= T_RCD) ? ((pnd_age == 5'd31) ? pnd_age : (pnd_age + 5'd1))
                                                 : {1'b0, T_RCD};
            pnd_valid      <= 1'b0;
            state          <= READ;
        end else if (need_refresh && refresh_allowed) begin
            // Refresh takes priority over new requests to prevent starvation
            cmd         <= CMD_AutoRefresh;
            SDRAM_nCS   <= 1'b0;
            refresh_cnt <= 0;
            busy_buf    <= 1'b1;
            cycle       <= 5'd1;
            state       <= REFRESH;
        end else if (new_req) begin
            // Latch request and pulse accepted. The pin registers are NOT driven from the live
            // mux here: the ACT stage below does that from these latches.
            // The next-row field for THIS request (see rc_of): computed here, at the
            // accept, so the pin mux reads a register instead of the incrementer.
            automatic reg [14:0] rc_n = rc_of(req_addr, sdram_size[1]);
            addr_buf       <= req_addr;
            din_buf        <= req_din;
            din_hi_buf     <= din0_hi;
            be_buf         <= req_be;
            req_id_buf     <= req_id;
            req_large_buf  <= sdram_size[1];
            req_chip_buf   <= (sdram_size == 2'd3) && req_addr[26];
            rc_next_buf    <= rc_n;
            rc_chip_buf    <= req_rc_chip;
            req_wr_buf     <= req_wr;
            req_gath_buf   <= req_gath;
            burst_buf      <= req_burst;
            // The gather session's entries latch HERE, at the accept: the requester may
            // move its payload the cycle after this ready pulse, and the session runs
            // long past it. Entry 0 is the ordinary request; entries 1.. come off
            // gath0_extra, each {addr[26:0], din[31:0], be[3:0]}.
            if (req_gath) begin : gk_latch
                integer li;
                /* verilator lint_off UNUSEDSIGNAL */   // lent's row bits feed the assertion above, not the latches
                reg [62:0] lent;
                /* verilator lint_on UNUSEDSIGNAL */
                for (li = 0; li < GATHER_K; li = li + 1) begin
                    if (li == 0) begin
                        gk_col[0] <= req_addr[10:2];
                        gk_din[0] <= req_din;
                        gk_be[0]  <= req_be;
                        gk_old[0] <= 32'd0;
                    end else begin
                        // {addr[26:0], din[31:0], be[3:0]}: addr [62:36], din [35:4], be [3:0]
                        lent = gath0_extra[(li-1)*GENT_W +: GENT_W];
                        gk_col[li] <= lent[46:38];        // addr[10:2]
                        gk_din[li] <= lent[35:4];
                        gk_be[li]  <= lent[3:0];
                        gk_old[li] <= 32'd0;
                    end
                end
                gk_ri <= 6'd0;
                gk_rc <= 6'd0;
                gk_wc <= 6'd0;

                // The slot maps and totals, registered HERE at the accept from the same
                // per-entry be masks and entry count latched above (the scan is the old
                // combinational gk_slot_maps, sampled at the accept instead of combinationally;
                // the accepted be masks are stable for the whole session, so the registered
                // value equals the combinational value at every consumer cycle).
                begin : gk_map_latch
                    integer mi, mh, mra, mwa;
                    reg [3:0] mbe_i, mbe_h, mn_ns;
                    mra = 0; mwa = 0;
                    for (mi = 0; mi < 2*GATHER_MAX; mi = mi + 1) begin
                        gk_rmap[mi] <= 4'd0;
                        gk_wmap[mi] <= 4'd0;
                    end
                    mn_ns = (req_burst == 4'd0) ? 4'd1 : req_burst;
                    for (mi = 0; mi < GATHER_K; mi = mi + 1) begin
                        if (mi == 0) mbe_i = req_be;
                        else         mbe_i = gath0_extra[(mi-1)*GENT_W +: 4];
                        for (mh = 0; mh < 2; mh = mh + 1) begin
                            mbe_h = mh[0] ? mbe_i[3:2] : mbe_i[1:0];
                            if ((mi < mn_ns) && (mbe_h != 2'b00)) begin
                                gk_wmap[mwa] <= {mi[2:0], mh[0]};
                                mwa = mwa + 1;
                                if (mbe_h != 2'b11) begin
                                    gk_rmap[mra] <= {mi[2:0], mh[0]};
                                    mra = mra + 1;
                                end
                            end
                        end
                    end
                    gk_rtot <= ADQM ? 6'd0 : mra[5:0];
                    gk_wtot <= mwa[5:0];
                end
            end
            ready_pulse[req_id] <= 1'b1;
            rr_ptr         <= req_id + 2'd1;   // priority passes to the next slot
            busy_buf  <= 1'b1;
            state     <= ACT;
        end
    end

    // ACT to the selected bank/row, from the request latched in IDLE. This is the registered
    // address stage: SDRAM_A/SDRAM_BA/SDRAM_nCS
    // are driven from the
    // latches, so the arbiter -> address mux -> pin-register path loses a logic stage and the
    // pins gain one clk_sdram cycle. The scheduler counter is re-armed here, so T_RCD, T_DAL
    // and T_RC are counted from the ACT on the pins exactly as they were counted from IDLE.
    ACT: begin
        cmd       <= CMD_BankActivate;
        SDRAM_nCS <= req_chip_buf;
        SDRAM_BA  <= req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
        {dqm_a, a}         <= ax(req_large_buf ? addr_buf[23:11] : addr_buf[22:10]);
        cycle     <= 5'd1;

        if (req_wr_buf) begin
            if (req_gath_buf) begin
                // G3 gather-RMW session: one ACT was just issued for every entry; the
                // half reads come next and the row stays open for the merged writes.
                state <= GATH_RD;
            end else if (ef_wr_burst > 4'd1) begin
                // Port 0's opt-in two-word write: one ACT, both column writes, one precharge.
                // burst_cnt != 2 (every other caller) falls through to the arms below. A pair
                // starting in the row's last column cannot fit, and is written as one word per
                // row through WRITE_BURST_ACT.
                automatic reg [8:0] wcol  = req_large_buf ? addr_buf[10:2]
                                                          : {1'b0, addr_buf[9:2]};
                automatic reg [9:0] wleft = (req_large_buf ? 10'd512 : 10'd256)
                                            - {1'b0, wcol};
                automatic reg [2:0] wseg  = (wleft >= {6'd0, ef_wr_burst})
                                            ? ({1'b0, ef_wr_burst[1:0]} << 1) : 3'd2;
                wr_split  <= (wleft < {6'd0, ef_wr_burst});
                wr_second <= 1'b0;
                wr_seg_h  <= wseg;
                state     <= WRITE_BURST;
            end else if (ADQM) begin
                // MiSTer standard (JTFRAME's ADQM): the chip's DQM is wired to A[12:11], so a
                // partial store is ONE masked WRITE -- the mask rides a[12:11], with no read and
                // no re-activated merge write. docs/sdram-dqm-wiring.md.
                wr_halfs <= {|be_buf[3:2], |be_buf[1:0]};
                state    <= WRITE;
            end else if (!HAS_DQM && (be_buf == 4'b0011)) begin
                wr_halfs <= 2'b01;
                state    <= WRITE;
            end else if (!HAS_DQM && (be_buf == 4'b1100)) begin
                wr_halfs <= 2'b10;
                state    <= WRITE;
            end else if (!HAS_DQM && (be_buf != 4'b1111)) begin
                rmw_issued   <= 2'd0;
                rmw_received <= 2'd0;
                rmw_old_data <= 32'd0;
                if (be_buf[1:0] != 2'b00 && be_buf[3:2] == 2'b00) begin
                    rmw_read_halfs  <= 2'b01;
                    rmw_total_reads <= 2'd1;
                    wr_halfs        <= 2'b01;
                end else if (be_buf[3:2] != 2'b00 && be_buf[1:0] == 2'b00) begin
                    rmw_read_halfs  <= 2'b10;
                    rmw_total_reads <= 2'd1;
                    wr_halfs        <= 2'b10;
                end else begin
                    rmw_read_halfs  <= 2'b11;
                    rmw_total_reads <= 2'd2;
                    wr_halfs        <= 2'b11;
                end
                state        <= RMW_READ;
            end else begin
                wr_halfs <= 2'b11;
                state <= WRITE;
            end
        end else begin
            automatic reg [3:0] eff_burst;
            automatic reg [8:0] col0;
            automatic reg [9:0] row_left;   // dwords from col0 to the end of its row (>= 1)
            // A 32MB chip has 256 dword columns; 64MB chips have 512.
            eff_burst       = (burst_buf == 0) ? 1 : burst_buf;
            col0            = req_large_buf ? addr_buf[10:2] : {1'b0, addr_buf[9:2]};
            row_left        = (req_large_buf ? 10'd512 : 10'd256) - col0;
            rd_col_base     <= col0;
            rd_total_halfs  <= {eff_burst,1'b0};     // *2
            // eff_burst <= 15 and a row holds >= 256 dwords, so a burst crosses at most ONE row
            // boundary: the first row takes what fits, the rest is a second ACT plus burst.
            rd_seg_halfs    <= (row_left >= {6'd0, eff_burst}) ? {eff_burst,1'b0}
                                                              : (row_left[3:0] << 1);
            rd_row2         <= 1'b0;
            rd_issued       <= 5'd0;
            rd_received     <= 5'd0;
            rd_cas0         <= {1'b0, T_RCD};
            state           <= READ;
        end
    end

    // Issue length-1 READ commands every cycle after T_RCD.
    // Each READ returns one 16-bit half. We compose 32-bit words from pairs.
    READ: begin
        // The pre-ACT's tRP guard, referenced to the last CAS (review F1). The row-split ACT
        // above waits for full data drain before its second ACT -- the bank's auto-precharge
        // only completes T_RP after the read data has finished -- and this guard must agree
        // with it. The reserved ACT is sampled pnd_go+1 = 2 cycles after this condition fires
        // and the last CAS is sampled at rd_cas0 + halfs = T_RCD + halfs after this read's
        // ACT, so `halfs + T_RP` left only T_RP+2-T_RCD between them: short by T_RCD-2 under
        // the precharge-at-READ-A reading of tRP (a violation outright at 125MHz), and short by
        // T_RCD+CAS-2 under the read-data-completion reading. Adding T_RCD+CAS-2 measures tRP
        // from the last data-out under EITHER reading and makes the two ACT paths agree.
        // Cycle cost: NONE at T_RCD <= 2 (the window still reaches the take-bound ACT and the
        // reserved read's CAS keeps its cycle count exactly); at T_RCD == 3 the safe window is
        // empty (no overlap ACT is legal there), so the reservation drops and a would-be
        // reserved follow-up read pays T_RCD more cycles -- unavoidable without relaxing tRP.
        automatic reg [5:0] rp_need = {1'b0, rd_total_halfs} + T_RP + T_RCD + CAS - 6'd2;
        automatic reg       rd_finish = (cycle >= (rd_cas0 + CAS + 2)) &&
                                        (rd_received < rd_issued) &&
                                        ((rd_received + 5'd1) == rd_total_halfs);
        // Issue CAS READ one per cycle once T_RCD reached
        if ((cycle >= T_RCD) && (rd_issued < rd_total_halfs)) begin
            if ((rd_issued == rd_seg_halfs) && !rd_row2) begin
                // The burst has run out of the row it started in. Drain it -- every issued half
                // has landed -- then open the next row and carry on in this same state, which is
                // the ACT the READ arm of ACT performs, from the same latches.
                if (rd_received == rd_issued) begin
                    cmd         <= CMD_BankActivate;
                    SDRAM_nCS   <= rc_chip_buf;
                    SDRAM_BA    <= rc_next_buf[14:13];
                    {dqm_a, a}           <= ax(rc_next_buf[12:0]);
                    rd_col_base <= 9'd0;
                    rd_row2     <= 1'b1;
                    // The second row's CAS timing is measured from `cycle == 1` again, so the data
                    // capture re-bases on T_RCD. A reserved (pre-ACT) read entered with rd_cas0 =
                    // pnd_age+1 > T_RCD, which would start this segment's capture late.
                    rd_cas0     <= {1'b0, T_RCD};
                    cycle       <= 5'd1;
                end
            end else begin
                // Column (S4a): this segment's half-column, combinational from the latches so
                // the pin-address path loses the old compare/shift/dw chain while adding no
                // feedback register (the Quartus DTM fitter bug the S2 lane hit on a register
                // form).
                // Segment 1: {rd_col_base,half} counts up from issued 0 -> {base,1'b0}+issued.
                // Segment 2 (rd_row2): columns restart at 0 in the row the split ACT opened,
                // so issued counts from rd_seg_halfs -> issued-rd_seg_halfs. rd_issued >= rd_seg_halfs
                // at a CAS is equivalent to rd_row2: the split drains before any later CAS issues.
                automatic reg [9:0] col16 = rd_row2
                    ? ({5'b0, rd_issued} - {5'b0, rd_seg_halfs})
                    : ({rd_col_base, 1'b0} + {5'b0, rd_issued});
                cmd      <= CMD_Read;
                // The second segment lives in the row the split ACT opened, which is the NEXT
                // BANK's (and possibly the next chip's) after the F5 carry: its commands must
                // carry that bank/chip, not addr_buf's.
                SDRAM_nCS <= rd_row2 ? rc_chip_buf : req_chip_buf;
                SDRAM_BA <= rd_row2 ? rc_next_buf[14:13]
                                    : (req_large_buf ? addr_buf[25:24] : addr_buf[24:23]);
                // Auto-precharge on the last half of EACH segment: the first row must be closed
                // before the second ACT opens the next row (same bank).
                {dqm_a, a}         <= ax(req_large_buf
                           ? {2'b00, ((rd_issued == rd_total_halfs-1) ||
                                      (rd_issued == (rd_seg_halfs-1))), col16}
                           : {2'b00, ((rd_issued == rd_total_halfs-1) ||
                                      (rd_issued == (rd_seg_halfs-1))), 1'b0, col16[8:0]});
                rd_issued <= rd_issued + 5'd1;
            end
        end

        // Capture returning 16-bit data CAS+2 after the FIRST CAS (rd_cas0), +1 for the dq_r
        // stage, rather than after the ACT: a reserved read's CAS is issued after its T_RCD.
        if ((cycle >= (rd_cas0 + CAS + 2)) && (rd_received < rd_issued)) begin
            if (!rd_received[0]) begin
                rd_lo16 <= dq_r;                  // low half
            end else begin
                dout_word <= {dq_r, rd_lo16};     // high half completes a 32-bit word
                data_resp_pulse <= 1'b1;

                // If that was the last half in the burst, signal burst_done and go idle
                if (rd_received + 5'd1 == rd_total_halfs) begin
                    burst_done_pulse <= 1'b1;
                    busy_buf <= 1'b0;
                    state    <= IDLE;
                end
            end
            rd_received <= rd_received + 5'd1;
        end

        // Speculative pre-ACT. Every CAS is out, so the command bus is
        // free until the data drains; activate the next request's row now, if the arbiter has a
        // READ pending on ANOTHER port and both tRC (from this transaction's ACT) and tRP (from
        // its last CAS) leave room. Another port, because port 0 carries two routes (the CPU and
        // the GVRAM) whose response spacing the subsystem's route queue is
        // sized for. `req_addr`/`req_wr` are the arbiter's pick this cycle, and the requesters
        // hold their request until ready, so the reservation cannot be taken from them.
        if (PRE_ACT && !rd_finish && !pnd_valid && !pnd_go && !nce && !need_refresh && arb_new && !req_wr &&
            (req_id != req_id_buf) &&
            (rd_issued >= rd_total_halfs) && (cycle >= T_RC) && ({1'b0, cycle} >= rp_need)) begin
            pnd_addr  <= req_addr;
            pnd_id    <= req_id;
            pnd_chip  <= (sdram_size == 2'd3) && req_addr[26];
            pnd_large <= sdram_size[1];
            pnd_go    <= 1'b1;
        end
        if (pnd_go) begin
            cmd       <= CMD_BankActivate;
            SDRAM_nCS <= pnd_chip;
            SDRAM_BA  <= pnd_large ? pnd_addr[25:24] : pnd_addr[24:23];
            {dqm_a, a}         <= ax(pnd_large ? pnd_addr[23:11] : pnd_addr[22:10]);
            pnd_go    <= 1'b0;
            pnd_valid <= 1'b1;
            pnd_age   <= 5'd1;
        end else if (pnd_valid) begin
            pnd_age <= (pnd_age == 5'd31) ? pnd_age : (pnd_age + 5'd1);
        end
    end

    // Boards without DQM must read the original dword and merge bytes locally.
    RMW_READ: begin
        if ((cycle >= T_RCD) && (rmw_issued < rmw_total_reads)) begin
            automatic reg [9:0] col16;
            automatic reg       half_sel;
            half_sel = (rmw_read_halfs == 2'b10) ? 1'b1 :
                       (rmw_read_halfs == 2'b01) ? 1'b0 :
                       rmw_issued[0];
            cmd      <= CMD_Read;
            SDRAM_nCS <= req_chip_buf;
            SDRAM_BA <= req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            col16    = {req_large_buf ? addr_buf[10:2] : {1'b0, addr_buf[9:2]}, half_sel};
            {dqm_a, a}        <= ax(req_large_buf
                      ? {2'b00, (rmw_issued == rmw_total_reads-1), col16}
                      : {2'b00, (rmw_issued == rmw_total_reads-1), 1'b0, col16[8:0]});
            rmw_issued <= rmw_issued + 2'd1;
        end

        if ((cycle >= (T_RCD + CAS + 2)) && (rmw_received < rmw_issued)) begin
            automatic reg       half_sel;
            automatic reg [31:0] old_word;
            half_sel = (rmw_read_halfs == 2'b10) ? 1'b1 :
                       (rmw_read_halfs == 2'b01) ? 1'b0 :
                       rmw_received[0];
            old_word = rmw_old_data;

            if (!half_sel) begin
                old_word[15:0] = dq_r;
            end else begin
                old_word[31:16] = dq_r;
            end

            rmw_old_data <= old_word;

            if (rmw_received + 2'd1 == rmw_total_reads) begin
                din_buf <= byte_merge(old_word, din_buf, be_buf);
                be_buf  <= (wr_halfs == 2'b01) ? 4'b0011 :
                           (wr_halfs == 2'b10) ? 4'b1100 : 4'b1111;
                state   <= RMW_ACT;
                cycle   <= 5'd0;
            end
            rmw_received <= rmw_received + 2'd1;
        end
    end

    // Re-open the row after the auto-precharged RMW read, then do a full-word write.
    RMW_ACT: begin
        if (cycle == 5'd0) begin
            cmd      <= CMD_BankActivate;
            SDRAM_nCS <= req_chip_buf;
            SDRAM_BA <= req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            {dqm_a, a}        <= ax(req_large_buf ? addr_buf[23:11] : addr_buf[22:10]);
            cycle    <= 5'd1;
            state    <= WRITE;
        end
    end

    // Write selected 16-bit halves. MiSTer SDRAM modules have no DQM, so
    // partial byte writes are converted to the smallest safe half-word write.
    WRITE: begin
        // low half at T_RCD
        if (cycle == T_RCD && wr_halfs[0]) begin
            cmd      <= CMD_Write;
            SDRAM_nCS <= req_chip_buf;
            SDRAM_BA <= req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            // ADQM: A[12:11] carry the low half's byte mask (A12=UDQM, A11=LDQM, active high).
            // Every other command drives a[12:11]=00 (READ) or row bits (ACT); MRS keeps 00.
            {dqm_a, a}        <= ax(req_large_buf
                      ? {(ADQM ? {~be_buf[1], ~be_buf[0]} : 2'b00), !wr_halfs[1]/*AP if final*/, addr_buf[10:2], 1'b0}
                      : {(ADQM ? {~be_buf[1], ~be_buf[0]} : 2'b00), !wr_halfs[1]/*AP if final*/, 1'b0, addr_buf[9:2], 1'b0});
            dqm_mask <= {~be_buf[1], ~be_buf[0]};
            dq_out   <= din_buf[15:0];
            dq_oen   <= 1'b0;
        end

        // high half can immediately follow the low half; no idle bubble needed.
        if ((cycle == T_RCD && !wr_halfs[0] && wr_halfs[1]) ||
            (cycle == (T_RCD+1) && wr_halfs == 2'b11)) begin
            cmd      <= CMD_Write;
            SDRAM_nCS <= req_chip_buf;
            SDRAM_BA <= req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            {dqm_a, a}        <= ax(req_large_buf
                      ? {(ADQM ? {~be_buf[3], ~be_buf[2]} : 2'b00), 1'b1/*AP*/, addr_buf[10:2], 1'b1}
                      : {(ADQM ? {~be_buf[3], ~be_buf[2]} : 2'b00), 1'b1/*AP*/, 1'b0, addr_buf[9:2], 1'b1});
            dqm_mask <= {~be_buf[3], ~be_buf[2]};
            dq_out   <= din_buf[31:16];
            dq_oen   <= 1'b0;
        end

        if ((cycle == (T_RCD+1) && wr_halfs != 2'b11) ||
            (cycle == (T_RCD+2) && wr_halfs == 2'b11)) begin
            dq_oen <= 1'b1;
        end

        // The auto-precharged write must return to IDLE late enough for tDAL = tWR + tRP before
        // the next ACT AND for tRC between this write's ACT and the NEXT transaction's ACT. The
        // partial-write arm used to fire one cycle earlier, leaving only 3 cycles (60ns) between
        // ACTs: exactly tRC on the -6 grade and 7ns short of the -7 grade's 67ns. Both arms now
        // exit at T_RCD + T_DAL_I; measured ACT-to-ACT becomes a full T_RC.
        if (cycle == (T_RCD + T_DAL_I)) begin
            busy_buf <= 1'b0;
            state    <= IDLE;
        end
    end

    // Port 0's opt-in two-word write (burst_cnt == 2, the only count that reaches here). One ACT
    // opens the row; both dwords are written at consecutive columns as four 16-bit WRITE commands,
    // one per cycle from T_RCD; auto-precharge rides the LAST half of each row segment. That is the
    // same write latency the single arm uses per word, and the burst's exit keeps the old rule --
    // T_DAL_I after the last write -- so tDAL and tRC are unchanged. A pair the row cannot hold
    // whole is one word per row, four halves in all.
    WRITE_BURST: begin
        // cycle and T_RCD are both < 32 here, so the half index fits 5 bits with room to spare.
        /* verilator lint_off WIDTHTRUNC */
        automatic reg [4:0] h  = cycle - T_RCD;                 // half index 0..wr_seg_h-1
        automatic reg [4:0] hl = {2'b0, wr_seg_h};
        automatic reg wk = wr_second | h[1];     // dword of the PAIR whose half this is
        automatic reg [8:0] cb = wr_second ? 9'd0 : (req_large_buf ? addr_buf[10:2]
                                                                   : {1'b0, addr_buf[9:2]});
        automatic reg       last_half = (h == (hl - 5'd1));
        /* verilator lint_on WIDTHTRUNC */
        automatic reg [31:0] wdat;
        wdat = wk ? din_hi_buf : din_buf;

        // The COLUMN is the segment's own dword index (h[2:1]), not wk: the pair's second word is
        // column 0 of its row, so a split segment's address must restart there.
        if ((cycle >= T_RCD) && (h < hl)) begin
            cmd       <= CMD_Write;
            // As in the READ arm: the pair's second segment writes the row its split ACT
            // opened -- the NEXT bank's/chip's after the F5 carry (review F5).
            SDRAM_nCS <= wr_second ? rc_chip_buf : req_chip_buf;
            SDRAM_BA  <= wr_second ? rc_next_buf[14:13]
                                   : (req_large_buf ? addr_buf[25:24] : addr_buf[24:23]);
            {dqm_a, a}         <= ax(req_large_buf
                       ? {2'b00, last_half, (cb + {7'd0, h[2:1]}), h[0]}
                       : {2'b00, last_half, 1'b0, (cb[7:0] + {6'd0, h[2:1]}), h[0]});
            dqm_mask  <= h[0] ? {~be_buf[3], ~be_buf[2]} : {~be_buf[1], ~be_buf[0]};
            dq_out    <= h[0] ? wdat[31:16] : wdat[15:0];
            dq_oen    <= 1'b0;
        end

        if (cycle == (T_RCD + hl + (T_DAL_I - 2))) begin
            if (wr_split && !wr_second) begin
                wr_second <= 1'b1;
                cycle     <= 5'd0;
                state     <= WRITE_BURST_ACT;
            end else begin
                dq_oen   <= 1'b1;
                busy_buf <= 1'b0;
                state    <= IDLE;
            end
        end
    end

    // The second row of a split write pair.
    // Entered at the exit the whole burst would
    // have taken, so the ACT is one T_DAL_I after the first row's last WRITE -- exactly where the
    // next transaction's ACT would have been -- and the second row's writes follow T_RCD later.
    WRITE_BURST_ACT: begin
        if (cycle == 5'd0) begin
            cmd       <= CMD_BankActivate;
            SDRAM_nCS <= rc_chip_buf;
            SDRAM_BA  <= rc_next_buf[14:13];
            {dqm_a, a}         <= ax(rc_next_buf[12:0]);
            cycle     <= 5'd1;
            state     <= WRITE_BURST;
        end
    end

    REFRESH: begin
        // A 128 MB module is two chips with complementary CS, and EACH needs its own
        // AutoRefresh. Two REFRESH commands are separated by tRC exactly as two ACTs are,
        // and the CONFIG sequence above already spaces its own pair by T_RC
        // (cycle == T_RP + T_RC). This path issued the second one on the cycle after the
        // first, which is a tRC violation, and tRC is not a tolerance: a refresh inside
        // another refresh's tRC window is undefined behaviour. The exit moves out with it
        // so the next ACTIVATE still has T_RC after the second REFRESH.
        //
        // Coverage note: the refresh path was in NO test before this - every bench's
        // transactions complete inside the auto-refresh interval, so no bench had
        // ever seen a REFRESH command at all. tb_pc9821_sdram now drives one to happen.
        if ((cycle == T_RC) && (sdram_size == 2'd3)) begin
            cmd <= CMD_AutoRefresh;
            SDRAM_nCS <= 1'b1;
        end
        if (cycle == ((sdram_size == 2'd3) ? (T_RC + T_RC) : T_RC)) begin
            SDRAM_nCS <= 1'b0;
            state    <= IDLE;
            busy_buf <= 1'b0;
        end
    end

    // The G3 gather-RMW session's half reads (the header). Every half any entry's be
    // touches with SOME but not ALL of its bytes is read once, back-to-back, length-1
    // CAS, and deliberately WITHOUT auto-precharge: the row stays open so the merged
    // writes below need no re-ACT (the single-RMW path's per-store re-open is what this
    // session exists to amortise). gk_rmap walks the slots in entry order.
    GATH_RD: begin
        if ((cycle >= T_RCD) && (gk_ri < gk_rtot)) begin : gk_issue
            automatic reg [3:0] rmap_v;
            automatic reg [8:0] gcol;
            automatic reg [9:0] col16;
            rmap_v = gk_rmap[gk_ri[3:0]];
            gcol   = gk_col[rmap_v[3:1]];
            col16  = {req_large_buf ? gcol : {1'b0, gcol[7:0]}, rmap_v[0]};
            cmd      <= CMD_Read;
            SDRAM_nCS <= req_chip_buf;
            SDRAM_BA <= req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            {dqm_a, a}        <= ax(req_large_buf
                      ? {2'b00, 1'b0, col16}
                      : {2'b00, 1'b0, 1'b0, col16[8:0]});
            gk_ri    <= gk_ri + 6'd1;
        end
        // The writes start at gk_w0 (see its derivation): the whole stream is out when
        // every read was ISSUED and the first write may drive the bus.
        if ((gk_ri == gk_rtot) && (cycle >= (gk_w0 - 6'd1))) begin
            gk_wc <= 6'd0;
            state <= GATH_WR;
        end
    end

    // The merged half writes: one per touched half, to each entry's own column, in the
    // same slot order as the reads. Auto-precharge rides the LAST write (one precharge
    // for the whole session), and the exit keeps the write arm's own tDAL/tRC rule.
    GATH_WR: begin
        if (gk_wc < gk_wtot) begin : gk_wissue
            automatic reg [3:0] wmap_v;
            automatic reg [8:0] gcol;
            automatic reg [9:0] col16;
            wmap_v = gk_wmap[gk_wc[3:0]];
            gcol   = gk_col[wmap_v[3:1]];
            col16  = {req_large_buf ? gcol : {1'b0, gcol[7:0]}, wmap_v[0]};
            cmd       <= CMD_Write;
            SDRAM_nCS <= req_chip_buf;
            SDRAM_BA  <= req_large_buf ? addr_buf[25:24] : addr_buf[24:23];
            // The fields come from the S1-a look-ahead flops (gk_la_*, formed one cycle
            // ahead from the same latched session state); col16/gk_gd_* are the live
            // forms they are checked against.
            {dqm_a, a}         <= ax(req_large_buf
                       ? {(ADQM ? gk_la_mask : 2'b00), gk_la_last, gk_la_col16}
                       : {(ADQM ? gk_la_mask : 2'b00), gk_la_last, 1'b0, gk_la_col16[8:0]});
            dqm_mask  <= 2'b00;      // ADQM puts the mask on a[12:11]; the RMW merge folded it into the half
            dq_out    <= ADQM ? gk_la_dat : gk_wdat;
`ifdef VERILATOR
            if (resetn && ((gk_la_col16 !== col16) || (gk_la_last !== (gk_wc == (gk_wtot - 6'd1))) ||
                           (ADQM && ((gk_la_dat !== gk_gd_dat) || (gk_la_mask !== gk_gd_mask)))))
                $fatal(1, "sdram: S1-a look-ahead slot %0d disagrees: col %h/%h last %b dat %h/%h mask %b/%b",
                       gk_wc, gk_la_col16, col16, gk_la_last, gk_la_dat, gk_gd_dat, gk_la_mask, gk_gd_mask);
`endif
            dq_oen    <= 1'b0;
        end
        if (gk_wc == gk_wtot) dq_oen <= 1'b1;
        if (gk_wc == (gk_wtot + T_DAL_I - 6'd2)) begin
            busy_buf <= 1'b0;
            state    <= IDLE;
        end
        gk_wc <= gk_wc + 6'd1;
    end

    default: state <= IDLE;
    endcase

    // The gather session's read capture runs across BOTH session states: write j needs
    // only capture j and both streams walk the same slot order, so the tail of the
    // capture overlaps the head of the writes (gk_w0 is derived so no write ever
    // reads its merge base before it lands).
    if (gk_on && (cycle >= (T_RCD + CAS + 2)) && (gk_rc < gk_ri)) begin : gk_capture
        automatic reg [3:0] rmap_v;
        automatic reg [31:0] od;
        rmap_v = gk_rmap[gk_rc[3:0]];
        od     = gk_old[rmap_v[3:1]];
        gk_old[rmap_v[3:1]] <= rmap_v[0] ? {dq_r, od[15:0]} : {od[31:16], dq_r};
        gk_rc <= gk_rc + 6'd1;
    end

    // Reset
    if (!resetn) begin
        state      <= INIT;
        busy_buf   <= 1'b1;
        dq_oen     <= 1'b1;
        dqm_mask   <= 2'b00;
        SDRAM_BA   <= 2'b00;
        SDRAM_nCS  <= 1'b0;
        {dqm_a, a}          <= ax(13'd0);
        cmd        <= CMD_NOP;

        cycle      <= 5'd0;
        cfg_cbr    <= 4'd0;
        refresh_cnt<= {REFRESH_CNT_W{1'b0}};
        rmw_issued <= 2'd0;
        rmw_received <= 2'd0;
        rmw_total_reads <= 2'd0;
        rmw_read_halfs <= 2'b00;
        rmw_old_data <= 32'd0;
        wr_halfs <= 2'b11;
        wr_split <= 1'b0;
        wr_second <= 1'b0;
        wr_seg_h <= 3'd0;
        req_gath_buf <= 1'b0;
        gk_ri <= 6'd0;
        gk_rc <= 6'd0;
        gk_wc <= 6'd0;
        req_large_buf <= 1'b0;
        req_chip_buf <= 1'b0;
        rc_next_buf  <= 15'd0;
        rc_chip_buf  <= 1'b0;
        init_chip <= 1'b0;
        pnd_valid <= 1'b0;
        pnd_go    <= 1'b0;
        pnd_id    <= 2'd0;
        pnd_addr  <= 27'd0;
        pnd_chip  <= 1'b0;
        pnd_large <= 1'b0;
        pnd_age   <= 5'd0;

        ready_pulse <= 4'b0000;
        rr_ptr      <= 2'd0;

        rd_total_halfs <= 5'd0;
        rd_seg_halfs   <= 5'd0;
        rd_row2        <= 1'b0;
        rd_issued      <= 5'd0;
        rd_received    <= 5'd0;
        rd_cas0        <= 5'd0;

        data_resp_pulse <= 1'b0;
        burst_done_pulse <= 1'b0;
    end
end
/* verilator lint_on WIDTHEXPAND */

// Generate cfg_now pulse after initialization delay (normally 200us)
reg  [23:0]   rst_cnt;        // enough for 200us at ~65MHz
reg           rst_done, rst_done_p1;

/* verilator lint_off WIDTHEXPAND */   // the same minimum-width timing parameters
always @(posedge clk) begin
    rst_done_p1 <= rst_done;
    cfg_now     <= rst_done & ~rst_done_p1;     // rising edge

    if (rst_cnt != (FREQ/1000)*200/1000) begin  // count to 200us
        rst_cnt  <= rst_cnt + 24'd1;
        rst_done <= 1'b0;
    end else begin
        rst_done <= 1'b1;
    end

    if (!resetn) begin
        rst_cnt  <= 24'd0;
        rst_done <= 1'b0;
    end
end
/* verilator lint_on WIDTHEXPAND */

endmodule

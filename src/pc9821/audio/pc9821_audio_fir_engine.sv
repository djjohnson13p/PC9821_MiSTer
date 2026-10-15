// One decimating FIR MAC engine for the 48 kHz output stage, used twice per channel: as
// stage B (decimate by 2) and as stage C (the 5/16 polyphase resampler). It owns its two
// history RAMs and two multipliers (left and right in parallel, so one tap costs one clock),
// reads its coefficients through a port so the PARENT holds one shared ROM for both
// channels, and is otherwise a pure "run TAPS taps and hand back the answer" machine.
//
// Fixed 2-deep MAC pipeline, one tap per clock (addresses issued at cycle c):
//   end of c   : history and coefficient registers load  (RAM in here, ROM in the parent)
//   end of c+1 : product registers load
//   c+2        : the product is accumulated
// A run is therefore TAPS+3 clocks and the accumulator's final value is latched in the last.
//
// History addressing: the tap window is the TAPS samples ending at `start_addr`, read as
// start_addr - k on a circular buffer. The buffer is deliberately larger than the window
// (32 vs 19, 128 vs 123) so a write landing during a run can never overwrite a sample the run
// still needs - and a write to the address being read that cycle reads back the OLD value,
// which is the value that tap wants anyway.
//
// Coefficients are Q17 signed and the table is symmetric about CMIRROR; the parent stores
// only the first half, so the address is mirrored here (one compare and one subtractor, and
// half the ROM - 308 entries fits one M10K where 615 would not).
//
// The CLK_AUDIO domain has no reset, so every register is seeded and the state machine only
// ever moves to a defined state (st has no undefined encoding: 2'd0 and 2'd1 are the only
// live ones and `default` returns to idle).
`default_nettype none

module pc9821_audio_fir_engine #(
    parameter integer TAPS    = 19,   // taps per output (per channel)
    parameter integer STRIDE  = 1,    // coefficient address step per tap
    parameter integer RAM_AW  = 5,    // history RAM address width (window + margin)
    parameter integer CMIRROR = 9,    // prototype symmetry centre: coefficient (2*CMIRROR - m)
    parameter integer COEF_AW = 4,    // coefficient address width after mirroring
    parameter integer SHIFT   = 17    // Q17 coefficients -> output
)(
    input  wire                    clk,

    // History write port: one sample of each channel per pulse.
    input  wire                    wr_en,
    input  wire [RAM_AW-1:0]       wr_addr,
    input  wire signed [15:0]      wr_l,
    input  wire signed [15:0]      wr_r,

    // One run.
    input  wire                    start,
    input  wire [RAM_AW-1:0]       start_addr,   // address of the newest sample of the window
    input  wire [2:0]              phase,        // polyphase offset (0 when STRIDE = 1)

    // Coefficients live outside so both channels share one ROM (and one read port). The
    // parent's read must be the registered one: no power-up value and no reset on it, or
    // Quartus refuses the memory and builds the table out of LUTs.
    output wire [COEF_AW-1:0]      coef_addr,
    input  wire signed [17:0]      coef_data,

    output reg                     busy,
    output reg                     done,
    output reg  signed [15:0]      out_l,
    output reg  signed [15:0]      out_r
);

    (* ramstyle = "M10K" *) reg signed [15:0] ram_l [0:(1<<RAM_AW)-1];
    (* ramstyle = "M10K" *) reg signed [15:0] ram_r [0:(1<<RAM_AW)-1];

    // Power-up contents: silence. A memory cannot be reset, so this seed is the whole of its
    // initialisation (the same reason ssg_reg in pc9821_opna carries none) - without it the
    // first outputs after power-up would be built from X.
    integer i;
    initial begin
        for (i = 0; i < (1<<RAM_AW); i = i + 1) begin
            ram_l[i] = 16'sd0;
            ram_r[i] = 16'sd0;
        end
    end

    /* verilator lint_off PROCASSINIT */   // the seeds ARE this domain's power-up state
    reg [RAM_AW-1:0] base = 0;
    reg [1:0]        st   = 0;      // 0 idle, 1 running
    reg [7:0]        cyc  = 0;      // 1 .. TAPS+3 (TAPS <= 123 here, so 8 bits is exact)
    reg [2:0]        ph   = 0;

    // One-deep request buffer: every `start` produces exactly one `done`, even if a start
    // lands while a run is in flight. The caller's schedule never needs it (B runs 22 of
    // every 160 clk, C 126 of every 512) - but a silently dropped start would be a dropped
    // audio sample, and that is worth three registers to make impossible.
    reg              pend      = 0;
    reg [RAM_AW-1:0] pend_addr = 0;
    reg [2:0]        pend_ph   = 0;
    /* verilator lint_on PROCASSINIT */

    // Sample address for this cycle's tap. Free-running wraparound is the point: the RAM's
    // address space is a power of two, so base-k wraps by itself.
    wire [RAM_AW-1:0] tap_addr = base - (cyc[RAM_AW-1:0] - 1'b1);

    // Coefficient index, mirrored about the prototype centre. Stride and phase are applied
    // on the prototype BEFORE mirroring, which is what makes the five phases work.
    // Widths are explicit: the index never exceeds the prototype length (123*5 = 615), so
    // 12 bits carry stride*k + phase exactly and the product cannot truncate.
    localparam [11:0] STRIDE_W = 12'(STRIDE);
    localparam [11:0] MID_W    = 12'(CMIRROR);
    wire [11:0] kk   = {4'b0, cyc} - 12'd1;
    wire [11:0] idx  = (STRIDE_W * kk) + {9'b0, ph};
    /* verilator lint_off UNUSEDSIGNAL */   // bits above COEF_AW are the prototype length
    wire [11:0] midx = (idx > MID_W) ? ((MID_W + MID_W) - idx) : idx;
    /* verilator lint_on UNUSEDSIGNAL */
    assign coef_addr = midx[COEF_AW-1:0];

    // Pipeline stage 1: history and coefficient. q_* is the RAM's registered read (coef_data
    // is already registered in the parent, one clock after coef_addr).
    //
    // q_l/q_r carry NO power-up value and NO reset, and that is a hardware rule, not a
    // style one: a seed or a reset on the register that captures a memory read makes Quartus
    // refuse the RAM and build the whole history out of LUTs (the kbd_lut trap,
    // res-mlab-REPORT section 7.2). Their first value before any run is X in 4-state
    // simulation and is never used - the engine only accumulates inside a run, and a run
    // always issues TAPS addresses first.
    reg signed [15:0] q_l, q_r;
    // Pipeline stage 2: product.
    reg signed [33:0] prod_l, prod_r;
    // Pipeline stage 3: accumulator. 34-bit products with 7 bits of tap growth (TAPS <= 128).
    reg signed [41:0] acc_l, acc_r;

    // Q17 accumulator -> 16-bit, saturating (the filters' DC gain is unity, so this only
    // ever catches arithmetic, never the signal). The accumulator's 42 bits are products
    // (34) plus tap growth (<= 7); SHIFT+15 is the sign bit of the 16-bit result, so
    // anything above it that is not that sign is an overflow.
    localparam integer OSB = SHIFT + 15;               // 32
    localparam integer OVW = 41 - OSB;                 // 9
    wire ovf_l = (acc_l[41:OSB+1] != {OVW{acc_l[OSB]}});
    wire ovf_r = (acc_r[41:OSB+1] != {OVW{acc_r[OSB]}});
    wire signed [15:0] y_l = ovf_l ? (acc_l[OSB] ? 16'sh8000 : 16'sh7FFF) : acc_l[OSB -: 16];
    wire signed [15:0] y_r = ovf_r ? (acc_r[OSB] ? 16'sh8000 : 16'sh7FFF) : acc_r[OSB -: 16];

    always @(posedge clk) begin
        done <= 1'b0;

        if (wr_en) begin
            ram_l[wr_addr] <= wr_l;
            ram_r[wr_addr] <= wr_r;
        end

        q_l <= ram_l[tap_addr];
        q_r <= ram_r[tap_addr];
        prod_l <= q_l * coef_data;
        prod_r <= q_r * coef_data;

        case (st)
            2'd0: begin
                      // Consume a buffered request first, then take this cycle's start. The
                      // order matters: a start arriving exactly now must survive, so it is
                      // captured (last write wins) rather than lost to the consume.
                      if (pend) begin
                          base  <= pend_addr;
                          ph    <= pend_ph;
                          cyc   <= 8'd1;
                          acc_l <= 42'sd0;
                          acc_r <= 42'sd0;
                          st    <= 2'd1;
                          busy  <= 1'b1;
                          pend  <= 1'b0;
                      end
                      if (start) begin
                          pend      <= 1'b1;
                          pend_addr <= start_addr;
                          pend_ph   <= phase;
                      end
                  end
            2'd1: begin
                      if (start) begin
                          pend      <= 1'b1;
                          pend_addr <= start_addr;
                          pend_ph   <= phase;
                      end
                      // Tap k is issued at cyc = k+1 and accumulated at cyc = k+3.
                      if ((cyc >= 8'd3) && (cyc <= 8'(TAPS + 2))) begin
                          acc_l <= acc_l + {{8{prod_l[33]}}, prod_l};
                          acc_r <= acc_r + {{8{prod_r[33]}}, prod_r};
                      end
                      if (cyc == 8'(TAPS + 3)) begin
                          out_l <= y_l;
                          out_r <= y_r;
                          done  <= 1'b1;
                          busy  <= 1'b0;
                          st    <= 2'd0;
                      end
                      else cyc <= cyc + 8'd1;
                  end
            default: st <= 2'd0;
        endcase
    end

endmodule

`default_nettype wire

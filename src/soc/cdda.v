/* verilator lint_off PROCASSINIT */   // The CLK_AUDIO half has no reset, so its power-up state IS
                                       // the seeds below (review r2-resets F3): each of them is a
                                       // declaration with an initial value that the procedural code
                                       // then assigns, which is exactly this warning's shape.
/* verilator lint_off SIMILARNAME */   // Vendor naming, upstream ao486's: `audio_l`/`audio_r`
                                       // overlap AUDIO_L/AUDIO_R in case only. Renaming them is an
                                       // edit to a vendored file for no behavioural gain.
/* verilator lint_off IMPLICITSTATIC */ // The function-local regs (old_clk, clk_d1/clk_d2,
                                       // old_wr/rd_req) are upstream's, and their lifetime is
                                       // static in every tool this builds on; `automatic` would
                                       // change the vendor copy for no behavioural gain.
module cdda #(parameter CLK_AUDIO_RATE)
(
	input             CLK,
	output reg        CDDA_REQ,
	input             CDDA_WR,
	input      [31:0] CDDA_DATA,
	input       [3:0] VOLUME_L,
	input       [3:0] VOLUME_R,

	input             CLK_AUDIO,
	output reg        AUDIO_CE = 0,
	output reg [15:0] AUDIO_L = 0,
	output reg [15:0] AUDIO_R = 0
);

localparam SECTOR_SIZE  = 2352*8/32;
localparam BUFFER_WIDTH = $clog2(2 * SECTOR_SIZE);
localparam BUFFER_SIZE  = 2**BUFFER_WIDTH;

// The accumulator's step (88200) and wrap threshold (CLK_AUDIO_RATE) share a common factor G
// (600 at 24.576 MHz), and the counter only ever holds multiples of G (it starts at 0, adds 88200
// and subtracts CLK_AUDIO_RATE), so it runs in units of G: step 147, threshold 40960, 16 bits
// instead of 32. The toggle instants are identical clock for clock.
function automatic integer gcd(input integer a, input integer b);
	integer x, y, t;
	begin
		x = a; y = b;
		while (y != 0) begin t = x % y; x = y; y = t; end
		gcd = x;
	end
endfunction
localparam integer DIV_G    = gcd(CLK_AUDIO_RATE, 88200);
localparam integer DIV_STEP = 88200 / DIV_G;
localparam integer DIV_WRAP = CLK_AUDIO_RATE / DIV_G;
localparam integer CNT_W    = $clog2(DIV_WRAP + DIV_STEP);
/* verilator lint_off WIDTHTRUNC */   // CNT_W = $clog2(DIV_WRAP+DIV_STEP) bits hold both values, so
                                      // narrowing the 32-bit integers drops only zero bits
localparam [CNT_W-1:0] DIV_STEP_V = DIV_STEP;
localparam [CNT_W-1:0] DIV_WRAP_V = DIV_WRAP;
/* verilator lint_on WIDTHTRUNC */

// Power-up state (review r2-resets F3): the CLK_AUDIO domain has no reset and
// the seeds below are the whole of its initialisation. Unseeded, the fractional
// divider X-locks in 4-state sim (clk_44100_cnt <= X + 88200 = X and the wrap
// compare is X) and AUDIO_CE/AUDIO_L/AUDIO_R never resolve; the ring pointers X
// poison buffer_q's read of the (deliberately unreset) ring array. Seeded: the
// divider starts at 0 and AUDIO_CE pulses at the divided rate from the first
// wraps; the ring starts empty (read_addr == write_addr) so the drain emits
// silence until the first CDDA_WR.
reg         clk_44100 = 0;
reg  [CNT_W-1:0] clk_44100_cnt = 0;
// 88200 = 2 x 44100, the accumulator step that makes CLK_AUDIO_RATE (24576000, the wrap
// threshold and the named side of this arithmetic) the sample rate: the counter adds a toggle
// period's worth per CLK_AUDIO cycle, so clk_44100 toggles every CLK_AUDIO_RATE/88200 = 278.64
// CLK_AUDIO cycles (88.2 kHz) and AUDIO_CE pulses on its rising half at 44100 Hz.
wire [CNT_W-1:0] clk_44100_cnt_next = clk_44100_cnt + DIV_STEP_V;
wire [15:0] audio_l_clk_audio, audio_r_clk_audio;
reg [15:0] audio_l = 0;
reg [15:0] audio_r = 0;
reg [31:0] buffer[BUFFER_SIZE];
reg [31:0] buffer_q = 0;

cdc_vector_handshake_continuous #(
    .DATA_WIDTH(16*2)
) audio_cdc (
    .clk_in(CLK),
    .clk_out(CLK_AUDIO),
    .data_in({audio_l, audio_r}),
    .data_out({audio_l_clk_audio, audio_r_clk_audio})
);

always @(posedge CLK_AUDIO) begin
	reg old_clk = 0;

	clk_44100_cnt <= clk_44100_cnt_next;
	if (clk_44100_cnt_next >= DIV_WRAP_V) begin
		clk_44100 <= ~clk_44100;
		clk_44100_cnt <= clk_44100_cnt_next - DIV_WRAP_V;
	end

	AUDIO_CE <= 0;
	old_clk <= clk_44100;
	if(~old_clk & clk_44100) begin
		AUDIO_CE <= 1;
		AUDIO_L <= $signed(audio_l_clk_audio) >>> ~VOLUME_L;
		AUDIO_R <= $signed(audio_r_clk_audio) >>> ~VOLUME_R;
	end
end

reg        wr_req = 0;

reg [BUFFER_WIDTH-1:0] read_addr = 0, write_addr = 0;
reg   [BUFFER_WIDTH:0] filled_cnt = 0;
initial filled_cnt = 0;
/* verilator lint_on PROCASSINIT */
/* verilator lint_on SIMILARNAME */

always @(posedge CLK) begin
	reg old_clk = 0;
	reg clk_d1 = 0, clk_d2 = 0;
	reg old_wr = 0, rd_req = 0;

	rd_req <= 0;
	wr_req <= 0;
	if(wr_req) write_addr <= write_addr + 1'b1;

	old_wr <= CDDA_WR;
	if(~old_wr && CDDA_WR && (write_addr+1'd1) != read_addr) wr_req <= 1;

	clk_d1 <= clk_44100;
	clk_d2 <= clk_d1;
	if(clk_d2 == clk_d1) begin
		old_clk <= clk_d2;
		if(old_clk & ~clk_d2) begin
			if(read_addr == write_addr) begin
				audio_l <= 0;
				audio_r <= 0;
			end
			else begin
				rd_req <= 1;
				audio_l <= buffer_q[15:0];
				audio_r <= buffer_q[31:16];
				read_addr <= read_addr + 1'd1;
			end
		end
	end

	filled_cnt <= filled_cnt + wr_req - rd_req;
	CDDA_REQ <= (BUFFER_SIZE[BUFFER_WIDTH:0] - filled_cnt >= SECTOR_SIZE[BUFFER_WIDTH:0]);
end

always @(posedge CLK) begin
	buffer_q <= buffer[read_addr];
	if (wr_req) buffer[write_addr] <= CDDA_DATA;
end

/* verilator lint_on IMPLICITSTATIC */

endmodule

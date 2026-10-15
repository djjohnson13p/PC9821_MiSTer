// gath_cone_merge.sv -- pre-merge byte-select form of the gather write-data cone.
//
// Class-1 value-identical rewrite of the write-data tail of sdram.v's gather path:
// the per-byte new-vs-old select (gk_ws_be) is HOISTED out of the critical path into a
// per-entry pre-computed 32-bit merged word (mword[e], a pure function of the REGISTERS
// gk_be/gk_din/gk_old), so the critical gk_n -> gk_wmap -> ... -> gk_wdat path only pays
// the 4-entry word mux and a single half select instead of the array-read mux + the
// two-level byte merge. The slot map is the ORIGINAL serial scan (unchanged).
`default_nettype none
module gath_cone_merge (
    input  [3:0]        gk_n,
    input  [3:0][3:0]   gk_be,
    input  [3:0]        gk_wc,
    input  [3:0][31:0]  gk_din,
    input  [3:0][31:0]  gk_old,
    output [15:0]       gk_wdat,
    output [3:0]        gk_wmap5,
    output [5:0]        gk_rtot,
    output [5:0]        gk_wtot
);
    localparam integer GATHER_K = 4;

    reg  [3:0] gk_rmap [0:2*GATHER_K-1];
    reg  [3:0] gk_wmap [0:2*GATHER_K-1];
    reg  [5:0] gk_rtot_r, gk_wtot_r;
    always @* begin : gk_slot_maps
        integer gi, gh, gra, gwa;
        reg [3:0] gbe_i, gbe_h;
        gra = 0; gwa = 0;
        for (gi = 0; gi < 2*GATHER_K; gi = gi + 1) begin
            gk_rmap[gi] = 4'd0;
            gk_wmap[gi] = 4'd0;
        end
        for (gi = 0; gi < GATHER_K; gi = gi + 1) begin
            gbe_i = gk_be[gi];
            for (gh = 0; gh < 2; gh = gh + 1) begin
                gbe_h = gh[0] ? gbe_i[3:2] : gbe_i[1:0];
                if ((gi < gk_n) && (gbe_h != 2'b00)) begin
                    gk_wmap[gwa] = {gi[2:0], gh[0]};
                    gwa = gwa + 1;
                    if (gbe_h != 2'b11) begin
                        gk_rmap[gra] = {gi[2:0], gh[0]};
                        gra = gra + 1;
                    end
                end
            end
        end
        gk_rtot_r = gra[5:0];
        gk_wtot_r = gwa[5:0];
    end

    // ---- pre-computed per-entry 32-bit byte-merged word (OFF the critical path:
    // ---- pure function of the gk_be/gk_din/gk_old registers) ----
    wire [31:0] mword [0:3];
    generate
        genvar ee;
        for (ee = 0; ee < 4; ee = ee + 1) begin : gen_mword
            assign mword[ee] = {
                gk_be[ee][3] ? gk_din[ee][31:24] : gk_old[ee][31:24],
                gk_be[ee][2] ? gk_din[ee][23:16] : gk_old[ee][23:16],
                gk_be[ee][1] ? gk_din[ee][15:8]  : gk_old[ee][15:8],
                gk_be[ee][0] ? gk_din[ee][7:0]   : gk_old[ee][7:0]};
        end
    endgenerate

    // ---- critical write-data tail: wmap -> slot -> merged word -> half select ----
    wire  [2:0] gk_ws   = gk_wmap[gk_wc[3:0]][2:0];
    wire  [1:0] gk_ws_e = gk_ws[2:1];
    wire        gk_ws_h = gk_ws[0];
    wire [31:0] gk_mw   = mword[gk_ws_e];
    wire [15:0] gk_wdat_w = gk_ws_h ? gk_mw[31:16] : gk_mw[15:0];

    assign gk_wdat  = gk_wdat_w;
    assign gk_wmap5 = gk_wmap[5];
    assign gk_rtot  = gk_rtot_r;
    assign gk_wtot  = gk_wtot_r;
endmodule
`default_nettype wire

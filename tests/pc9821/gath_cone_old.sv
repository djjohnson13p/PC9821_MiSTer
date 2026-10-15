// gath_cone_old.sv -- the CURRENT (pre-cut) gather-RMW write-data cone, extracted
// faithfully from src/memory/sdram.v as a standalone combinational module for the
// sdram-hunt depth measurement + equivalence proof. GATHER_K = 4 (2*GATHER_K = 8 slots).
//
// Critical path (from STA): gk_n -> gk_slot_maps (serial gwa scan) -> gk_wmap ->
// gk_ws -> gk_ws_e -> gk_din/gk_old/gk_be array read -> gk_wdat byte-merge -> dq_out.
`default_nettype none
module gath_cone_old (
    input  [3:0]        gk_n,       // session entry count (1..4)
    input  [3:0][3:0]   gk_be,      // latched byte enables per entry
    input  [3:0]        gk_wc,      // write-phase slot counter (index into gk_wmap)
    input  [3:0][31:0]  gk_din,     // latched store data per entry
    input  [3:0][31:0]  gk_old,     // latched read-back data per entry
    output [15:0]       gk_wdat,    // the merged half -> dq_out
    output [3:0]        gk_wmap5,   // slot 5 of the write map (the critical slot)
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

    wire  [3:0] gk_ws   = gk_wmap[gk_wc[3:0]];
    wire  [2:0] gk_ws_e = gk_ws[3:1];
    wire        gk_ws_h = gk_ws[0];
    wire [31:0] gk_ws_nd = gk_din[gk_ws_e];
    wire [31:0] gk_ws_od = gk_old[gk_ws_e];
    wire  [3:0] gk_ws_be = gk_be[gk_ws_e];
    wire [15:0] gk_wdat_w = gk_ws_h
        ? {gk_ws_be[3] ? gk_ws_nd[31:24] : gk_ws_od[31:24],
           gk_ws_be[2] ? gk_ws_nd[23:16] : gk_ws_od[23:16]}
        : {gk_ws_be[1] ? gk_ws_nd[15:8]  : gk_ws_od[15:8],
           gk_ws_be[0] ? gk_ws_nd[7:0]   : gk_ws_od[7:0]};

    assign gk_wdat  = gk_wdat_w;
    assign gk_wmap5 = gk_wmap[5];
    assign gk_rtot  = gk_rtot_r;
    assign gk_wtot  = gk_wtot_r;
endmodule
`default_nettype wire

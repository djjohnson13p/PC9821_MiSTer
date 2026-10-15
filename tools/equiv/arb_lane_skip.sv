// PLANT: wire [3:0] n_skip = lane_rmw_hold ? g_datum : 4'd0; => wire [3:0] n_skip = lane_rmw_hold ? c_datum : 4'd0;
// Combinational proof: pc9821_gvram_arb's GRCG zero-lane skip (lane_skip_hold) takes the same value
// when the owner mux that chose between the plain, GRCG and EGC byte-zero flags is dropped in favour
// of the GRCG's flags alone, for every owner state the arbiter can be in: the skip is applied only
// under lane_rmw_hold, which requires cc_owns_grcg, and cc_owns_plain is by definition neither
// owner. (cc_owns_egc and cc_owns_grcg are exclusive: the egc arm is tested first.)
module m(input owns_egc_raw, input owns_grcg_raw, input ef_wr, input hold_rmw,
         input [3:0] c_datum, input [3:0] g_datum, input [3:0] e_datum, output mismatch);
  wire cc_owns_egc   = owns_egc_raw;
  wire cc_owns_grcg  = !cc_owns_egc && owns_grcg_raw;
  wire cc_owns_plain = !cc_owns_egc && !cc_owns_grcg;
  wire lane_rmw_hold = ef_wr && cc_owns_grcg && hold_rmw;
  wire [3:0] o_hold = cc_owns_plain ? c_datum : cc_owns_grcg ? g_datum : e_datum;
  wire [3:0] o_skip = lane_rmw_hold ? o_hold : 4'd0;
  wire [3:0] n_skip = lane_rmw_hold ? g_datum : 4'd0;
  assign mismatch = o_skip != n_skip;
endmodule

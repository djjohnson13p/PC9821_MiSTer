// PLANT: wire inv = (!r2 || p) && (!gr || g) && (!er || (!r2 && !gr)); => wire inv = (!r2 || p) && (!er || (!r2 && !gr));
// PLANT: wire answered = !er || e; => wire answered = 1'b1;
// PLANT: egc_cpu_resp_valid  ? egc_cpu_dout : c_dout_r; => c_dout_r;
// Combinational proof: pc9821_gvram_arb's response routing (TB cut) equals the owner mux it
// replaced, for every owner state and every strobe/datum, under the three implications the
// arbiter holds in every reachable state (tools/check_arb_resp_inv.py proves them by induction):
// (1) cs == C_RESP2 implies the plain owner; (2) grcg_cpu_resp_valid implies the GRCG owner;
// (3) egc_cpu_resp_valid is never beside C_RESP2 or the GRCG strobe. The strobes and the line
// strobe must match on every cycle, the word datum on every cycle its strobe is high (the only
// cycles pc9821_memory_subsystem and pc9821_gvram_share read it). The owners are the arbiter's own
// exclusive pair: the EGC arm is tested first.
// The ONE excluded case (`answered`): an EGC strobe while the live owner is not the EGC, where the
// old mux masked the strobe. No legal execution reaches it (the CPU holds its request through the
// ready edge, so pc9821_gvram_share cannot grant a GDC visit before the strobe's cycle; see the
// assign in pc9821_gvram_arb). The second PLANT shows the routing differs from the old mux there
// and only there.
module m(input egc_raw, input grcg_raw, input r2, input lm,
         input grcg_cpu_resp_valid, input egc_cpu_resp_valid,
         input [31:0] c_dout_r, input [31:0] grcg_cpu_dout, input [31:0] egc_cpu_dout,
         output mismatch);
  wire e = egc_raw;
  wire g = !e && grcg_raw;
  wire p = !e && !g;
  wire gr = grcg_cpu_resp_valid, er = egc_cpu_resp_valid;
  wire inv = (!r2 || p) && (!gr || g) && (!er || (!r2 && !gr));
  wire answered = !er || e;
  // the old owner mux
  wire        o_rv   = p ? (r2 && !lm) : g ? gr : er;
  wire [31:0] o_d    = p ? c_dout_r : g ? grcg_cpu_dout : egc_cpu_dout;
  wire        o_line = p && r2 && lm;
  // the new routing, as pc9821_gvram_arb writes it
  wire        n_rv   = (r2 && !lm) || grcg_cpu_resp_valid ||
                       egc_cpu_resp_valid;
  wire [31:0] n_d    = grcg_cpu_resp_valid ? grcg_cpu_dout :
                       egc_cpu_resp_valid  ? egc_cpu_dout : c_dout_r;
  wire        n_line = r2 && lm;
  assign mismatch = inv && answered &&
                    ((o_rv != n_rv) || (o_line != n_line) || (o_rv && (o_d != n_d)));
endmodule

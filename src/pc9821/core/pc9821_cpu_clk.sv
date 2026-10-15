// The CPU-throttle platform side: the gated CPU clock (this file) and the bus bridge (pc9821_cpu_bus_bridge.sv) between the gated
// z486 and the clk_sys platform.
//
// z486 has no speed input (src/z486/docs/throttle.md, the 0ebf0d0 re-vendor): a slower CPU is the
// same CPU seeing fewer clock edges. cpu_throttle (src/z486/cpu_throttle.sv) produces
// `cpu_ce`, REGISTERED on clk_sys: cpu_ce high in a clk_sys cycle means the CPU gets the edge
// that ENDS that cycle. The platform therefore owes the CPU (src/z486/docs/throttle.md, "What the
// platform must do"):
//   - a glitch-free gated clock (this module);
//   - a transfer that happens exactly in the cpu_ce cycles in which valid && ready held, so a
//     responder's one-cycle ready in a non-enabled cycle is HELD until the next enabled edge
//     and the responder does not see `valid` again meanwhile (the accept latch below);
//   - every pulse input held until the next enabled edge: resp_valid with its data (a FIFO,
//     because the SDRAM burst cannot be back-pressured), and cache_flush;
//   - every one-CPU-cycle output pulse sampled under cpu_ce.
// With cpu_ce constant 1 (setting 0, "Full") no latch is ever set and the FIFO is never
// written, so every output equals its input: the bridge is a wire and the full-speed core is
// cycle-identical to the ungated one (the boot golden pins that).

// The gated CPU clock. On the FPGA it is a Cyclone V clock-control block (the ALTCLKCTRL
// atom, cyclonev_clkena) whose `ena` is registered on the FALLING edge of its input clock, so
// a cpu_ce that changes just after a rising edge cannot glitch the output - the property
// cpu_ce being registered relies on (fork cpu_throttle.sv header). It costs no LABs and one
// global clock network. Verilator builds the fork's behavioural low-phase latch + AND
// (cpu_clk_gate), which is NEVER synthesised (src/z486/docs/cpu-review2-2026-10-10.md section 7,
// item 3).
module pc9821_cpu_clk (
    input  wire clk,    // clk_sys
    input  wire ena,    // cpu_ce
    output wire gclk    // the CPU's clock
);
`ifdef VERILATOR
    cpu_clk_gate u_gate (.clk(clk), .ena(ena), .gclk(gclk));
`else
    cyclonev_clkena #(
        .clock_type("Global Clock"),
        .ena_register_mode("falling edge"),
        .ena_register_power_up("high"),
        .disable_mode("low"),
        .test_syn("high")
    ) u_clkena (
        .inclk(clk), .ena(ena), .enaout(), .outclk(gclk)
    );
`endif
endmodule


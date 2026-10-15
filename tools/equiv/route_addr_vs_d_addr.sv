// PLANT: wire win0_moved_m = win0_in_window && (win0_sel != 8'h08) => wire win0_moved_m = win0_in_window && (win0_sel != 8'h09)
// PLANT: eff_addr = sys16m_mirror ? {12'd0, cpu_addr[19:0]} => eff_addr = sys16m_mirror ? {12'd0, cpu_addr[18:0], 1'b0}
// Combinational proof: pc9821_memory_subsystem's route_addr (window 0 translation computed from
// the raw address) equals pc9821_memory_map's d_addr (computed from the subsystem's eff_addr), for
// every input, so the subsystem can reuse the map's `addr_ge_ram` instead of a second compare.
module m(input [31:0] cpu_addr, input sys16m_en, input [7:0] win0_sel, output mismatch);
  wire sys16m_mirror = sys16m_en && !(|cpu_addr[31:24]) && (cpu_addr[23:16] >= 8'hFA);
  wire peg_high = (&cpu_addr[31:24]) && (cpu_addr[23:20] == 4'hF) && !cpu_addr[19];
  wire bios_top = (&cpu_addr[31:21]) && (cpu_addr[19:15] >= 5'b11101);
  wire [31:0] eff_addr = sys16m_mirror ? {12'd0, cpu_addr[19:0]} :
                         peg_high       ? {8'd0,  cpu_addr[23:0]} :
                         bios_top       ? {12'd0, cpu_addr[19:0]} : cpu_addr;
  // subsystem: raw-address test, eff_addr data
  wire win0_moved_s = !(|cpu_addr[31:20]) && (cpu_addr[19:17] == 3'b100) && (win0_sel != 8'h08);
  wire [8:0] win0_hi_s = {1'b0, win0_sel} + {8'd0, cpu_addr[16]};
  wire [31:0] route_addr = win0_moved_s ? {7'd0, win0_hi_s, eff_addr[15:0]} : eff_addr;
  // map: test on the translated address
  wire win0_in_window = !(|eff_addr[31:20]) && (eff_addr[19:17] == 3'b100);
  wire win0_moved_m = win0_in_window && (win0_sel != 8'h08);
  wire [8:0] win0_hi_m = {1'b0, win0_sel} + {8'd0, eff_addr[16]};
  wire [31:0] d_addr = win0_moved_m ? {7'd0, win0_hi_m, eff_addr[15:0]} : eff_addr;
  assign mismatch = route_addr != d_addr;
endmodule

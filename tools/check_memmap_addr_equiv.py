#!/usr/bin/env python3
"""check_memmap_addr_equiv.py -- prove pc9821_memory_map's spliced `mem_addr` equals the
pre-rewrite 32-bit-adder form for every input the system can present.

The rewrite (area-core lane) builds each window arm of `mem_addr` as {base[31:20], 20-bit
sum} instead of a 32-bit add. That is exact only under the invariants the system guarantees:

  * pack_base is one of the eight whole-MiB RAM-size constants (1 .. 96 MiB), so its low 20
    bits are zero;
  * ems_page_base / fw_shadow_base / peg_base are pack_base + 1 MiB + 0x48000 / 0x58000 /
    0x80000 (pc9821_memory_subsystem, PACK_BYTES = 1 MiB);
  * peg_window is only asserted for an address in 0xF00000-0xF7FFFF (the subsystem decodes
    it on the same post-window-0 address the map calls d_addr);
  * win0_sel_moved == (win0_sel != 8'h08): pc9821_iobus registers the flag with win0_sel
    (tools/check_win0_moved_inv.py proves it in every reachable cycle).

It also proves every other output of the map equal (the window decodes, the ready/response
outputs), which covers the late-muxed region decode (`region_dec`).

The map's address is pc9821_memory_subsystem's eff_addr, and the current map also takes the
untranslated address with eff_addr's arm (cpu_addr_raw / xl_low20 / xl_peg, P0-d). The wrapper
therefore drives the RAW address and sys16m_en free and forms eff_addr and the two selects
exactly as the subsystem does; every 32-bit eff_addr is reachable that way (an untranslated
address is its own raw form), so the old module still sees every input it ever could.

The proof wraps the OLD module (from `--old REV`, renamed) and the CURRENT file under those
invariants, with every other input free, and asks yosys's SAT engine whether `mem_addr` can
differ. `--plant` mutates the current text and the run must then FAIL; `--selftest` runs the
clean proof and each plant.

  python3 tools/check_memmap_addr_equiv.py --old ac2538dc
  python3 tools/check_memmap_addr_equiv.py --selftest
"""
import argparse
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = "src/pc9821/core/pc9821_memory_map.sv"
DEFAULT_OLD = "ac2538dc"

PLANTS = {
    # a wrong constant in one arm
    "sound_rom_const": ("20'hC6800", "20'hC6000"),
    # bios_lower offset without the half-block flip
    "bios_flip": ("1'b1, ~d_addr[15]", "1'b1, d_addr[15]"),
    # the PEGC window's bit 19 (peg_base's 0x80000)
    "peg_bit19": ("{peg_hi, peg_base[19], d_addr[18:0]}", "{peg_hi, 1'b0, d_addr[18:0]}"),
    # the late-muxed region decode: the moved arm's sound-ROM window one bit off
    "region_sound": ("first && (a[19:16] == 4'hC) && a[15] && a[14],", "first && (a[19:16] == 4'hC) && a[15],"),
    # C7-head: the registered window-0 flag read inverted
    "win0_flag": ("win0_moved = win0_in_window && win0_sel_moved;", "win0_moved = win0_in_window && !win0_sel_moved;"),
    # the late-muxed region decode: the arms swapped
    "region_swap": ("win0_moved ? dv_mv :", "win0_moved ? dv_raw :"),
    # P0-d: the low-20 translation arm decoded on the untranslated address
    "xl_low20_arm": ("xl_low20 ? dv_l20 :", "xl_low20 ? dv_raw :"),
    # P0-d: the PEGC alias arm's RAM-bound compare on the untranslated address
    "xl_peg_ge": ("xl_peg ? ge_peg : ge_raw;", "xl_peg ? ge_raw : ge_raw;"),
}

WRAP = r"""
module wrap(
  input [2:0] sel,
  input [3:0] top_bank, input ide_rom_enable, input [1:0] d8_bank, input ide_ram_gate,
  input bios_ram_gate, input top_shadow_en, input fw_shadow_dirty, input [1:0] ems_state,
  input [7:0] win0_sel, input peg_window_i, input pegc_256, input pegc_plane,
  input [3:0] pegc_bank_a, input [3:0] pegc_bank_b,
  input [31:0] cpu_addr_raw, input sys16m_en, input [31:0] cpu_din, input [3:0] cpu_be, input [7:0] cpu_burstcount,
  input cpu_line_read, input cpu_valid, input cpu_write, input [31:0] guest_ram_bytes,
  output mismatch);
  reg [31:0] pack_base;
  always @* case (sel)
    3'd0: pack_base = 32'h0010_0000; 3'd1: pack_base = 32'h0020_0000;
    3'd2: pack_base = 32'h0040_0000; 3'd3: pack_base = 32'h0080_0000;
    3'd4: pack_base = 32'h0100_0000; 3'd5: pack_base = 32'h0200_0000;
    3'd6: pack_base = 32'h0400_0000; default: pack_base = 32'h0600_0000;
  endcase
  wire [31:0] ems_page_base  = pack_base + 32'h0010_0000 + 32'h0004_8000;
  wire [31:0] fw_shadow_base = pack_base + 32'h0010_0000 + 32'h0005_8000;
  wire [31:0] peg_base       = pack_base + 32'h0010_0000 + 32'h0008_0000;
  // pc9821_memory_subsystem's translation (sys16m_mirror / peg_high / bios_top -> eff_addr)
  wire sys16m_mirror = sys16m_en && !(|cpu_addr_raw[31:24]) && (cpu_addr_raw[23:16] >= 8'hFA);
  wire peg_high = (&cpu_addr_raw[31:24]) && (cpu_addr_raw[23:20] == 4'hF) && !cpu_addr_raw[19];
  wire bios_top = (&cpu_addr_raw[31:21]) && (cpu_addr_raw[19:15] >= 5'b11101);
  wire [31:0] cpu_addr = sys16m_mirror ? {12'd0, cpu_addr_raw[19:0]} :
                         peg_high      ? {8'd0,  cpu_addr_raw[23:0]} :
                         bios_top      ? {12'd0, cpu_addr_raw[19:0]} : cpu_addr_raw;
  // the window-0 translation exactly as pc9821_memory_map computes d_addr
  wire win0_in = !(|cpu_addr[31:20]) && (cpu_addr[19:17] == 3'b100);
  wire win0_mv = win0_in && (win0_sel != 8'h08);
  wire [8:0] win0_hi = {1'b0, win0_sel} + {8'd0, cpu_addr[16]};
  wire [31:0] d_addr = win0_mv ? {7'd0, win0_hi, cpu_addr[15:0]} : cpu_addr;
  wire peg_window = peg_window_i && (d_addr[31:19] == 13'h01E);
  wire [31:0] a_old, a_new;
  wire o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11;
  wire [1:0] p1,p2; wire [14:0] q1; wire [31:0] c1,c2,c3,c4,c5,c6,c7;
  wire [127:0] l1; wire [3:0] be1; wire [7:0] bc1; wire v1,w1;
  wire cr1,cv1,clv1, cr2,cv2,clv2;
  wire [31:0] x1, x2; wire [3:0] be2; wire [7:0] bc2; wire v2,w2;
  wire a1,e1,s1, a2,e2,s2, ga1, ga2, gb1, gb2, gc1, gc2, gv1, gv2; wire [1:0] gp1, gp2; wire [14:0] go1, go2;
  wire [31:0] do1, do2; wire [127:0] ld1, ld2;
  pc9821_memory_map_old u_old(.top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(d8_bank),
    .ide_ram_gate(ide_ram_gate), .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en),
    .fw_shadow_dirty(fw_shadow_dirty), .fw_shadow_base(fw_shadow_base), .ems_state(ems_state),
    .ems_page_base(ems_page_base), .win0_sel(win0_sel), .pack_base(pack_base),
    .guest_ram_bytes(guest_ram_bytes), .peg_window(peg_window), .peg_base(peg_base),
    .pegc_256(pegc_256), .pegc_plane(pegc_plane), .pegc_bank_a(pegc_bank_a), .pegc_bank_b(pegc_bank_b),
    .pegc_packed(ga1), .pegc_reg_win(gb1), .pegc_nc(gc1),
    .gvram_window(gv1), .gvram_win_plane(gp1), .gvram_win_offset(go1),
    .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(do1), .cpu_line_dout(ld1), .cpu_be(cpu_be),
    .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read), .cpu_valid(cpu_valid),
    .cpu_write(cpu_write), .cpu_ready(cr1), .cpu_resp_valid(cv1), .cpu_line_resp_valid(clv1),
    .absent_area(a1), .ems_open_bus(e1), .fw_shadow_store(s1),
    .mem_addr(a_old), .mem_din(x1), .mem_dout(32'd0), .mem_be(be1), .mem_burstcount(bc1),
    .mem_valid(v1), .mem_write(w1), .mem_ready(1'b0), .mem_resp_valid(1'b0));
  pc9821_memory_map u_new(.top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(d8_bank),
    .ide_ram_gate(ide_ram_gate), .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en),
    .fw_shadow_dirty(fw_shadow_dirty), .fw_shadow_base(fw_shadow_base), .ems_state(ems_state),
    .ems_page_base(ems_page_base), .win0_sel(win0_sel),
    .win0_sel_moved(win0_sel != 8'h08), .pack_base(pack_base),
    .guest_ram_bytes(guest_ram_bytes), .peg_window(peg_window), .peg_base(peg_base),
    .pegc_256(pegc_256), .pegc_plane(pegc_plane), .pegc_bank_a(pegc_bank_a), .pegc_bank_b(pegc_bank_b),
    .pegc_packed(ga2), .pegc_reg_win(gb2), .pegc_nc(gc2),
    .gvram_window(gv2), .gvram_win_plane(gp2), .gvram_win_offset(go2),
    .cpu_addr(cpu_addr), .cpu_addr_raw(cpu_addr_raw), .xl_low20(sys16m_mirror || bios_top),
    .xl_peg(peg_high), .cpu_din(cpu_din), .cpu_dout(do2), .cpu_line_dout(ld2), .cpu_be(cpu_be),
    .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read), .cpu_valid(cpu_valid),
    .cpu_write(cpu_write), .cpu_ready(cr2), .cpu_resp_valid(cv2), .cpu_line_resp_valid(clv2),
    .absent_area(a2), .ems_open_bus(e2), .fw_shadow_store(s2),
    .mem_addr(a_new), .mem_din(x2), .mem_dout(32'd0), .mem_be(be2), .mem_burstcount(bc2),
    .mem_valid(v2), .mem_write(w2), .mem_ready(1'b0), .mem_resp_valid(1'b0));
  // mem_addr is a don't-care wherever mem_valid is low (no backend request is issued)
  assign mismatch = v1 && (a_old != a_new);
  // and every other output must be untouched
  wire others = (v1 != v2) || (a1 != a2) || (e1 != e2) || (s1 != s2) || (ga1 != ga2) ||
                (gb1 != gb2) || (gc1 != gc2) || (gv1 != gv2) || (gp1 != gp2) || (go1 != go2) ||
                (cr1 != cr2) || (cv1 != cv2) || (clv1 != clv2) || (do1 != do2) || (ld1 != ld2);
  wire unused = o1;
endmodule
"""


def git_show(rev):
    out = subprocess.run(["git", "show", "%s:%s" % (rev, MAP)], cwd=REPO,
                         capture_output=True, text=True)
    if out.returncode:
        sys.exit("git show failed: " + out.stderr)
    return out.stdout


def prove(old_rev, plant=None):
    old = git_show(old_rev).replace("module pc9821_memory_map", "module pc9821_memory_map_old")
    new = open(os.path.join(REPO, MAP)).read()
    if plant:
        a, b = PLANTS[plant]
        if a not in new:
            sys.exit("plant %s: anchor text not found" % plant)
        new = new.replace(a, b, 1)
    wrap = WRAP.replace("wire unused = o1;", "").replace("wire o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11;", "")
    wrap = wrap.replace("  assign mismatch = v1 && (a_old != a_new);",
                        "  assign mismatch = (v1 && (a_old != a_new)) || others;")
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "old.sv"), "w").write(old)
        open(os.path.join(tmp, "new.sv"), "w").write(new)
        open(os.path.join(tmp, "wrap.sv"), "w").write(wrap)
        script = ("read_verilog -sv old.sv new.sv wrap.sv; hierarchy -top wrap; proc; flatten; memory_map; "
                  "opt_clean; sat -prove mismatch 0 -verify -show-inputs")
        r = subprocess.run(["yosys", "-p", script], cwd=tmp, capture_output=True, text=True)
    proved = r.returncode == 0 and "SUCCESS!" in r.stdout
    return proved, r.stdout[-3000:] + r.stderr[-1500:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", default=DEFAULT_OLD)
    ap.add_argument("--plant", choices=sorted(PLANTS))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        ok, log = prove(a.old)
        if not ok:
            print(log)
            sys.exit("selftest: the clean proof failed")
        for p in sorted(PLANTS):
            ok, _ = prove(a.old, p)
            if ok:
                sys.exit("selftest: plant %s was NOT caught" % p)
        print("check_memmap_addr_equiv: selftest PASS (clean proven, %d plants caught)" % len(PLANTS))
        return
    ok, log = prove(a.old, a.plant)
    if a.plant:
        print("plant %s: %s" % (a.plant, "NOT caught" if ok else "caught (as required)"))
        sys.exit(1 if ok else 0)
    print(log if not ok else "check_memmap_addr_equiv: PROVEN (mem_addr and every other output equal, the late-muxed region decode included)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

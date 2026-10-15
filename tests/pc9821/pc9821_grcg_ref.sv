`default_nettype none

// pc9821_grcg_ref -- the GOLDEN GRCG, a behavioural reference for the differential
// bench tb_pc9821_grcg_ops.sv. A direct transcription of NP2kai:
//
//   io/crtc.c      crtc_o7c (mode, tile-pointer reset), crtc_o7e (tile byte, both
//                  byte halves), crtc_i7c (the modereg read-back)
//   vram/vram.h    the operating-mode decode: VOPBIT_GRCG bit2 = mode bit 6,
//                  bit3 = mode bit 7, and i386c/cpumem.c vacctbl[] selecting
//                  memvram (plain), memrmw (RMW write), memtdw (TDW write) and
//                  memtcr (the tile-compare READ), or memegc when the EGC gate wins.
//   mem/memvram.c  VRAMRD/WR8/16/32, RMWWR8/16, TDWWR8/16, TCRRD8/16
//
// The plane store is [page][plane][offset in the 32 KiB window]: NP2kai's
// mem[LOW15(a) + p*VRAM_STEP + VRAM_x] with the four VRAM bases dropped, so
// page 0/1 is memvram0/memvram1 and the addressed plane is the window's own.
//
// The store side is atomic. The tile register's second byte half (b[1]) is written
// by crtc_o7e but read only by TCRRD16 through .w, so CPU writes see b[0] alone.
//
// The register READ side (crtc_i7c returning modereg) is modelled for the record;
// the RTL has none by design (both ports read 0xFF on the machine), so the bench
// records it as a deviation rather than driving it.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module pc9821_grcg_ref #(
    parameter [31:0] GVRAM_BASE = 32'h0300_0000
);

  reg [7:0] mem [0:1][0:3][0:32767];

  reg [7:0] r_mode;        // grcg.modereg
  reg [7:0] r_tile [0:3];  // grcg.tile[i].b[0]
  reg [1:0] r_cnt;         // grcg.counter

  // The bench's SDRAM backend is initialised with this same function of the SDRAM
  // byte address, so DUT and reference start from identical memory and no seeding
  // store can itself be the thing under test.
  function [7:0] grcg_pat(input [31:0] a);
    grcg_pat = a[7:0] ^ {2'b0, a[13:8]} ^ {4'b0, a[19:16]} ^ 8'hA5;
  endfunction

  task automatic rst();
    integer p, pl, o;
    begin
      r_mode = 8'h00;
      r_cnt  = 2'd0;
      for (p = 0; p < 4; p = p + 1) r_tile[p] = 8'h00;
      for (p = 0; p < 2; p = p + 1)
        for (pl = 0; pl < 4; pl = pl + 1)
          for (o = 0; o < 32768; o = o + 1)
            mem[p][pl][o] = grcg_pat(GVRAM_BASE + 4 * (p * 32768 + o) + pl);
    end
  endtask

  // io/crtc.c crtc_o7c: store the mode and restart the tile pointer.
  task automatic set_mode(input [7:0] v);
    begin
      r_mode = v;
      r_cnt  = 2'd0;
    end
  endtask

  // io/crtc.c crtc_o7e: the next of four tile bytes, B,R,G,E; the pointer wraps mod 4.
  task automatic w_tile(input [7:0] v);
    begin
      r_tile[r_cnt] = v;
      r_cnt = r_cnt + 2'd1;
    end
  endtask

  // One CPU access. `plane` is the addressed window (ignored by a GRCG store, which
  // reaches all four planes); `off` is the LOW15 plane offset.
  task automatic op(input pg, input [1:0] plane, input [14:0] off,
                    input [31:0] din, input [3:0] be, input wr,
                    output [31:0] dout);
    integer k, p;
    reg [7:0] d;
    begin
      dout = 32'hFFFF_FFFF;
      if (!wr) begin
        // memvram0/1_rd8/16/32: the addressed window's plane, byte k at off+k for each
        // enabled CPU byte lane. The mode-0x80 READ is memtcr (the tile-compare read) in
        // NP2kai, which the RTL does not have; tcr_read() models it and the bench records
        // the difference as a deviation, so the differential read path here is the plain
        // one the RTL answers.
        for (k = 0; k < 4; k = k + 1)
          dout[8 * k +: 8] = be[k] ? mem[pg][plane][off + k] : 8'h00;
      end else begin
        if (r_mode[7] && r_mode[6]) begin
          // memvram.c RMWWR: (old & ~data) | (tile & data), enabled planes only.
          for (k = 0; k < 4; k = k + 1)
            if (be[k]) begin
              d = din[8 * k +: 8];
              for (p = 0; p < 4; p = p + 1)
                if (!(r_mode & (8'h01 << p)))
                  mem[pg][p][off + k] = (mem[pg][p][off + k] & ~d) | (r_tile[p] & d);
            end
        end else if (r_mode[7]) begin
          // memvram.c TDWWR: the tile byte, the CPU datum ignored.
          for (k = 0; k < 4; k = k + 1)
            if (be[k])
              for (p = 0; p < 4; p = p + 1)
                if (!(r_mode & (8'h01 << p)))
                  mem[pg][p][off + k] = r_tile[p];
        end else begin
          // memvram.c VRAMWR: the window's plane.
          for (k = 0; k < 4; k = k + 1)
            if (be[k]) mem[pg][plane][off + k] = din[8 * k +: 8];
        end
      end
    end
  endtask

  function [7:0] peek(input pg, input [1:0] plane, input [14:0] off);
    peek = mem[pg][plane][off];
  endfunction

  // NP2kai's memtcr0_rd8/16/32 -- the tile-compare read the mode bit7|bit6 = 10 dispatch
  // (vacctbl index 8/9) selects. A 16-bit unit compares 16-bit WORDS and tile[].w is
  // {tile,tile} because crtc_o7e writes both byte halves; an 8-bit unit compares bytes
  // and returns one. The RTL has no such path, so the bench only uses this to state the
  // reference value it does not produce.
  task automatic tcr_read(input pg, input [1:0] plane, input [14:0] off,
                          input [3:0] be, output [31:0] dout);
    integer k, p;
    reg [7:0] bacc, tw;
    reg [15:0] wacc;
    begin
      dout = 32'd0;
      if (be == 4'hF) begin
        wacc = 16'h0000;
        for (p = 0; p < 4; p = p + 1)
          if (!(r_mode & (8'h01 << p))) begin
            tw = r_tile[p];
            wacc = wacc | ({mem[pg][p][off + 1], mem[pg][p][off]} ^ {tw, tw});
          end
        dout[15:0] = ~wacc;
        wacc = 16'h0000;
        for (p = 0; p < 4; p = p + 1)
          if (!(r_mode & (8'h01 << p))) begin
            tw = r_tile[p];
            wacc = wacc | ({mem[pg][p][off + 3], mem[pg][p][off + 2]} ^ {tw, tw});
          end
        dout[31:16] = ~wacc;
      end else begin
        for (k = 0; k < 4; k = k + 1)
          if (be[k]) begin
            bacc = 8'h00;
            for (p = 0; p < 4; p = p + 1)
              if (!(r_mode & (8'h01 << p))) bacc = bacc | (mem[pg][p][off + k] ^ r_tile[p]);
            dout[8 * k +: 8] = ~bacc;
          end
      end
    end
  endtask

  // io/crtc.c crtc_i7c: the mode read-back. The RTL has no read side.
  function [7:0] read_mode();
    read_mode = r_mode;
  endfunction

endmodule

`default_nettype wire

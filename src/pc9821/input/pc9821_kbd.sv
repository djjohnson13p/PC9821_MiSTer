// PC-98 keyboard controller - PC-9821 MiSTer core.
//
// Mainboard interface: uPD8251A at 0x41 (data) / 0x43 (control/status).
// NP2kai io/serial.c is the primary 8251/status/command-flow reference.
// MiSTer hps_io emits PS/2 Set-2 event bytes in ps2_key[7:0], with bit 8
// marking E0 extension, bit 9 pressed, and bit 10 toggled per event.
// Translation follows the physical Set-1-to-PC-98 correspondence in
// qemu-pc98 pc98-kbd.c, converted here to direct MiSTer Set-2 decoding.

`default_nettype none

module pc9821_kbd #(
    parameter integer SYS_CLOCK_HZ = 50_000_000,
    // OSD "Enter BIOS setup (hold HELP)": how long the injected HELP key is held.
    // 3 s is past the ITF's POST scan window (~1 s) and ends on a break, so the key is not left held into the OS.
    // 29 bits: the hold is SYS_CLOCK_HZ * 3, which is 360_000_000 at 120 MHz, and a
    // 28-bit field TRUNCATED it at the 100 and 120 MHz profiles - 300_000_000 mod 2^28
    // is 31_564_544, so the injected key was released after 0.32 s instead of 3 s and
    // the ITF's POST poll never saw HELP held.
    parameter [29:0] HELP_HOLD_CYCLES = 30'(SYS_CLOCK_HZ * 3),
    // Typematic auto-repeat, NP2kai keystat.c defaults (500 ms delay, 50 ms interval).
    // 26 bits: REPEAT_DELAY is SYS_CLOCK_HZ/2, which is 60_000_000 at 120 MHz and so
    // still inside 2^26 (67_108_864); a profile past 134 MHz would need widening.
    parameter [25:0] REPEAT_DELAY    = 26'(SYS_CLOCK_HZ / 2),
    parameter [25:0] REPEAT_INTERVAL = 26'(SYS_CLOCK_HZ / 20),
    // The RE-POKE tick: how often an unread delivered byte re-strokes the IRQ
    // request. NP2kai pokes pic_setirq(1) at EVERY keyboard transfer tick while
    // the receive side is not empty (io/serial.c keyboard_callback), with
    // keybrd.xferclock = pccore.realclock / 1920 (keyboard_changeclock) - one
    // byte-time per 1920 base-clock cycles. pccore.realclock is the base clock
    // at multiple 1 (pccore.h PCBASECLOCK25 = 2,457,600), so the transfer rate
    // is 2,457,600 / 1920 = 1,280 byte-times per second. That is the DEVICE's
    // rate - clk_sys only scales the count (the rate rule), and a bench
    // overrides this parameter to make the window observable.
    parameter [25:0] XFER_TICK_CYCLES = 26'(SYS_CLOCK_HZ / 1280)
) (
    input wire clk,
    input wire rst_n,

    input  wire       cs,
    input  wire       a0,   // 0=data, 1=control/status
    input  wire       wr,
    input  wire       rd,
    input  wire [7:0] din,
    output wire [7:0] dout,

    output wire irq,
    input wire [10:0] ps2_key,
    input wire        bios_setup,   // OSD: hold HELP from reset, so POST enters SETUP
    output wire [2:0] led_status,   // MiSTer hps_io order {scrolllock, numlock, capslock}

    // Bring-up telemetry: enough to tell "the MiSTer never gave us a key" from
    // "we never handed it to the guest" from "the guest never asked".
    output reg  [7:0] dbg_events,
    output reg  [7:0] dbg_delivered,
    output reg  [7:0] dbg_rd_data,
    output reg  [7:0] dbg_wr_ctrl,
    output wire       dbg_rts,
    output wire       dbg_rx_en,
    output reg  [7:0] dbg_last_del,    // last byte handed to the guest
    output reg  [7:0] dbg_ctrl0,       // 8251 mode byte (first control write)
    output reg  [7:0] dbg_ctrl1        // 8251 command byte (second control write)
);

  localparam [7:0] KST_RXRDY = 8'h02;
  localparam [7:0] KST_PARITY = 8'h08;
  localparam [7:0] KST_OVERRUN = 8'h10;
  localparam [7:0] KST_FRAMING = 8'h20;

  localparam [3:0] LOCK_NUM = 4'h1;
  localparam [3:0] LOCK_CAPS = 4'h4;
  localparam [3:0] LOCK_KANA = 4'h8;

  // Direct PS/2 Set-2 -> NEC PC-98 physical-key translation.
  function automatic [7:0] translate(input extended, input [7:0] set2);
    begin
      if (extended) begin
        case (set2)
          8'h11:   translate = 8'h35;  // right Alt -> XFER (NP2kai kbtrans.c)
          8'h14:   translate = 8'h73;  // right Ctrl -> GRPH (NP2kai kbtrans.c)
          8'h1F:   translate = 8'h77;  // left Win
          8'h27:   translate = 8'h78;  // right Win
          // Menu -> KANA 0x72, deliberately NOT NP2kai's APP 0x79: after the Round-3
          // remap no Set-2 code reached 0x72, so event_lock/the LOCK_KANA toggle/led_status[3]
          // were dead from the host. Menu is the least-used free Windows-cluster key.
          8'h2F:   translate = 8'h72;  // Menu -> KANA
          8'h4A:   translate = 8'h41;  // keypad /
          8'h5A:   translate = 8'h1C;  // keypad Enter
          8'h69:   translate = 8'h3F;  // End
          8'h6B:   translate = 8'h3B;  // Left
          8'h6C:   translate = 8'h3E;  // Home
          8'h70:   translate = 8'h38;  // Insert
          8'h71:   translate = 8'h39;  // Delete
          8'h72:   translate = 8'h3D;  // Down
          8'h74:   translate = 8'h3C;  // Right
          8'h75:   translate = 8'h3A;  // Up
          8'h77:   translate = 8'h60;  // Pause (hps_io normalized)
          8'h7A:   translate = 8'h37;  // Page Down
          8'h7C:   translate = 8'h61;  // Print Screen / SysRq
          8'h7D:   translate = 8'h36;  // Page Up
          default: translate = 8'hFF;
        endcase
      end else begin
        case (set2)
          8'h76: translate = 8'h00;  // Escape
          8'h16: translate = 8'h01;  // 1
          8'h1E: translate = 8'h02;  // 2
          8'h26: translate = 8'h03;  // 3
          8'h25: translate = 8'h04;  // 4
          8'h2E: translate = 8'h05;  // 5
          8'h36: translate = 8'h06;  // 6
          8'h3D: translate = 8'h07;  // 7
          8'h3E: translate = 8'h08;  // 8
          8'h46: translate = 8'h09;  // 9
          8'h45: translate = 8'h0A;  // 0
          8'h4E: translate = 8'h0B;  // minus
          8'h55: translate = 8'h0C;  // caret/equal
          8'h66: translate = 8'h0E;  // Backspace
          8'h0D: translate = 8'h0F;  // Tab
          8'h15: translate = 8'h10;  // Q
          8'h1D: translate = 8'h11;  // W
          8'h24: translate = 8'h12;  // E
          8'h2D: translate = 8'h13;  // R
          8'h2C: translate = 8'h14;  // T
          8'h35: translate = 8'h15;  // Y
          8'h3C: translate = 8'h16;  // U
          8'h43: translate = 8'h17;  // I
          8'h44: translate = 8'h18;  // O
          8'h4D: translate = 8'h19;  // P
          8'h54: translate = 8'h1A;  // @ / left bracket
          8'h5B: translate = 8'h1B;  // left bracket / right bracket
          8'h5A: translate = 8'h1C;  // Enter
          8'h1C: translate = 8'h1D;  // A
          8'h1B: translate = 8'h1E;  // S
          8'h23: translate = 8'h1F;  // D
          8'h2B: translate = 8'h20;  // F
          8'h34: translate = 8'h21;  // G
          8'h33: translate = 8'h22;  // H
          8'h3B: translate = 8'h23;  // J
          8'h42: translate = 8'h24;  // K
          8'h4B: translate = 8'h25;  // L
          8'h4C: translate = 8'h26;  // semicolon
          8'h52: translate = 8'h27;  // colon/quote
          8'h5D: translate = 8'h0D;  // yen: number-row key right of '='; its
          8'h6A: translate = 8'h0D;  // physical Yen (JIS) also maps to 0x0D
          8'h51: translate = 8'h33;  // RO (underscore/yen), left of right shift; NEC 0x33
          8'h61: translate = 8'h33;  // RO key (underscore/yen), left of right shift; NEC 0x33
          8'h7F: translate = 8'h61;  // raw PrintScreen (hps_io normalises it to E0 0x7C)
                                      // is the slot between slash and space, BIOS table 0xFF = special
                                     // BIOS translation (BANK7@0x632B[0x0D]) is
                                     // 0x5C '\', the DOS path separator
          8'h1A: translate = 8'h29;  // Z
          8'h22: translate = 8'h2A;  // X
          8'h21: translate = 8'h2B;  // C
          8'h2A: translate = 8'h2C;  // V
          8'h32: translate = 8'h2D;  // B
          8'h31: translate = 8'h2E;  // N
          8'h3A: translate = 8'h2F;  // M
          8'h41: translate = 8'h30;  // comma
          8'h49: translate = 8'h31;  // period
          8'h4A: translate = 8'h32;  // slash
          8'h29: translate = 8'h34;  // Space
          8'h14: translate = 8'h74;  // left Ctrl
          8'h11: translate = 8'h51;  // left Alt -> NFER (NP2kai kbtrans.c)
          8'h12, 8'h59: translate = 8'h70;  // both Shift keys -> NEC SHIFT. NP2kai's
          // default kbdtype folds RSHIFT 0x7D onto 0x70 (keystat.c keystat_down), and the
          // BIOS shift byte (0x53A bit 0) is written only for keys 0x70-0x74.
          8'h58: translate = 8'h71;  // Caps Lock
          8'h05: translate = 8'h62;  // F1 -> NEC F1 (NP2kai lrcnv106 F1->0x62); HELP is End
                                     // (0x69 -> 0x3F above) and the OSD bios_setup injector, so
                                     // the old F1->HELP remap made NEC F1 unreachable (M1)
          8'h06: translate = 8'h63;  // F2
          8'h04: translate = 8'h64;  // F3
          8'h0C: translate = 8'h65;  // F4
          8'h03: translate = 8'h66;  // F5
          8'h0B: translate = 8'h67;  // F6
          8'h83: translate = 8'h68;  // F7
          8'h0A: translate = 8'h69;  // F8
          8'h01: translate = 8'h6A;  // F9
          8'h09: translate = 8'h6B;  // F10
          // F11 (Set-2 0x78) maps to NOTHING. It used to answer 0x60 (STOP), so an
          // ordinary F11 press read as the STOP key - a phantom STOP make from a code
          // sitting one off the normalized Pause token's 0x77. NP2kai's host tables map
          // F11 to no PC-98 key at all (sdl/kbtrans.c lrcnv101/lrcnv106 carry
          // RETROK_F1..F10 and no RETROK_F11 row; wx/kbtrans.cpp:36 labels it "VF1" but
          // with that table's own inconsistent 0x73); qemu-pc98 hw/input/pc98-kbd.c:97
          // maps set-1 0x57 (F11) to 0x60 as physical correspondence - secondary, and
          // the evidence hierarchy puts NP2kai first. tb_pc9821_kbd_stop pins it silent.
          8'h07: translate = 8'h61;  // F12 -> SysRq/COPY (qemu set-1 0x58; the MiSTer
                                     // OSD key, which never reaches the core)
          8'h7B: translate = 8'h40;  // keypad minus
          8'h7C: translate = 8'h45;  // keypad multiply
          8'h79: translate = 8'h49;  // keypad plus
          8'h6C: translate = 8'h42;  // keypad 7
          8'h75: translate = 8'h43;  // keypad 8
          8'h7D: translate = 8'h44;  // keypad 9
          8'h6B: translate = 8'h46;  // keypad 4
          8'h73: translate = 8'h47;  // keypad 5
          8'h74: translate = 8'h48;  // keypad 6
          8'h69: translate = 8'h4A;  // keypad 1
          8'h72: translate = 8'h4B;  // keypad 2
          8'h7A: translate = 8'h4C;  // keypad 3
          8'h70: translate = 8'h4E;  // keypad 0
          8'h71: translate = 8'h50;  // keypad period
          default: translate = 8'hFF;
        endcase
      end
    end
  endfunction

  // NP2kai keystat.tbl kbexflag KBEX_NONREP (keystat.tbl:146-230) marks 0x52-0x56
  // (vf.1-vf.5), 0x62-0x6B (F1-F10), 0x70-0x74 (SHIFT/CAPS/KANA/GRPH/CTRL), 0x78
  // (RWIN), 0x79 (APP) and 0x7D (right Shift). Only the ones translate() can produce
  // are listed: 0x52-0x56 and 0x7D have no PS/2 source here (right Shift folds to
  // 0x70). 0x77 (left Win) is REPEATABLE in that table - the row above it ends at
  // 0x74 and the 0x78 row is RWIN/APP - so the old 0x77..0x79 range made LWIN stop
  // repeating where the reference repeats it.
  function automatic nonrep(input [7:0] code);
    begin
      nonrep = ((code >= 8'h62) && (code <= 8'h6B)) ||   // F1-F10
               ((code >= 8'h70) && (code <= 8'h74)) ||   // SHIFT/CAPS/KANA/GRPH/CTRL
               (code == 8'h78) || (code == 8'h79);       // RWIN/APP
    end
  endfunction

  // Direct PS/2 Set-2 -> NEC PC-98 physical-key translation table.
  // 512 entries stored in an MLAB ROM initialized from the translation function,
  // replacing the 150-arm case on the active event path.
  (* ramstyle = "MLAB" *) reg [7:0] kbd_lut [0:511];
  integer lut_i;
  initial begin
    for (lut_i = 0; lut_i < 512; lut_i = lut_i + 1) begin
      kbd_lut[lut_i] = translate(lut_i[8], lut_i[7:0]);
    end
  end
  // OR 0x85 (TXRDY, TXEMPTY, DSR).
  reg [7:0] status_reg;
  reg rts, rx_enabled, tx_enabled;
  reg [7:0] ctrl_writes;
  reg [7:0] rx_latch;
  // Whether the byte currently sitting unread in rx_latch was delivered by a
  // COMMAND RESPONSE (deliver_resp) rather than by the key FIFO. NP2kai's
  // keyboard_ctrl() clears its control queue (keybrd.ctrls = 0) whenever it queues
  // a leading FA/FC, so a new command response DISCARDS a pending, unread command
  // response; a key byte is not its queue and survives. This bit is what lets the
  // core tell the two apart when that clear is applied (see st_resp_clear below).
  reg       rx_is_resp;
  reg       cmd_bit3;   // bit 3 of the previous command write, for the reset edge

  // Key events and command responses are separate, matching NP2kai's control
  // response priority over normal keyboard traffic.
  reg [7:0] fifo[0:15];
  reg [3:0] fifo_head, fifo_tail;
  reg [4:0] fifo_cnt;
  reg [23:0] resp_shift;
  reg [1:0] resp_count;

  reg cmd_pending;
  reg [7:0] cmd_opcode;
  reg [3:0] lock_flags;
  // MEMORY TYPE: M10K, NOT MLAB - measured, not a preference. An MLAB is built from a
  // LAB's own ALMs and LABs are this device's BINDING resource (the fit has 88 of 553 M10K
  // blocks free and 4,163 of 4,191 LABs used), so the MLAB form spends the scarce one.
  // tools/res_exp_map.py, this module alone, one variable (MLAB -> M10K): ALMs needed
  // 294 -> 266, combinational ALUTs 420 -> 408, registers 280 -> 272, MLAB memory bits
  // 1,024 -> 0, +1 M10K block. Same values and cycles: both forms are a registered read.
  (* ramstyle = "M10K" *) reg [7:0] key_state [0:127];   // {generation, down} per NEC key number
  // Typematic repeat: the last repeatable key held (8'hFF = none), whether its
  // break+make pair is still being pushed, and the delay/interval countdown.
  reg [7:0]  rep_key;
  reg [1:0]  rep_pend;
  reg [25:0] rep_timer;
  // PENDING breaks owed for normalized Pause taps (0..3). Each tap make enqueues
  // its own break on the next idle cycle, so two makes landing before the first
  // break enqueues owe TWO breaks; a single bit would drop the second break and
  // leave its make unbroken (a stuck STOP-down reaching the guest). The host sends
  // one token per press, milliseconds apart, so this never exceeds 1 in practice -
  // the width is a guard, not a model of reachable backpressure.
  reg [1:0]  tap_brk;
  // The RE-POKE divider (see the irq assign below): free-running, so the re-strokes
  // are phase-deterministic and the first one after a delivery is at most one
  // transfer tick away.
  reg [25:0] xfer_div;
  integer k;
  // key_state's power-up state: stamp 0 under `key_epoch` 0 reads "not down" for every
  // entry. The RESET state is the epoch bump in the reset arms below.
  initial begin
    for (k = 0; k < 128; k = k + 1) key_state[k] = 8'b0;
  end
  /* verilator lint_off PROCASSINIT */   // the initialiser is the register's power-up value
  reg ps2_key_prev = 1'b0;
  reg rst_n_prev   = 1'b0;   // rst_n one clk ago: the module reset's leading edge, for the epoch bump
  /* verilator lint_on PROCASSINIT */

  // OSD "Enter BIOS setup (hold HELP)": the injected HELP hold. A physically held key
  // cannot do this -- the framework sends one edge per press and the ITF's POST re-inits
  // the 8251 with a bit-3 reset (BANK4@0x4BEA/0x4BF6) that discards anything latched
  // before its ~5 ms key poll (the 500 ms typematic repeat is far too late). The ITF
  // enters SETUP when its poll reads the raw key number 0x3F (BANK4@0x4C3F,
  // `cmp al,0x3f`). So the option HOLDS HELP itself: queue make 0x3F at the start,
  // RE-QUEUE a make on every guest keyboard reset (the held key survives the ITF's
  // re-init, exactly as NP2kai's keystat_resendstat re-announces a still-held key,
  // io/serial.c), and queue one break 0xBF after HELP_HOLD_CYCLES to release it.
  reg [29:0] help_hold;      // remaining hold-window cycles (0 = released); the width of HELP_HOLD_CYCLES, which is why the 120 MHz hold is the full 3 s
  reg        help_started;   // 1 after this hold's first make has been queued
  reg        help_pending;   // an injected byte is waiting for FIFO room
  reg        help_release;   // the pending byte is the final break (0xBF)
  wire [7:0] help_data = help_release ? 8'hBF : 8'h3F;
  // THE OPTION IS SAMPLED AT MACHINE RESET ONLY (owner requirement, lane dip-settings):
  // a mid-run OSD change must do NOTHING to the running machine - flipping it on used to
  // start a fresh hold immediately, injecting a held HELP into a running guest. The hold is
  // armed from the reset-time latch instead (the msw-cells pattern), so the new value
  // applies at the next machine reset / reload and nowhere else.
  /* verilator lint_off PROCASSINIT */   // the initialiser is the register's power-up value
  reg  bios_setup_eff = 1'b0;
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk) begin
    if (!rst_n) bios_setup_eff <= bios_setup;
  end
  wire help_active = bios_setup_eff && (help_hold != 30'd0);

  // THE TRANSLATION ROM'S READ IS REGISTERED, AND ITS READ REGISTER CARRIES NO POWER-UP VALUE.
  // Both halves are load-bearing and only together. The synchronous read is what lets the ROM
  // be block RAM at all; a POWER-UP VALUE ON THE REGISTER THAT CAPTURES IT puts the whole
  // 4,096-bit table back into combinational LUTs (225 combinational ALUTs, ~40 % of the
  // module) - Quartus 17.0.2 reports that as
  //   Info (276007): RAM logic "kbd_lut" is uninferred due to asynchronous read logic,
  // which names the symptom and not the cause. Measured with tools/res_exp_map.py (one
  // `quartus_map` of this module, ~1 min): taking this one value off the read register is
  // what makes the 512x8 ROM row appear; the `ramstyle` attribute (MLAB or M10K), the
  // initialised contents and the address cone change nothing. Review r2-resets F5 (9dc1214c)
  // added `event_code = 8'hFF;` here for 4-state determinism and silently cost the ROM, and
  // nothing in this tree can see it - Verilator is 2-state and no bench reads an inference -
  // so DO NOT give `rom_q` a power-up value. The "no event can fire before the first read
  // lands" property that value was added for is kept by `rom_valid` instead, applied on the
  // wire below rather than as a register power-up value.
  // A block-RAM read returns one clk later, so the WHOLE event path moves with it: `ps2_key_q`
  // carries the two ps2_key bits this logic reads (the toggling event bit and the pressed bit)
  // one clk earlier, i.e. describing the SAME ps2_key value the ROM's registered output does,
  // so `event_code` and every signal that qualifies it are aligned. hps_io holds ps2_key until
  // the next event and events are milliseconds apart, so the one extra clk is not observable;
  // the keyboard is not on any hot path.
  reg [7:0]  rom_q;                // the ROM's read register: NO power-up value (see above)
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg [1:0]  ps2_key_q = 2'b00;
  reg        rom_valid = 1'b0;     // 0 until the first ROM read has landed
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk) begin
    rom_q     <= kbd_lut[{ps2_key[8], ps2_key[7:0]}];
    rom_valid <= 1'b1;
    ps2_key_q <= ps2_key[10:9];
  end
  // Unmapped until the first read lands. This is the register power-up value the read
  // register must not carry, expressed as a one-clk guard instead.
  wire [7:0] event_code = rom_valid ? rom_q : 8'hFF;
  wire ps_event = (ps2_key_q[1] != ps2_key_prev);
  wire event_mapped = (event_code != 8'hFF);
  wire event_lock = (event_code == 8'h71) || (event_code == 8'h72);
  wire event_pressed = ps2_key_q[0];

  // ---- THE DEDUP TABLE'S READ IS CLOCKED, SO THE WHOLE DECISION MOVES ONE clk DEEPER --
  // `key_down[0:127]` (the M2 mechanical-lock fix) lives in `key_state`, a block memory,
  // and a block-RAM read returns one clk later - so the comparison "is this key already
  // down", and every signal derived from it, cannot happen in the clk the event code
  // arrives in. The event is carried one stage: `event_code`/`event_lock`/`event_pressed`
  // /`ps_event && event_mapped` are registered here as `ev2_*`, and the decision below is
  // taken from those plus the table's registered read. `ev2_valid` is what
  // `ps_event && event_mapped` used to be, one clk later.
  //
  // THAT ONE clk IS THE WHOLE T6 TRADE, approved by the owner on 2026-09-25: the keyboard
  // is not on any hot path, keys are milliseconds apart (hps_io holds ps2_key until the
  // next event, and the host's USB HID poll dominates by milliseconds), and the VALUES
  // and the ORDER of the guest-visible bytes are unchanged - only the cycle the decision
  // lands on. tb_pc9821_kbd_pipeline.sv pins the new depth (both this stage and the
  // translation ROM's, which stage 1 rides on) as a contract rather than a comment.
  reg [7:0] key_q;                 // the dedup table's read register: NO power-up value
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg [6:0] key_epoch = 7'd0;      // the generation tag the reset bumps (see the table below)
  /* verilator lint_on PROCASSINIT */
  reg [7:0] ev2_code;
  reg       ev2_lock;
  reg       ev2_pressed;
  reg       ev2_valid;
  // The dedup write that landed on the edge the current read was captured on, in DECODED
  // form: a block RAM hands back the OLD word of a same-address write, so this is how the
  // decision below sees it (see the bypass note at the table itself).
  reg [6:0] wq_addr;
  reg       wq_down;
  reg       wq_we;
  always @(posedge clk) begin
    ev2_code    <= event_code;
    ev2_lock    <= event_lock;
    ev2_pressed <= event_pressed;
    ev2_valid   <= ps_event && event_mapped;
  end

  // The decision itself, unchanged in shape - just reading the staged event and the
  // table's registered read (`key_q`) instead of the live event and a flop array.
  wire key_down_now = wq_we && (wq_addr == ev2_code[6:0]) ? wq_down :
                      (key_q[0] && (key_q[7:1] == key_epoch));   // entry live under THIS epoch
  wire normal_make = ev2_valid && !ev2_lock && ev2_pressed && !key_down_now;
  wire normal_break = ev2_valid && !ev2_lock && !ev2_pressed && key_down_now;
  wire lock_press = ev2_valid && ev2_lock && ev2_pressed &&
                    !key_down_now;   // M2: one toggle per PHYSICAL press
  wire event_valid = normal_make || normal_break || lock_press;
  wire [7:0] event_data = ev2_lock ?
      ((ev2_code == 8'h71) ?
       (lock_flags[2] ? (ev2_code | 8'h80) : ev2_code) :
       (lock_flags[3] ? (ev2_code | 8'h80) : ev2_code)) :
      (ev2_pressed ? ev2_code : (ev2_code | 8'h80));

  // NP2kai's keyboard_callback (io/serial.c) gates delivery on exactly one
  // condition -- the previously delivered byte has been read (its `status & 2`
  // check); it does not gate on the 8251 command bits at all. We additionally
  // required rx_enabled and !rts, and the PC-98 BIOS asserts RTS in its command
  // byte, so every keystroke was swallowed and the guest saw no keyboard.
  wire can_deliver = !status_reg[1];
  wire deliver_resp = can_deliver && (resp_count != 2'd0);
  wire deliver_key = can_deliver && (resp_count == 2'd0) && (fifo_cnt != 5'd0);
  // THE RECEIVE STATUS'S FOUR EFFECTS, as strobes for the ONE next-state fold below
  // (review r2-pulses H6 / review-keyboard F8): the data-read clear, the command's
  // error clear (bit 4 - both 0x3A and 0x32 carry it), the overflow flag (an event
  // that cannot enqueue because the FIFO is full) and the delivery set.
  wire st_read    = cs && rd && !a0;
  wire st_errclr  = cs && wr && a0 && !din[6] && din[4];
  wire st_overrun = !kbd_reset_now && event_valid && !enqueue_key;
  wire st_deliver = !kbd_reset_now && (deliver_resp || deliver_key);
  wire fifo_can_enqueue = (fifo_cnt < 5'd16) || deliver_key;
  wire event_enqueue = event_valid && fifo_can_enqueue;
  wire inject_enqueue = help_pending && fifo_can_enqueue && !event_valid;
  // THE hps_io-NORMALIZED PAUSE EVENT IS A TAP, NOT A HELD KEY. Its host stream carries
  // exactly ONE event: Main_MiSTer sends the raw PS/2 Pause make sequence
  // E1 14 77 E1 F0 14 F0 77 at key RELEASE (user_io.cpp send_keycode, `press != 1` -
  // "pause does not have a break code"), and sys/hps_io.sv:309 normalizes it to one
  // {pressed, extended, 0x77} token with NO Pause-release case. The make that token
  // translates to (0x60, STOP) could therefore never be broken: the key stayed down
  // and - STOP being typematic-repeatable (NP2kai keystat.tbl kbexflag row 0x60 is 0) -
  // the repeat engine re-emitted 0xE0/0x60 pairs forever, so any later keyboard poll
  // (Touhou 4 at startup) saw "the STOP key has been pressed". NP2kai's guest stream
  // for a Pause TAP is a make+break pair (sdl/kbtrans.c {RETROK_PAUSE, 0x60} feeds
  // keystat.c keystat_send: the make byte on the down event, code|0x80 on the up
  // event), so the tap queues its own break and is never marked down - one clean STOP
  // press per host event, with no stuck state and no typematic reachable from it.
  wire tap_event = (ev2_code == 8'h60);   // 0x60 has no other source in translate()
  wire tap_brk_set = normal_make && tap_event && event_enqueue;
  wire tap_enqueue = (tap_brk != 2'd0) && fifo_can_enqueue && !event_valid && !inject_enqueue;
  // The typematic pair outranks nothing: a real key event and the injected HELP both
  // win, so a held key can never displace a press.
  wire repeat_push = (rep_pend != 2'd0) && fifo_can_enqueue && !event_valid && !inject_enqueue && !tap_enqueue;
  wire [7:0] repeat_push_data = (rep_pend == 2'd2) ? (rep_key | 8'h80) : rep_key;
  wire enqueue_key = event_enqueue || inject_enqueue || tap_enqueue || repeat_push;
  wire [7:0] enqueue_data = event_enqueue ? event_data :
                            (inject_enqueue ? help_data :
                             (tap_enqueue ? (8'h60 | 8'h80) : repeat_push_data));

  // THE KEYBOARD RESET'S OWN CYCLE (the 8251 bit-3 1-to-0 transition). As a
  // wire it can give explicit priority in the folds below: the reset is one
  // event like any other (review r2-pulses H6, the Single-Cycle Event
  // Discipline), and every register it owns has ONE next-state per cycle,
  // `kbd_reset_now ? clear : normal_update`. The coincident deliver/enqueue is
  // discarded WITH the rest of what the receive side is holding - exactly what
  // NP2kai's keyboard_resetsignal() clears (keybrd.status, keybrd.ctrls,
  // keybrd.buffers).
  wire kbd_reset_now = cs && wr && a0 && !din[3] && cmd_bit3;
  // Every 8251 data write with TxEN loads a command response (every arm of the
  // write case below does), so this strobe marks the load for the delivery fold.
  wire resp_load = cs && wr && !a0 && tx_enabled;
  // THE COMMAND RESPONSE'S OWN CLEAR (NP2kai keyboard_ctrl(), io/serial.c): queuing a
  // leading FA/FC -- every command arm below does -- clears keybrd.ctrls, so a command
  // response REPLACES a pending, unread command response. That unread remainder is not
  // only resp_shift (already overwritten by the load); it is also the byte already
  // delivered into rx_latch, which is what the ITF's `0x00`-then-`0x9F` identity probe
  // (BANK4@0x1988/0x1992) must NOT see: with it kept, the guest reads the stale 0xFC,
  // re-sends 0x9F, and the re-loaded response duplicates its 0xFA, so the probe's
  // `cmp al,0xA0` fails and the stage-0x27 `or [0x481],0x40` never runs. A key byte
  // (rx_is_resp = 0) is untouched: it is the FIFO's, not the control queue's.
  wire st_resp_clear = resp_load && rx_is_resp;

  // ---- THE RESET CLEAR, HALF 1 OF 2: A GENERATION TAG -----------------------------------
  // One write port cannot clear 128 words in one clk, and a 128-clk sweep cannot be waited
  // for, so the reset does not clear the array - it BUMPS `key_epoch`, and every word
  // carries the tag it was written under. A word written before a reset then reads as
  // not-down WITHOUT the memory being touched, which is the same guest-visible state the
  // flop array had (every key up) in one clk. Both resets take it: the module reset (whose
  // level is edge-detected in the main block below) and the 8251 bit-3 keyboard reset. A key
  // that survives a reset is re-announced by its next make exactly as it was, because that
  // make reads a stale tag and delivers.
  //
  // ---- THE RESET CLEAR, HALF 2 OF 2: THE SWEEP THAT MAKES THE TAG EXACT -----------------
  // A tag WRAPS, and on the wrap a word stamped 2^7 bumps ago would read as live again -
  // i.e. a reset could revive the PRE-reset belief that a key is down, which is exactly the
  // belief review r2-resets F5.2 exists to clear. So the tag alone is not the scheme: the
  // SWEEP is the clear, and the tag only makes it immediate.
  // The sweep walks key_state[0..127] and writes {current tag, 0} to every word whose tag is
  // STALE. That write is IDEMPOTENT and observationally a NO-OP - a stale word already reads
  // as not-down, so the sweep only makes the clear PHYSICAL - which is why it can run in the
  // background without touching a guest-visible value. Everything is stale after a bump, so
  // a word is physically cleared within 128 of its key's idle cycles of the bump, while the
  // tag needs 2^7 = 128 bumps to return to any stamp - and >= 256 clk_sys even for a
  // back-to-back guest reset loop, since each reset is a 1-to-0 transition on 8251 bit 3,
  // which a port write can produce no faster than every other clk. No input the interface
  // can present can revive a pre-reset belief.
  // The sweep is READ-GATED: it issues its read only while the event path does not need the
  // port (ps_event low), so an event's stage-1 read is never disturbed; and it clears a word
  // only when nothing wrote it on either edge since that read (the wq_* bypass and the
  // ev2_kwe priority below), so it can never clobber a fresh write back to not-down.
  wire       ev2_kwe   = rst_n && !kbd_reset_now && ev2_valid &&
                         (!ev2_pressed || event_enqueue);
  // The tap key is never marked down: its break is queued with its make (above), so
  // the dedup table must read it as released - a later tap's make then delivers again.
  wire [7:0] ev2_kdata = {key_epoch, ev2_pressed && event_enqueue && !tap_event};
  wire [6:0] ev2_kaddr = ev2_code[6:0];
  // ...the sweep's own state: the next address to read, the address key_q holds, and
  // whether key_q is a sweep read at all (it is not, in the clk after any ps_event).
  // They are powered up so that 4-state sim has no X on the memory's read address or its
  // write enable from t=0: these are plain registers, so a power-up value is safe here (the
  // ban above is on the register that CAPTURES a memory read).
  /* verilator lint_off PROCASSINIT */
  reg [6:0] sw_cnt = 7'd0;
  reg [6:0] sw_addr_q = 7'd0;
  reg       sw_rd = 1'b0;
  /* verilator lint_on PROCASSINIT */
  wire       sw_owns  = !ps_event;                            // the event's stage-1 read wins
  wire [6:0] k_raddr  = sw_owns ? sw_cnt : event_code[6:0];
  wire       sw_clear = sw_rd && (key_q[7:1] != key_epoch) &&
                        !(wq_we && (wq_addr == sw_addr_q)) &&
                        !(ev2_kwe && (ev2_kaddr == sw_addr_q));
  always @(posedge clk) begin
    // ONE READ PORT AND ONE WRITE PORT, deliberately: a bypass mux ON the read (the other
    // way to handle a same-address read-during-write) makes Quartus REFUSE the RAM - Info
    // (276009) "key_state is uninferred due to unsupported read-during-write behavior" -
    // and puts all 128 words back into logic. The bypass is on the CONSUMER side, in wq_*:
    // the read is the table's OLD word, and the decision the event one clk later substitutes
    // the write that landed on the same edge.
    key_q <= key_state[k_raddr];
    if (ev2_kwe)       key_state[ev2_kaddr] <= ev2_kdata;
    else if (sw_clear) key_state[sw_addr_q] <= {key_epoch, 1'b0};
    // ...the write that landed on THIS edge, decoded, for the next decision and for the
    // sweep's clobber guard. One clk of history is enough: any older write is in the table.
    wq_addr <= ev2_kaddr;
    // The bypass's down bit must match the table's write (ev2_kdata above): the
    // tap's make is never marked down, so its bypass must read released too - a
    // stray wq_down=1 would make key_down_now believe STOP is held for one cycle
    // and swallow a second tap landing on that edge.
    wq_down <= ev2_pressed && event_enqueue && !tap_event;
    wq_we   <= ev2_kwe;
    // ...and the sweep's read issue and advance, only while it owns the port.
    sw_rd <= sw_owns;
    if (sw_owns) begin
      sw_addr_q <= sw_cnt;
      sw_cnt    <= sw_cnt + 7'd1;
    end
  end

  always @(posedge clk) begin
    // The PS/2 event edge detector tracks THROUGH reset (review r2-resets F5.1,
    // the L2 replay): `ps_event` is an EDGE of the hps_io toggle bit, and an
    // edge detector that stops tracking across reset sees a phantom edge on the
    // first cycle after release and replays the last (or X) key. Tracking is
    // unconditional, so a completed event held on ps2_key is consumed DURING the
    // reset - a fresh ps2_key[10] toggle after release is the only thing that
    // fires an event.
    ps2_key_prev <= ps2_key_q[1];
    rst_n_prev   <= rst_n;
    // The generation-tag bump: ONE increment per reset ASSERTION, which is why the module
    // reset (a level) is edge-detected here rather than folded into the `!rst_n` arm -
    // bumping every clk it is held would walk the epoch by the pulse's LENGTH, and it is
    // the count of bumps, not of clks, that the tag has to absorb. The 8251 bit-3 reset is
    // already a one-clk strobe, so it bumps directly. Both resets used to clear the dedup
    // array word by word; this is that clear, in one clk.
    if (rst_n && (!rst_n_prev || kbd_reset_now)) key_epoch <= key_epoch + 7'd1;
    if (!rst_n) begin
      status_reg   <= 8'd0;
      rts          <= 1'b1;
      rx_enabled   <= 1'b0;
      tx_enabled   <= 1'b0;
      rx_latch     <= 8'hFF;
      rx_is_resp   <= 1'b0;
      cmd_bit3     <= 1'b0;
      fifo_head    <= 4'd0;
      fifo_tail    <= 4'd0;
      fifo_cnt     <= 5'd0;
      resp_shift   <= 24'd0;
      resp_count   <= 2'd0;
      cmd_pending  <= 1'b0;
      cmd_opcode   <= 8'd0;
      lock_flags   <= 4'd0;
      xfer_div     <= 26'd0;
      rep_key      <= 8'hFF;
      rep_pend     <= 2'd0;
      rep_timer    <= 26'd0;
      tap_brk      <= 2'd0;
      // The key state and the 8251 sequence telemetry are reset state too
      // (review r2-resets F5.2/F5.3/F5.4): the dedup state kept across a reset swallowed
      // the first make of every key that was down before it (the epoch bump above is what
      // clears it now), and `ctrl_writes` X-locked the dbg_ctrl0/1 latches in 4-state sim.
      ctrl_writes  <= 8'd0;
      dbg_events   <= 8'd0;
      dbg_delivered<= 8'd0;
      dbg_rd_data  <= 8'd0;
      dbg_wr_ctrl  <= 8'd0;
      dbg_last_del <= 8'd0;
      dbg_ctrl0    <= 8'd0;
      dbg_ctrl1    <= 8'd0;
    end else begin

      // Data reads clear RXRDY - and with it the IRQ line, which is RXRDY's own
      // level (the assign at the bottom). Both land in status_reg's ONE next-state
      // fold near the queue below; delivery has priority if a new byte becomes
      // available on the same edge, avoiding a lost receive byte.

      // 8251 mode/command state.
      if (cs && wr && a0) begin
        if (ctrl_writes == 8'd0)      dbg_ctrl0 <= din;
        else if (ctrl_writes == 8'd1) dbg_ctrl1 <= din;
        if (ctrl_writes != 8'hFF) ctrl_writes <= ctrl_writes + 8'd1;
        // 0x43 is always the command register. The 8251 has no positional
        // state here: NP2kai's keyboard_o43 stores every write (io/serial.c:55-66)
        // and the only "mode register" path is a write to 0x41 while TxEN is
        // clear (serial.c:45). Our value-classified cfg_phase machine consumed
        // phases without storing anything, so a control sequence could be
        // swallowed -- writing 0x40, 0x5E, 0x05 left TxEN clear, whereas NP2kai
        // ends with cmd = 0x05. Removed, along with the phase register.
        if (din[6]) begin
          rts        <= 1'b1;
          rx_enabled <= 1'b0;
          tx_enabled <= 1'b0;
        end else begin
          // The error clear (bit 4) lands in status_reg's ONE next-state fold near
          // the queue below, where the keyboard reset wins as the priority
          // expression - not because of where any NBA sits.
          rts        <= din[5];
          rx_enabled <= din[2];
          tx_enabled <= din[0];
        end

        // THE KEYBOARD RESET. Bit 3's 1-to-0 transition discards everything the
        // receive side is holding, which is what NP2kai's keyboard_o43 does by calling
        // keyboard_resetsignal() (io/serial.c): it clears keybrd.cmd, keybrd.status and
        // BOTH byte queues, the control responses and the keys.
        //
        // The ITF performs exactly that transition in its POST init sequence:
        // BANK4@0x04BEA writes 0x3A and BANK4@0x04BF6 writes 0x32, differing in bit 3
        // ALONE, and the same pair appears at BANK4@0x04BDF/0x06709, BANK7@0x067B5 and
        // BIOS.ROM@0x167B5. On a plain 8251 bit 3 is SBRK, which is meaningless to a
        // keyboard controller, so NP2kai's reading of it as a keyboard reset is what
        // makes the firmware's pulse meaningful.
        //
        // FOLDED, not positioned: every receive-side register this touches has
        // its single next-state (status_reg's and the IRQ line's is the fold's
        // reset arm near the queue below) in this arm or in that fold, with the
        // reset winning over the same-cycle deliver/enqueue arms by their
        // `!kbd_reset_now` guards, review r2-pulses H6. It does NOT touch
        // rts/rx_enabled/tx_enabled: NP2kai assigns keybrd.cmd = dat AFTER the reset, so
        // the new command byte's enables survive and only the receive-side record goes.
        if (kbd_reset_now) begin
          resp_shift <= 24'd0;
          resp_count <= 2'd0;
          rx_is_resp <= 1'b0;
          fifo_head  <= 4'd0;
          fifo_tail  <= 4'd0;
          fifo_cnt   <= 5'd0;
          // ...and the half-written keyboard command, which is the part easiest to
          // forget. NP2kai's keyboard_resetsignal() calls keystat_ctrlreset(), whose
          // first act is `keyctrl.reqparam = 0` -- so a reset abandons a command that
          // was waiting for its parameter. Without this, cmd_pending survives the
          // reset and the NEXT command byte is eaten as the parameter of the stale
          // opcode instead of being decoded: the guest gets the wrong response, or
          // none, and the command it meant to send is never carried out. The ITF
          // writes this exact pair during POST (BANK4@0x04BEA/0x04BF6), so the state
          // can be stale on real firmware and not only in a bench.
          cmd_pending <= 1'b0;
          cmd_opcode  <= 8'd0;
          // ...and the key state (review r2-resets F5.2): a key held across the
          // reset must not swallow its next make as a "re-send of a held key".
          // NP2kai resets the whole record (keyboard_resetsignal ->
          // keystat_ctrlreset) and re-announces what is still held
          // (keystat_resendstat); this model clears the state instead, so the
          // next make of a physically-held key simply delivers. The typematic
          // state goes with it (keystat_resendstat drops its keyrepeat buffer):
          // a cleared key_down must not leave a repeat of a key that is no
          // longer down. THE CLEAR IS THE EPOCH BUMP at the top of this block:
          // the 8251 bit-3 reset is one of the two reset events that bump it.
          rep_key   <= 8'hFF;
          rep_pend  <= 2'd0;
          rep_timer <= 26'd0;
        end
        cmd_bit3 <= din[3];
      end

      // Keyboard-side command protocol. NP2kai recognizes 9C/9D/9F; 95/96
      // are enabled for newer keyboards. QEMU's 99 response is harmless and
      // useful to firmware that probes it.
      if (cs && wr && !a0 && tx_enabled) begin
        if (cmd_pending) begin
          cmd_pending <= 1'b0;
          case (cmd_opcode)
            8'h95: begin
              resp_shift <= {16'd0, 8'hFA};
              resp_count <= 2'd1;
            end
            8'h9C: begin
              resp_shift <= {16'd0, 8'hFA};
              resp_count <= 2'd1;
            end
            8'h9D: begin
              if (din == 8'h60) begin
                resp_shift <= {8'd0, (8'h70 | {4'd0, lock_flags}), 8'hFA};
                resp_count <= 2'd2;
              end else if (din[7:4] == 4'h7) begin
                lock_flags <= din[3:0] & (LOCK_NUM | LOCK_CAPS | LOCK_KANA);
                resp_shift <= {16'd0, 8'hFA};
                resp_count <= 2'd1;
              end else begin
                resp_shift <= {16'd0, 8'hFC};
                resp_count <= 2'd1;
              end
            end
            default: begin
              resp_shift <= {16'd0, 8'hFC};
              resp_count <= 2'd1;
            end
          endcase
        end else begin
          case (din)
            8'h95, 8'h9C, 8'h9D: begin
              cmd_opcode  <= din;
              cmd_pending <= 1'b1;
              resp_shift  <= {16'd0, 8'hFA};
              resp_count  <= 2'd1;
            end
            8'h96: begin
              // Keyboard ID: NP2kai keystat_ctrlsend answers FA A0 83; the 0x85 was
              // QEMU's byte and the primary reference is NP2kai.
              resp_shift <= {8'h83, 8'hA0, 8'hFA};
              resp_count <= 2'd3;
            end
            8'h99: begin
              resp_shift <= {8'd0, 8'hFB, 8'hFA};
              resp_count <= 2'd2;
            end
            8'h9F: begin
              resp_shift <= {8'h80, 8'hA0, 8'hFA};
              resp_count <= 2'd3;
            end
            default: begin
              resp_shift <= {16'd0, 8'hFC};
              resp_count <= 2'd1;
            end
          endcase
        end
      end

      // Typematic auto-repeat (NP2kai keystat.c keyrepeat_proc): a held repeatable key
      // re-emits break+make after REPEAT_DELAY, then every REPEAT_INTERVAL, until its own
      // break arrives. break-then-make is what NP2kai's two keyboard_send() calls produce.
      // Placed before the key-state block so a break in the same cycle wins the race.
      // Folded under the keyboard reset: its arm clears rep_* (below), and a
      // same-cycle push must not resurrect any of it (review r2-pulses H6).
      if (!kbd_reset_now && rep_key != 8'hFF) begin
        if (rep_pend == 2'd0) begin
          if (rep_timer != 26'd0) rep_timer <= rep_timer - 26'd1;
          else begin
            rep_pend  <= 2'd2;
            rep_timer <= REPEAT_INTERVAL;
          end
        end else if (repeat_push) begin
          rep_pend <= rep_pend - 2'd1;
        end
      end

        // The M2 mechanical-lock dedup and the typematic/lock bookkeeping it gates, one
        // pipeline stage behind the event that caused them: `key_down_now` and the words
        // of `key_state` are written by the table's own always block above, and this arm
        // keeps the records that hang off the decision (the lock toggle and the repeat
        // timer). Folded under the keyboard reset (review r2-resets F5/H6): the reset
        // bumps the epoch, and a decision landing in its cycle is discarded WITH the
        // enqueue next to it, so the two can never disagree. M2 mechanical-lock dedup
        // (NP2kai keystat.c one alternating byte per PHYSICAL press): the table gates the
        // press exactly as it gates a normal make and clears on the release, so a
        // duplicate make -- a USB re-enumeration re-delivery, a resync/replay, or
        // Menu->KANA typematic -- re-neither re-toggles the lock nor emits a spurious
        // lock byte.
        if (!kbd_reset_now && ev2_valid) begin
          if (ev2_lock) begin
            if (ev2_pressed) begin
              if (event_enqueue) begin
                if (ev2_code == 8'h71) lock_flags <= lock_flags ^ LOCK_CAPS;
                else lock_flags <= lock_flags ^ LOCK_KANA;
              end
            end
          end else begin
          if (ev2_pressed && event_enqueue && !tap_event) begin
            if (!nonrep(ev2_code)) begin
              rep_key   <= ev2_code;
              rep_timer <= REPEAT_DELAY;
              rep_pend  <= 2'd0;
            end
          end else if (!ev2_pressed) begin
            if (ev2_code == rep_key) begin
              rep_key  <= 8'hFF;
              rep_pend <= 2'd0;
            end
          end
        end
      end

      // The queue's single next-state per cycle (review r2-pulses H6): under the
      // keyboard reset NOTHING on the receive side moves - the reset arm owns
      // the indices and the count, and the pre-reset enqueue/deliver are dropped
      // with the rest of the record instead of resurrecting head+1/tail+1 and a
      // delivered stale byte.
      if (!kbd_reset_now) begin
        if (enqueue_key) begin
          fifo[fifo_head] <= enqueue_data;
          fifo_head <= fifo_head + 4'd1;
        end
        // (an event that cannot enqueue - a full FIFO - sets the overrun flag in
        // status_reg's fold below, as st_overrun.)
        if (deliver_key) fifo_tail <= fifo_tail + 4'd1;

        case ({
          enqueue_key, deliver_key
        })
          2'b10:   fifo_cnt <= fifo_cnt + 5'd1;
          2'b01:   fifo_cnt <= fifo_cnt - 5'd1;
          default: ;  // simultaneous enqueue/dequeue leaves count unchanged
        endcase
      end

      // The Pause tap's queued break: ONE next-state per cycle (review r2-pulses H6).
      // A keyboard reset drops it WITH the make it belongs to - both were in the queue
      // the reset just flushed, so the orphan break must not outlive it.
      // The tap break count: reset drops every owed break with the makes it belongs
      // to (the FIFO the reset just flushed held them), an enqueue consumes one, and a
      // make owes one. Enqueue and make-set cannot coincide (tap_enqueue needs
      // !event_valid; tap_brk_set needs normal_make), so the order is a priority, not
      // a same-cycle race.
      if (kbd_reset_now)    tap_brk <= 2'd0;
      else if (tap_enqueue) tap_brk <= tap_brk - 2'd1;
      else if (tap_brk_set) tap_brk <= tap_brk + 2'd1;

      // The telemetry counts only what survives the fold (the bus-access counts
      // are unconditional: the reset write IS a control write).
      if (!kbd_reset_now && ev2_valid)                               dbg_events    <= dbg_events + 8'd1;
      if (!kbd_reset_now && (deliver_key || deliver_resp))           dbg_delivered <= dbg_delivered + 8'd1;
      if (cs && rd && !a0)                         dbg_rd_data   <= dbg_rd_data + 8'd1;
      if (cs && wr && a0)                          dbg_wr_ctrl   <= dbg_wr_ctrl + 8'd1;

      // Control responses have priority over normal key traffic, as in NP2kai.
      // DEFER-NOT-LOSE (review r2-pulses H9): a command response loaded in this
      // exact clk must keep the NEW response. The in-flight byte still reaches
      // the guest (deliver-first, the order NP2kai's serial callback gives: the
      // byte already in keybrd.data when the write lands), and the deliver's
      // shift/decrement bookkeeping DEFERS to the load. A response arriving
      // mid-response replaces the unread remainder exactly as NP2kai does it:
      // keystat_ctrlsend -> keyboard_ctrl() clears keybrd.ctrls on the leading
      // FA/FC before queueing the new bytes (io/serial.c).
      if (!kbd_reset_now && st_resp_clear) begin
        // The command response loaded in this clk replaces the unread one: discard the
        // delivered control byte with the remainder (NP2kai keybrd.ctrls = 0). The new
        // response delivers on the next clk, when status_reg[1] is clear again.
        rx_latch   <= 8'hFF;
        rx_is_resp <= 1'b0;
      end else if (!kbd_reset_now && deliver_resp) begin
        dbg_last_del <= resp_shift[7:0];
        rx_latch   <= resp_shift[7:0];
        rx_is_resp <= 1'b1;
        if (!resp_load) begin
          resp_shift <= {8'd0, resp_shift[23:8]};
          resp_count <= resp_count - 2'd1;
        end
      end else if (!kbd_reset_now && deliver_key) begin
        dbg_last_del <= fifo[fifo_tail];
        rx_latch   <= fifo[fifo_tail];
        rx_is_resp <= 1'b0;
      end else if (!kbd_reset_now && st_read) begin
        // The byte was consumed: it is no longer an unread remainder.
        rx_is_resp <= 1'b0;
      end

      // THE RECEIVE STATUS'S ONE NEXT-STATE (review r2-pulses H6 / review-keyboard F8).
      // The data-read clear, the error clear, the overflow flag and the delivery set
      // are folded into ONE expression, so no same-clk pair can resurrect or drop
      // another's bit. The old last-wins chain had three broken collisions: a same-clk
      // data read + overflow RESURRECTED RXRDY from the pre-read value (so the guest's
      // next 0x41 read returned the ALREADY-read rx_latch as a duplicate key byte), a
      // same-clk error-clear + overflow lost the 0x38 clear, and a same-clk overflow +
      // deliver lost the overrun flag. Priority in the fold: the keyboard reset clears
      // everything; a delivery WINS the RXRDY bit over the coincident read (deliver-
      // first, the order NP2kai's serialized callback gives - a byte landing on a read
      // edge must not be lost); the overrun flag and the error clear are independent
      // bits and both land.
      status_reg <= kbd_reset_now ? 8'd0 :
                    ((status_reg & ~(st_read       ? KST_RXRDY : 8'h00)
                                 & ~(st_resp_clear ? KST_RXRDY : 8'h00)
                                 & ~(st_errclr ? (KST_PARITY | KST_OVERRUN | KST_FRAMING) : 8'h00))
                     | (st_overrun ? KST_OVERRUN : 8'h00)
                     | (st_deliver ? KST_RXRDY : 8'h00));

      // The RE-POKE divider: RESTARTED by every request rise (a delivery -
      // st_deliver is the cycle the rise lands in), so the first re-stroke of a
      // fresh byte is one FULL transfer tick after the request it could re-fire.
      // A normal service's [dispatch, read] window is inside that first tick and
      // therefore contains no dip at all: with the free-running divider the
      // dip's recovery edge could land between the acknowledge and the handler's
      // 0x41 read, re-arm the edge-latched PIC, and survive the read - after EOI
      // IRQ1 fired again and the handler (which reads 0x41 WITHOUT checking
      // RXRDY) re-processed the stale byte as a second keypress
      // (the owner's double-typing). The dip's own recovery does not restart the
      // divider: the wrap is already one tick away from it.
      xfer_div <= st_deliver ? 26'd1 :
                  (xfer_div == XFER_TICK_CYCLES - 26'd1) ? 26'd0 : xfer_div + 26'd1;
    end
  end

  // The injected-HELP generator: re-armed whenever the option is off or the block is
  // reset, so a core reset with the option on starts a fresh hold. The option itself is
  // the reset-latched bios_setup_eff above, so a mid-run OSD flip neither starts nor
  // releases a hold.
  always @(posedge clk) begin
    if (!rst_n || !bios_setup_eff) begin
      help_hold    <= HELP_HOLD_CYCLES;
      help_started <= 1'b0;
      help_pending <= 1'b0;
      help_release <= 1'b0;
    end else begin
      // The hold's first make, and the make re-announced after each guest keyboard
      // reset (the reset flushed the receive side, so the held key is offered again).
      if (!help_started || (help_active && kbd_reset_now)) help_pending <= 1'b1;

      if (help_pending) begin
        if (inject_enqueue) help_pending <= 1'b0;
      end

      // Count the hold window down; at its end queue the one break that releases HELP.
      if (help_hold == 30'd1) begin
        help_release <= 1'b1;
        help_pending <= 1'b1;
        help_hold    <= 30'd0;
      end else if (help_hold != 30'd0) begin
        help_hold <= help_hold - 30'd1;
      end

      help_started <= 1'b1;
    end
  end

  // THE IRQ LINE IS THE REQUEST HELD HIGH - WITH THE NP2kai RE-POKE. While a delivered
  // byte waits unread the line holds (RXRDY's own level: qemu pc98-kbd.c:470 raises it
  // from KST_RXRDY exactly, and tb_pc9821_kbd_reset pins the hold), but once per
  // transfer tick it dips for one clk, so the request arrives as a fresh rising edge.
  // The consumer is the edge-latched PIC (pc9821_pic.sv: "set on a rising edge of IR,
  // held until INTA clears the serviced bit. A still-held level does NOT re-set after
  // INTA (no new edge)"), and NP2kai re-pokes pic_setirq(1) at EVERY keyboard transfer
  // tick while the receive side is not empty (io/serial.c keyboard_callback) - so an
  // acknowledge that is not followed by a 0x41 read is RE-REQUESTED at the next tick,
  // instead of the byte sitting forever with no interrupt (the dispatched-but-never-
  // read wedge the EMM386 trace's unread byte shows). The read clears RXRDY and with
  // it the line and the re-strokes (io/serial.c keyboard_i41: status &= ~2, and
  // pic_resetirq(1) is the same withdrawal here, since the line IS the request).
  //
  // st_read is the ATOMIC CANCEL of the dip (the double-type fix): the read's status
  // clear only lands the cycle AFTER its strobe is sampled, so a dip whose RECOVERY
  // edge fell in the strobe's own cycle would still rise (status_reg[1] not yet
  // cleared) and arm the PIC for a byte being consumed right there. Forcing the line
  // low while the strobe is up cancels that recovery edge with the clear itself - no
  // dip may land after (or across) a read that clears RXRDY.
  assign irq = status_reg[1] && !st_read && (xfer_div != 26'd0);
  assign dout     = a0 ? (status_reg | 8'h85) : rx_latch;
  assign dbg_rts  = rts;
  assign dbg_rx_en = rx_enabled;
  // Host keyboard LEDs, in hps_io's {scrolllock, numlock, capslock} order, from the lock
  // state on every change (NP2kai reloadled()). KANA has no host lamp and takes
  // scrolllock; NUM takes numlock and CAPS takes capslock.
  assign led_status = {lock_flags[3], lock_flags[0], lock_flags[2]};

endmodule

`default_nettype wire

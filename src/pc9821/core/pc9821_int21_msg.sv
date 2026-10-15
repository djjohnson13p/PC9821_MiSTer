// The INT-21h telemetry record: ONE completed call is TWO lines, the entry and the return, and
// the two together are the §1.4 wire format this module is the formatter for:

//   21 IN  AH=48 BX=5208 CS=xxxx IP=xxxx
//   21 OUT AH=48 CY=c AX=0008 BX=xxxx

// THE LAYOUT IS A CONTRACT with tools/decode_telemetry.py and tools/check_telemetry_contract.py:
// the IN line is a 6-byte prefix ("21 IN "), four fields (a SPACE, a 2-char label, '=', 2 or 4
// hex digits), then ONE LF - 37 bytes. The OUT line is a 6-byte prefix ("21 OUT"), four fields
// (CY is ONE digit), then ONE LF - 34 bytes. 71 bytes in all, no CR anywhere. NOTE the OUT line's
// AH is the FUNCTION number, carried from the entry snapshot - the return AX register is its own
// field (AX=0008 insufficient / AX=0007 arena trashed, whose high byte DOS clobbers to 00), so the
// two are separate fields on purpose and the OUT line is self-describing.

// WHY THIS MODULE HAS A CAPTURE FSM, not just a formatter. The two lines are not a report the
// watchdog trigger can snapshot: they are a MATCHED PAIR produced by one call, and the fields
// that separate them live on two sides of that call. The entry half (AH/BX/CS/IP) is latched at
// the trigger - the vectoring read of IVT slot 0x21 - and the return half (AX/BX/CF) is latched
// when the CPU is back at the caller's CS:EIP, which is the `iret`'s arrival; the OUT line's AH
// is the FUNCTION number, carried from the entry snapshot. dbg_EAX/dbg_EBX/dbg_CF are the z486
// vector-fetch telemetry exports (real since the 4c8ebc3 re-vendor wired them), so AH reads the
// live function number and the AH filter (48h/49h/4Ah) gates the capture.

// THE TRIGGER IS the z486 vector-fetch pulse (pc9821_system.sv's int21_vec_fetch =
// cpu_dbg_vec_fetch && cpu_dbg_vec_num == 8'h21): the BUSOP_RD_IND gate read of IVT slot 0x21,
// exactly the cycle the soft-INT vectoring read is accepted. The return match uses the
// already-exported dbg_CS/dbg_EIP. One open detail for the bench to pin: whether EIP at the gate
// read already carries the pushed return IP, or the `int` instruction's own address (+2 for INT
// imm8) - the module latches cpu_eip at that cycle and matches it on the iret arrival, so this
// is what decides whether the OUT line's return match fires.

`default_nettype none

module pc9821_int21_msg (
    input  wire        clk,
    input  wire        reset,
    input  wire        vec_fetch,     // one-cycle: the z486 vector-fetch pulse at IVT/IDT slot 0x21
    /* verilator lint_off UNUSEDSIGNAL */   // the record's fields are 16-bit; the full upstream EAX/EBX width is carried
    input  wire [31:0] dbg_EAX,       // <- z486 dbg_EAX (AH = the function number at the gate read)
    input  wire [31:0] dbg_EBX,       // <- z486 dbg_EBX (BX at the gate read)
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        dbg_CF,        // <- z486 dbg_CF (EFLAGS[0] at the return)
    input  wire [15:0] cpu_cs,        // dbg_CS (already exported)
    input  wire [31:0] cpu_eip,       // dbg_EIP (already exported)
    input  wire  [7:0] idx,           // 0..INT21_MSG_LEN-1, or past the record for NUL
    input  wire        ack,           // one-cycle: the sequencer took this pending record
    input  wire        emitting,      // the sequencer is emitting it now (protects the snapshot)
    output reg   [7:0] ch,
    output reg         pending,       // a completed IN/OUT pair is latched and not yet consumed
    output reg   [7:0] drops,         // completed pairs lost to the single-entry pending slot
    // One-cycle: a captured return carried a DOS ARENA error - CF=1 with AX=0007h (memory
    // control blocks destroyed) or 0009h (invalid memory block address), RBIL INT 21h/48h-4Ah.
    // It is the instruction ring's freeze trigger (pc9821_trace `trig`): the OP.EXE capture
    // (docs/probes/int21-mister-2026-09-30) returns AX=0007 from a C0 startup shrink that
    // runs twice in place, and the ring then holds the transfer into it.
    output reg         arena_err
);

    localparam [7:0] INT21_MSG_LEN = 8'd71;   // 37-byte IN line + 34-byte OUT line
    localparam [7:0] INT21_IN_LEN  = 8'd37;
    localparam [7:0] INT21_OUT_LEN = 8'd34;

    // The §1.4 filter: only the OOM family the task captures (AH=48h allocate, 49h free,
    // 4Ah resize). §1.4's row context also names 52h/58h; they are one localparam list away and
    // are deliberately NOT captured so the record is exactly the game's calls.
    wire ah_hit = (dbg_EAX[15:8] == 8'h48) ||
                  (dbg_EAX[15:8] == 8'h49) ||
                  (dbg_EAX[15:8] == 8'h4A);
    wire trigger = vec_fetch && ah_hit;

    // The capture FSM and its snapshot. The snapshot is NOT reset on ack: it stays until the next
    // entry latches, so the record being emitted reads one instant however long the paced emission
    // waits. `emitting` (pc9821_dbg_record's int21_active) stops a new trigger from overwriting
    // that snapshot mid-emission; the overwritten call would be a torn record, so it is counted
    // in `drops` instead.
    localparam [1:0] S_IDLE    = 2'd0;
    localparam [1:0] S_ARMED   = 2'd1;
    localparam [1:0] S_PENDING = 2'd2;
    reg [1:0]  state;
    reg  [7:0] in_ah_q;
    reg [15:0] in_bx_q;
    reg [15:0] in_cs_q;
    reg [31:0] in_eip_q;
    reg        left;         // the CPU has been AWAY from (in_cs_q, in_eip_q) since the arm
    reg [15:0] out_ax_q;
    reg [15:0] out_bx_q;
    reg        out_cf_q;

    always @(posedge clk) begin
        if (reset) begin
            state    <= S_IDLE;
            pending  <= 1'b0;
            drops    <= 8'd0;
            in_ah_q  <= 8'd0;  in_bx_q <= 16'd0; in_cs_q <= 16'd0; in_eip_q <= 32'd0;
            left     <= 1'b0;
            out_ax_q <= 16'd0; out_bx_q <= 16'd0; out_cf_q <= 1'b0;
            arena_err <= 1'b0;
        end else begin
            arena_err <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (trigger) begin
                        if (emitting) begin
                            // A new call arrived while the previous record is still on the wire:
                            // its entry is lost and counted, never silently.
                            if (drops != 8'hFF) drops <= drops + 8'd1;
                        end else begin
                            in_ah_q  <= dbg_EAX[15:8];
                            in_bx_q  <= dbg_EBX[15:0];
                            in_cs_q  <= cpu_cs;
                            in_eip_q <= cpu_eip;
                            left     <= 1'b0;
                            state    <= S_ARMED;
                        end
                    end
                end
                S_ARMED: begin
                    if (trigger) begin
                        // A nested INT 21h while armed re-arms on the inner call; the outer pair
                        // is lost and counted.
                        in_ah_q  <= dbg_EAX[15:8];
                        in_bx_q  <= dbg_EBX[15:0];
                        in_cs_q  <= cpu_cs;
                        in_eip_q <= cpu_eip;
                        left     <= 1'b0;
                        if (drops != 8'hFF) drops <= drops + 8'd1;
                    end else begin
                        // The return match must NOT fire in the first cycle after arming: in_eip_q
                        // is the fetch EIP captured at the vectoring (already EIP+2, the return
                        // address), so cpu_eip still equals it until the CPU has actually jumped
                        // into the DOS handler. Latch that the CPU has LEFT the caller, then only
                        // capture the return half once it has been away and is back again.
                        if ((cpu_cs != in_cs_q) || (cpu_eip != in_eip_q))
                            left <= 1'b1;
                        if (left && (cpu_cs == in_cs_q) && (cpu_eip == in_eip_q)) begin
                            out_ax_q <= dbg_EAX[15:0];
                            out_bx_q <= dbg_EBX[15:0];
                            out_cf_q <= dbg_CF;
                            arena_err <= dbg_CF && ((dbg_EAX[15:0] == 16'h0007) ||
                                                    (dbg_EAX[15:0] == 16'h0009));
                            pending  <= 1'b1;
                            state    <= S_PENDING;
                        end
                    end
                end
                S_PENDING: begin
                    if (trigger) begin
                        // A second call completed while the first is still queued: its entry is
                        // lost and counted. The record format is fixed (§1.4 has no DN field), so
                        // the count travels on this port, not in the line.
                        if (drops != 8'hFF) drops <= drops + 8'd1;
                    end
                    if (ack) begin
                        pending <= 1'b0;
                        state   <= S_IDLE;
                    end
                end
                default: begin
                    // The 2-bit state has no fourth encoding; recover to IDLE rather than leaving
                    // the case uncovered (Verilator's CASEINCOMPLETE).
                    state <= S_IDLE;
                end
            endcase
        end
    end

    /* verilator lint_off WIDTHEXPAND */   // a 4-bit nibble is zero-extended to add an ASCII base
    function [7:0] int21_hc(input [3:0] n);
        int21_hc = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction
    /* verilator lint_on WIDTHEXPAND */

    // The 2-char label of each field, as two bytes. These are the ONE place a field's name lives
    // on the RTL side; the decoder's INT21_FIELDS / INT21_OUT_FIELDS tables must name them in the
    // same order, and tools/check_telemetry_contract.py holds the two together. `p == 1` is the
    // label's first character and `p == 0` its second.
    function [7:0] int21_in_label(input [1:0] f, input [1:0] p);
        reg [15:0] l;
        begin
            l = (f == 2'd0) ? "AH" :
                (f == 2'd1) ? "BX" :
                (f == 2'd2) ? "CS" : "IP";
            int21_in_label = (p == 2'd1) ? l[15:8] : l[7:0];
        end
    endfunction

    function [7:0] int21_out_label(input [1:0] f, input [1:0] p);
        reg [15:0] l;
        begin
            l = (f == 2'd0) ? "AH" :
                (f == 2'd1) ? "CY" :
                (f == 2'd2) ? "AX" : "BX";
            int21_out_label = (p == 2'd1) ? l[15:8] : l[7:0];
        end
    endfunction

    // The record, byte for byte. The two lines have different prefixes and different field
    // widths, so the layout is written as two explicit case blocks rather than the uniform
    // field/pos arithmetic the uniform perf/gfx records use. Every literal byte is named; the
    // digits read the SNAPSHOT latched by the FSM above, so a paced emission cannot splice two
    // values into one field.
    always @* begin
        if (idx >= INT21_MSG_LEN) begin
            ch = 8'h00;                       // past the record: NUL, as the watchdog's own default
        end else if (idx < INT21_IN_LEN) begin
            // "21 IN  AH=.. BX=.... CS=.... IP=....\n"  (37 bytes)
            case (idx)
                8'd0:  ch = "2";
                8'd1:  ch = "1";
                8'd2:  ch = " ";
                8'd3:  ch = "I";
                8'd4:  ch = "N";
                8'd5:  ch = " ";
                8'd6:  ch = " ";
                8'd7:  ch = int21_in_label(2'd0, 2'd1);
                8'd8:  ch = int21_in_label(2'd0, 2'd0);
                8'd9:  ch = "=";
                8'd10: ch = int21_hc(in_ah_q[7:4]);
                8'd11: ch = int21_hc(in_ah_q[3:0]);
                8'd12: ch = " ";
                8'd13: ch = int21_in_label(2'd1, 2'd1);
                8'd14: ch = int21_in_label(2'd1, 2'd0);
                8'd15: ch = "=";
                8'd16: ch = int21_hc(in_bx_q[15:12]);
                8'd17: ch = int21_hc(in_bx_q[11:8]);
                8'd18: ch = int21_hc(in_bx_q[7:4]);
                8'd19: ch = int21_hc(in_bx_q[3:0]);
                8'd20: ch = " ";
                8'd21: ch = int21_in_label(2'd2, 2'd1);
                8'd22: ch = int21_in_label(2'd2, 2'd0);
                8'd23: ch = "=";
                8'd24: ch = int21_hc(in_cs_q[15:12]);
                8'd25: ch = int21_hc(in_cs_q[11:8]);
                8'd26: ch = int21_hc(in_cs_q[7:4]);
                8'd27: ch = int21_hc(in_cs_q[3:0]);
                8'd28: ch = " ";
                8'd29: ch = int21_in_label(2'd3, 2'd1);
                8'd30: ch = int21_in_label(2'd3, 2'd0);
                8'd31: ch = "=";
                8'd32: ch = int21_hc(in_eip_q[15:12]);
                8'd33: ch = int21_hc(in_eip_q[11:8]);
                8'd34: ch = int21_hc(in_eip_q[7:4]);
                8'd35: ch = int21_hc(in_eip_q[3:0]);
                default: ch = 8'h0A;          // index 36: the IN line's LF
            endcase
        end else if ((idx - INT21_IN_LEN) < INT21_OUT_LEN) begin
            // "21 OUT AH=.. CY=. AX=.... BX=....\n"  (34 bytes)
            case (idx - INT21_IN_LEN)
                8'd0:  ch = "2";
                8'd1:  ch = "1";
                8'd2:  ch = " ";
                8'd3:  ch = "O";
                8'd4:  ch = "U";
                8'd5:  ch = "T";
                8'd6:  ch = " ";
                8'd7:  ch = int21_out_label(2'd0, 2'd1);
                8'd8:  ch = int21_out_label(2'd0, 2'd0);
                8'd9:  ch = "=";
                8'd10: ch = int21_hc(in_ah_q[7:4]);   // OUT AH is the FUNCTION, carried from entry
                8'd11: ch = int21_hc(in_ah_q[3:0]);
                8'd12: ch = " ";
                8'd13: ch = int21_out_label(2'd1, 2'd1);
                8'd14: ch = int21_out_label(2'd1, 2'd0);
                8'd15: ch = "=";
                8'd16: ch = int21_hc({3'd0, out_cf_q});   // CY is one bit: '0' or '1'
                8'd17: ch = " ";
                8'd18: ch = int21_out_label(2'd2, 2'd1);
                8'd19: ch = int21_out_label(2'd2, 2'd0);
                8'd20: ch = "=";
                8'd21: ch = int21_hc(out_ax_q[15:12]);
                8'd22: ch = int21_hc(out_ax_q[11:8]);
                8'd23: ch = int21_hc(out_ax_q[7:4]);
                8'd24: ch = int21_hc(out_ax_q[3:0]);
                8'd25: ch = " ";
                8'd26: ch = int21_out_label(2'd3, 2'd1);
                8'd27: ch = int21_out_label(2'd3, 2'd0);
                8'd28: ch = "=";
                8'd29: ch = int21_hc(out_bx_q[15:12]);
                8'd30: ch = int21_hc(out_bx_q[11:8]);
                8'd31: ch = int21_hc(out_bx_q[7:4]);
                8'd32: ch = int21_hc(out_bx_q[3:0]);
                default: ch = 8'h0A;          // OUT pos 33: the OUT line's LF
            endcase
        end else begin
            // Unreachable: INT21_MSG_LEN == INT21_IN_LEN + INT21_OUT_LEN, so the bounds above
            // cover the whole record. Stated so the OUT line's guard has an else arm.
            ch = 8'h00;
        end
    end

endmodule

`default_nettype wire

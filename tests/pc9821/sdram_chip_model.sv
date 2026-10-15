`timescale 1ns/1ps

// The SDRAM chip model, in ONE home: `sdram_chip_model` is instantiated by every bench that
// drives src/memory/sdram.v against a device and needs the pins to mean something. It was
// extracted from tb_pc9821_sdram.sv when the TDM bench (tb_pc9821_sdram_tdm.sv) became the
// second consumer, so the two cannot drift about what a READ returns or when.
//
// It is deliberately NOT a datasheet-accurate device: the benches test the CONTROLLER, so the
// one property that matters is that the same pins address the same location on a write and a
// read. The per-model comments below carry the rest.

module sdram_chip_model #(
    // The chip's own CAS latency, in cycles. JEDEC SDR: the read data of a READ command
    // appears CAS (the latency the MRS programmed) clocks after the command, on the pins,
    // independent of when the controller samples it. Two is what sdram.v declares below
    // 100 MHz (CAS_I = 2 below 100 MHz, 3 at 100 MHz and up): a bench at 100 MHz or more
    // passes 3.
    parameter integer CAS = 2,
    // The transfer appears CAS cycles after the controller asserts the READ command.
    // The model tracks the pipeline depth implied by that datasheet statement (one in-flight
    // transfer per CAS stage) and no more: if the controller ever samples at the wrong edge,
    // the data will not be there and the BENCH fails -- the model must not be fitted to the
    // controller's sampling point (it previously was, and that is how F1-class bugs hide).
    parameter integer LATENCY = CAS,
    // JEDEC tRP / t_WR for the config under test, in cycles (the controller's own derived
    // T_RP / T_WR). Defaults are the lenient side so a bench that passes nothing cannot
    // false-fail; the directed benches pass their exact values.
    parameter integer T_RP = 2,
    parameter integer T_WR = 2,
    // Longest tolerated gap, in cycles, between AutoRefresh commands seen on the pins.
    // 0 disables the check. tREFI is 64ms/8192 rows; a dropped refresh (review F3) shows up
    // as a gap of a whole counter wrap past the next attempt.
    parameter integer REFRESH_INTERVAL = 0
) (
    input               clk,
    inout      [15:0]   DQ,
    input      [12:0]   A,
    input      [1:0]    BA,
    input               nRAS,
    input               nCAS,
    input               nWE,
    input               nCS
);
    // A consistent store keyed by the pins the controller drives. This is deliberately
    // NOT a datasheet-accurate SDRAM device: the bench tests the CONTROLLER, so what
    // matters is that the same pins address the same location on a write and on a read.
    localparam [2:0] CMD_MRS = 3'b000,
                     CMD_REF = 3'b001,
                     CMD_PRE = 3'b010,
                     CMD_ACT = 3'b011,
                     CMD_WR  = 3'b100,
                     CMD_RD  = 3'b101,
                     CMD_NOP = 3'b111;

    wire [2:0] cmd = nCS ? CMD_NOP : {nRAS, nCAS, nWE};

    // The MiSTer/XSDS tie: the chip's LDQM/UDQM are wired to the connector's A[11]/A[12]
    // (docs/sdram-dqm-wiring.md). A WRITE captures the mask with its data, so the model samples
    // A[12:11] on the WRITE command edge; a masked-off byte keeps its stored value. Reads are
    // never masked by this core (A[12:11]=00 on READ), so the read side needs no DQM here.
    wire [1:0] wr_dqm = A[12:11];   // {UDQM, LDQM}, active high

    reg [4095:0] seen_bank;                     // banks the model has activated
    reg [15:0]   mem [0:33554431];
    // Set when the controller issues a MODE REGISTER SET. CAS latency and burst type come
    // from that register, so a controller that skipped it would be running on the device's
    // power-on default while every timing check in this bench still passed.
    reg          mrs_seen = 0;

    // The row open PER BANK, as a real device holds it: an ACTIVATE opens one bank's row and
    // it stays open until a PRECHARGE closes it. The earlier single latch held only the last
    // ACTIVATE, which was correct only while the controller auto-precharged every access --
    // exactly what the predicted open-row policy (r13/164) stops doing. An ACTIVATE to a bank
    // whose row is still open with no precharge is a protocol violation and is fatal.
    reg [12:0] row_a [0:3];
    reg  [3:0] row_v = 4'b0000;                 // this bank holds an open row

    // Per-bank precharge countdown (the tRP check). A PRECHARGE / auto-precharge starts the
    // bank's internal precharge; while this is non-zero the bank is PRECHARGING and an ACT to
    // it is fatal -- JEDEC tRP is a hard PRE-to-ACT minimum per bank. Loaded to (duration-1)
    // so the countdown reads 0 on the first cycle the bank is legally ready again:
    //   READ-A  : the internal precharge starts CAS-1 after the READ command (it overlaps the
    //             burst's data-out), so the bank is ready (CAS-1)+tRP after it.
    //   WRITE-A : tWR after the last data-in (BL=1: the WRITE command edge itself), then tRP.
    //   PRE     : tRP after the PRECHARGE command.
    // The controller's own row-split ACT path encodes the same read rule (it waits for full
    // data drain -- the read-data-completion reading is one cycle stricter still -- before its
    // second ACT), which is exactly what the pre-ACT guard (review F1) failed to do.
    reg  [4:0] pre_left [0:3];
    localparam [31:0] PRE_TICKS_RD   = (CAS - 1) + T_RP - 1;
    localparam [31:0] PRE_TICKS_WR   = T_WR + T_RP - 1;
    localparam [31:0] PRE_TICKS_PRE  = T_RP - 1;
    integer  p;
    initial begin
        for (p = 0; p < 4; p = p + 1) pre_left[p] = 5'd0;
        ref_gap  = 32'd0;
        ref_seen = 1'b0;
        cbr_seen = 0;
    end

    // AutoRefresh interval bookkeeping (the review F3 check). ref_gap counts the cycles since
    // the previous AutoRefresh on this chip; a gap over REFRESH_INTERVAL means a pending
    // refresh was dropped or starved past the device's retention interval. cbr_seen counts
    // every AutoRefresh ever seen, because the INIT ones are a requirement of their own:
    // AS4C64M8SD-7TCN 3.2 Initialization -- "A minimum of eight Auto Refresh cycles (CBR) are
    // also required ... Failure to follow these steps may lead to unpredictable start-up
    // modes." A controller that under-inits passes every DATA check and then misbehaves only
    // on real silicon, so the first ACTIVATE closes the account: fewer than 8 CBRs before it
    // is fatal here.
    reg [31:0] ref_gap;
    reg        ref_seen;
    integer    cbr_seen;

    // Read pipeline: each READ command returns exactly one 16-bit half, CAS cycles
    // later. sdram.v's READ comment is explicit: "Issue length-1 READ commands every
    // cycle after T_RCD. Each READ returns one 16-bit half."
    reg      rd_v [0:LATENCY-1];
    reg [15:0] rd_word [0:LATENCY-1];
    integer  i;

    reg [15:0] dq_out_r;
    reg [15:0] bus_data;
    reg        dq_oen_r;

    // A reduction over an UNPACKED array is not legal, so the burst-active term is
    // computed explicitly: the bus is driven while ANY transfer is in flight.
    integer  k;
    reg      any_rd;
    always @* begin
        any_rd = 1'b0;
        for (k = 0; k < LATENCY; k = k + 1) any_rd = any_rd | rd_v[k];
    end
    // bus_data latches the newest transfer, so the last one stays valid while the
    // pipeline drains instead of the bus going to zero under a late sample.
    // Combinational drive: a device holds DQ for the whole burst, and the registered
    // version added a cycle that neither the device nor the controller's dq_r
    // accounting has -- which the cycle-by-cycle trace showed as the high half
    // being captured as the completion of the previous word.
    assign DQ = any_rd ? (rd_v[LATENCY-1] ? rd_word[LATENCY-1] : bus_data) : 16'hZZZZ;

    // The location, as an injective function of (row, bank, column) where column is the
    // low 10 bits A carries during an access -- the field both the write and the read
    // put there. The upper A bits during an access are auto-precharge and the burst's
    // last-half flag, not address.
    wire [24:0] key_w = {BA, row_a[BA], A[9:0]};
    // THE KEY WIDTH IS LOAD-BEARING. This was stored as mem[key_w[15:0]], which throws
    // away the top 8 bits -- BOTH BANK BITS and the top 6 row bits -- so two addresses
    // differing only in their bank aliased to one cell. That is not a tidiness problem:
    // it is exactly the field the geometry decode moves, so with the truncation in place
    // NO check could tell a correct decode from a wrong one, which is why the geometry
    // has been 'reported, not asserted' since this bench was written. The comment above
    // already claimed injectivity; the index now delivers it. 32MB of simulation memory
    // is a fair price for being able to test aliasing at all. It then took a SECOND
    // truncation: key_w dropped row_a[BA][12] of the 13-bit row, so rows 0x000 and 0x1000
    // aliased and a controller that wrapped its row counter at 12 bits shared the model's
    // blind spot and read back 'correctly' (bench-circularity audit entry 5). The key is
    // now the FULL (bank, row, column) triple -- 25 bits -- so no geometry-decode or
    // row-carry bug (review F5) can hide inside the fixture's own aliasing.

    always @(posedge clk) begin
        // Shift the read pipeline; the command seen this cycle emerges CAS later.
        for (i = LATENCY-1; i > 0; i = i - 1) begin
            rd_v[i]    <= rd_v[i-1];
            rd_word[i] <= rd_word[i-1];
        end
        rd_v[0]    <= 1'b0;
        rd_word[0] <= 16'h0000;

        // Age every bank's precharge countdown; a command's load below overrides this.
        for (i = 0; i < 4; i = i + 1)
            if (pre_left[i] != 5'd0) pre_left[i] <= pre_left[i] - 5'd1;

        if (cmd == CMD_ACT) begin
            if (cbr_seen < 8)
                $fatal(1, "sdram_chip_model: ACTIVATE after only %0d init CBR AutoRefreshes (AS4C64M8SD-7TCN 3.2 requires >= 8)",
                       cbr_seen);
            if (row_v[BA])
                $fatal(1, "sdram_chip_model: ACTIVATE to bank %0d whose row is still open (a precharge was skipped)", BA);
            if (pre_left[BA] != 5'd0)
                $fatal(1, "sdram_chip_model: ACTIVATE to bank %0d %0d cycle(s) before its precharge completed (tRP violated)",
                       BA, pre_left[BA]);
            seen_bank[BA] <= 1'b1;
            row_a[BA]     <= A;
            row_v[BA]     <= 1'b1;
        end else if (cmd == CMD_PRE) begin
            if (A[10]) begin
                row_v <= 4'b0000;               // precharge every bank
                for (i = 0; i < 4; i = i + 1) pre_left[i] <= PRE_TICKS_PRE[4:0];
            end else begin
                row_v[BA]    <= 1'b0;           // precharge the selected bank
                pre_left[BA] <= PRE_TICKS_PRE[4:0];
            end
        end else if (cmd == CMD_WR) begin
            // Apply the byte mask carried on A[12:11] (active high): a masked byte keeps its
            // stored value, an unmasked byte takes DQ. With A[12:11]=00 this is a full word write,
            // which is what the DQM-less RMW and gather paths drive.
            mem[key_w] <= {wr_dqm[1] ? mem[key_w][15:8] : DQ[15:8],
                           wr_dqm[0] ? mem[key_w][7:0]  : DQ[7:0]};
            if (A[10]) begin
                row_v[BA]    <= 1'b0;           // auto-precharge on the last half closes it
                pre_left[BA] <= PRE_TICKS_WR[4:0];   // ... and starts tWR + tRP
            end
        end else if (cmd == CMD_RD) begin
            rd_v[0]    <= 1'b1;
            rd_word[0] <= mem[key_w];
            if (A[10]) begin
                row_v[BA]    <= 1'b0;
                pre_left[BA] <= PRE_TICKS_RD[4:0];   // read auto-precharge: starts CAS-1 later
            end
        end else if (cmd == CMD_MRS) begin
            mrs_seen <= 1'b1;
        end

        // The AutoRefresh interval (review F3): a device needs one refresh per row per 64ms,
        // i.e. one AutoRefresh every tREFI on average. A gap over REFRESH_INTERVAL means the
        // controller dropped or starved a pending refresh.
        if (cmd == CMD_REF) begin
            if (ref_seen && (REFRESH_INTERVAL > 0) && (ref_gap > REFRESH_INTERVAL))
                $fatal(1, "sdram_chip_model: %0d cycles since the last AutoRefresh (limit %0d): a pending refresh was dropped or starved",
                       ref_gap, REFRESH_INTERVAL);
            ref_seen  <= 1'b1;
            ref_gap   <= 32'd1;
            cbr_seen  <= cbr_seen + 1;
        end else if (ref_seen) begin
            ref_gap <= ref_gap + 32'd1;
        end

        // Drive the pins the way a device does: DQ is valid from CAS cycles after each
        // READ and STAYS valid until the burst is over. A real SDRAM does not pulse the
        // bus for one cycle per transfer, and sdram.v samples through a registered dq_r,
        // so a one-cycle pulse loses every second half -- which is exactly the symptom
        // the first draft produced (a written word read back as 5a5a0000).
        if (rd_v[LATENCY-1]) bus_data <= rd_word[LATENCY-1];
    end
endmodule

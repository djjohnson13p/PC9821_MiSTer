// pc9821_hps_slot_demux - the one owner of hps_io's shared word bus.
//
// hps_io has ONE sd_buff_wr / sd_buff_addr / sd_buff_dout for every disk slot and a per-slot
// sd_ack[] that is high only for the slot whose transfer is being served (sys/hps_io.sv:
// "sd_ack <= disk[VD:0]"). A module that consumes the shared strobe without its own slot's ack
// also swallows another slot's words (the Policenauts intro stall: the CD's CD-DA words landed
// in hard-disk sectors). This module is the single place the
// shared strobe is qualified: each consumer group gets a PRIVATE strobe that pulses only while
// that group's own ack is high, so a consumer cannot see another slot's words by construction.
//
// CYCLE-IDENTICAL for a slot's own transfers: the output is the input with the strobe ANDed with
// an ack that the consumer already required (pc9821_block_io `stream_word`, pc9821_atapi
// `e_word`), so it is a pure wire in the cases that matter and no register is added. The
// consumers keep their own ack gates as defence in depth.
//
// Two groups: the DISK group (hard disk and both floppies, which share one engine in
// pc9821_block_share) and the CD group (pc9821_atapi, slot 4).
//
// ZERO_DATA: also force addr/dout to zero outside the group's ack. Off by default: addr/dout are
// only ever sampled under the strobe, so zeroing them buys nothing the strobe does not, and
// costs one AND per bit (29 bits per group).
`default_nettype none

module pc9821_hps_slot_demux #(
    parameter ZERO_DATA = 0
) (
    input  wire        sd_buff_wr,
    input  wire [12:0] sd_buff_addr,
    input  wire [15:0] sd_buff_dout,

    input  wire        disk_ack,   // hdd | fdd0 | fdd1 slot acks
    input  wire        cd_ack,

    output wire        disk_buff_wr,
    output wire [12:0] disk_buff_addr,
    output wire [15:0] disk_buff_dout,
    output wire        cd_buff_wr,
    output wire [12:0] cd_buff_addr,
    output wire [15:0] cd_buff_dout
);

  assign disk_buff_wr   = sd_buff_wr && disk_ack;
  assign cd_buff_wr     = sd_buff_wr && cd_ack;
  assign disk_buff_addr = ZERO_DATA ? (sd_buff_addr & {13{disk_ack}}) : sd_buff_addr;
  assign cd_buff_addr   = ZERO_DATA ? (sd_buff_addr & {13{cd_ack}})   : sd_buff_addr;
  assign disk_buff_dout = ZERO_DATA ? (sd_buff_dout & {16{disk_ack}}) : sd_buff_dout;
  assign cd_buff_dout   = ZERO_DATA ? (sd_buff_dout & {16{cd_ack}})   : sd_buff_dout;

endmodule

`default_nettype wire

// The OSD's stored selections, decoded: one place per list POSITION -> value contract.
//
// IT IS A MODULE, NOT A FUNCTION IN THE TOP LEVEL, because a function there is unreachable from
// the benches in this tree. The contract is not obvious: a card with no
// config file passes 0 for every field, so list position 0 must be the bootable default.
// `z486_mister.sv`'s CONF_STR is the other half of every field and
// tools/check_osd_contract.py parses both; if you reorder a list there, map it here.

`default_nettype none

module pc9821_osd (
  // O[63:61],RAM Size - a list POSITION, not a size.
  input  wire [2:0] osd_ram_size,
  // O[4],VSync - a list POSITION, not a polarity.
  input  wire       osd_vsync,
  // O[3],Enter BIOS setup (hold HELP): 0 = Off (the default a config-less card passes).
  input  wire       osd_bios_setup,
  // O[32],GDC Clock: 0 = 2.5 MHz (position 0, the measured machine's strap and the
  // default a config-less card passes), 1 = 5 MHz.
  input  wire       osd_gdc_clock,
  // pc9821_system's guest-size code: 0..6 = log2(MiB), 7 = the 96 MiB ceiling.
  output reg  [2:0] ram_size_code,
  // 1 = the guest's own rate (the OSD's "Variable"), 0 = forced 60 Hz. NOTE the polarity
  // inverts with the list: see the VSync comment below.
  output wire       vsync_native,
  // 1 = the keyboard holds HELP (0x3F) from reset, which the ITF's POST reads to enter SETUP.
  // The generator is pc9821_kbd's; owns the evidence.
  output wire       bios_setup,
  // 1 = 5 MHz: PC-9821 port 0x31 bit 7 CLEAR. The strap's own semantics, its ROM consumer
  // and why it is not the software-DIP record are on pc9821_iobus's port declaration.
  output wire       gdc_clock_5m
);

              // O[63:61],RAM Size,16M,32M,64M,96M,1M,2M,4M,8M
              // THE LIST IS ROTATED: MiSTer uses OPTION INDEX 0 FOR EVERY FIELD when a core has no stored
              // config file, so index 0 has to BE the default, and an ascending 1M..96M list cannot also
              // put 16 MB first. A rotated list makes a card with no .CFG behave like a card with a
              // zeroed one.
              // Four places of rotation, written out so a reader need not do modular arithmetic, with the
              // size CODE unchanged downstream (0..6 = log2(MiB), 7 = the 96 MiB ceiling):
              //   entry 0 -> 16 MiB (the default)   entry 4 -> 1 MiB
              //   entry 1 -> 32 MiB                 entry 5 -> 2 MiB
              //   entry 2 -> 64 MiB                 entry 6 -> 4 MiB
              //   entry 3 -> 96 MiB                 entry 7 -> 8 MiB
  always @* begin
    case (osd_ram_size)
      3'd0:    ram_size_code = 3'd4;   // entry 0 -> 16 MiB <- the DEFAULT, and the point
      3'd1:    ram_size_code = 3'd5;   // entry 1 -> 32 MiB
      3'd2:    ram_size_code = 3'd6;   // entry 2 -> 64 MiB
      3'd3:    ram_size_code = 3'd7;   // entry 3 -> 96 MiB, the design's ceiling
      3'd4:    ram_size_code = 3'd0;   // entry 4 -> 1 MiB
      3'd5:    ram_size_code = 3'd1;   // entry 5 -> 2 MiB
      3'd6:    ram_size_code = 3'd2;   // entry 6 -> 4 MiB
      default: ram_size_code = 3'd3;   // entry 7 -> 8 MiB
    endcase
  end

  // O[4],VSync,Variable,60Hz - rotated for the same reason, so index 0 is the core's NATIVE
  // rate rather than 60 Hz. THE BIT THEREFORE MEANS THE OPPOSITE OF WHAT IT MEANT BEFORE THE
  // ROTATION: 0 is now "the guest's own rate" and 1 is "forced 60 Hz".
  assign vsync_native = ~osd_vsync;

  // O[3],Enter BIOS setup (hold HELP),Off,On. Identity: position 0 = Off = the default.
  assign bios_setup = osd_bios_setup;

  // O[32],GDC Clock,2.5 MHz,5 MHz. Identity: position 0 = 2.5 MHz, which is the strap the
  // measured machine answers (0xF3, bit 7 set) and therefore what a config-less card boots.
  assign gdc_clock_5m = osd_gdc_clock;

endmodule

`default_nettype wire

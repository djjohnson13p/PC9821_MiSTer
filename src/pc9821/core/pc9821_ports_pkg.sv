// Shared pc9821 I/O fabric decode constants.
//
// The 194 one-hot `hit[]` decode indices and the iobus access-FSM states were
// module `localparam`s in pc9821_iobus.sv. Module localparams are not reachable
// through the instance hierarchy, so white-box benches had to hardcode raw
// integers (`dut.hit[182]`, `dut.state == 3'd1`); those go stale the moment a
// lane inserts a decode entry (the hit[181] -> hit[182] shift fixed in
// tb_pc9821_mouse.sv). They live here so benches name them instead.
//
// HX_E0D0/HX_E0D2 are the MPU-PC98II's two ports (pc9821_mpu): they sort after the
// device half's last port 0xA46E, so they end the device run and every SYSTEM index
// moved by two when they landed (83..191 -> 85..193).
package pc9821_ports_pkg;
  // The iobus access FSM states.
  localparam [2:0] S_IDLE    = 3'd0;
  localparam [2:0] S_BYTE    = 3'd1;
  localparam [2:0] S_FLUSH   = 3'd2;
  localparam [2:0] S_REPLY   = 3'd3;
  localparam [2:0] S_HOLD    = 3'd4;
  localparam [2:0] S_DEVWAIT = 3'd5;
  localparam [2:0] S_IOWAIT  = 3'd6;

  // hit[] one-hot decode indices: device ports ascending in hit[0..84], then
  // system ports ascending in hit[85..193].
  localparam int HX_0000 = 0, HX_0002 = 1, HX_0008 = 2, HX_000A = 3, HX_0020 = 4, HX_0022 = 5, HX_0041 = 6, HX_0043 = 7;
  localparam int HX_0060 = 8, HX_0062 = 9, HX_0064 = 10, HX_0068 = 11, HX_006A = 12, HX_006E = 13, HX_0070 = 14, HX_0071 = 15;
  localparam int HX_0072 = 16, HX_0073 = 17, HX_0074 = 18, HX_0075 = 19, HX_0076 = 20, HX_0077 = 21, HX_0078 = 22, HX_007A = 23;
  localparam int HX_007C = 24, HX_007E = 25, HX_00A0 = 26, HX_00A1 = 27, HX_00A2 = 28, HX_00A3 = 29, HX_00A4 = 30, HX_00A5 = 31;
  localparam int HX_00A6 = 32, HX_00A8 = 33, HX_00A9 = 34, HX_00AA = 35, HX_00AC = 36, HX_00AE = 37, HX_0128 = 38, HX_0188 = 39;
  localparam int HX_018A = 40, HX_018C = 41, HX_018E = 42, HX_0430 = 43, HX_0432 = 44, HX_0433 = 45, HX_0435 = 46, HX_0640 = 47;
  localparam int HX_0641 = 48, HX_0642 = 49, HX_0644 = 50, HX_0646 = 51, HX_0648 = 52, HX_064A = 53, HX_064C = 54, HX_064E = 55;
  localparam int HX_0740 = 56, HX_0742 = 57, HX_0744 = 58, HX_0746 = 59, HX_0748 = 60, HX_074A = 61, HX_074C = 62, HX_074E = 63;
  localparam int HX_1480 = 64, HX_1481 = 65, HX_1482 = 66, HX_1483 = 67, HX_1484 = 68, HX_1485 = 69, HX_1486 = 70, HX_1487 = 71;
  localparam int HX_3FD9 = 72, HX_3FDB = 73, HX_3FDD = 74, HX_3FDF = 75, HX_A462 = 76, HX_A464 = 77, HX_A466 = 78, HX_A468 = 79;
  localparam int HX_A46A = 80, HX_A46C = 81, HX_A46E = 82, HX_E0D0 = 83, HX_E0D2 = 84, HX_0001 = 85, HX_0003 = 86, HX_0005 = 87;
  localparam int HX_0007 = 88, HX_0009 = 89, HX_000B = 90, HX_000D = 91, HX_000F = 92, HX_0011 = 93, HX_0019 = 94, HX_001B = 95;
  localparam int HX_0021 = 96, HX_0023 = 97, HX_0025 = 98, HX_0027 = 99, HX_0029 = 100, HX_0031 = 101, HX_0032 = 102, HX_0033 = 103;
  localparam int HX_0035 = 104, HX_0037 = 105, HX_0040 = 106, HX_0042 = 107, HX_0044 = 108, HX_005C = 109, HX_005D = 110, HX_005E = 111;
  localparam int HX_005F = 112, HX_0090 = 113, HX_0092 = 114, HX_0094 = 115, HX_00A7 = 116, HX_00BE = 117, HX_00BF = 118, HX_00C8 = 119;
  localparam int HX_00CA = 120, HX_00CC = 121, HX_00F0 = 122, HX_00F1 = 123, HX_00F2 = 124, HX_00F4 = 125, HX_00F6 = 126, HX_0134 = 127;
  localparam int HX_0149 = 128, HX_0434 = 129, HX_0436 = 130, HX_0439 = 131, HX_043B = 132, HX_043D = 133, HX_043F = 134, HX_0461 = 135;
  localparam int HX_0463 = 136, HX_04A0 = 137, HX_04A1 = 138, HX_04A2 = 139, HX_04A3 = 140, HX_04A4 = 141, HX_04A5 = 142, HX_04A6 = 143;
  localparam int HX_04A7 = 144, HX_04A8 = 145, HX_04A9 = 146, HX_04AA = 147, HX_04AB = 148, HX_04AC = 149, HX_04AD = 150, HX_04AE = 151;
  localparam int HX_04AF = 152, HX_04BE = 153, HX_0530 = 154, HX_0531 = 155, HX_0534 = 156, HX_053D = 157, HX_053E = 158, HX_0567 = 159;
  localparam int HX_0610 = 160, HX_0611 = 161, HX_063C = 162, HX_063D = 163, HX_063E = 164, HX_063F = 165, HX_09A0 = 166, HX_09A8 = 167;
  localparam int HX_09AE = 168, HX_0E00 = 169, HX_0E02 = 170, HX_0E05 = 171, HX_0E07 = 172, HX_0E09 = 173, HX_0E0B = 174, HX_0E0F = 175;
  localparam int HX_0EE0 = 176, HX_0FAA = 177, HX_0FAB = 178, HX_0FAC = 179, HX_18F0 = 180, HX_18F1 = 181, HX_18F2 = 182, HX_18F3 = 183;
  localparam int HX_1E8E = 184, HX_7FD9 = 185, HX_7FDB = 186, HX_7FDD = 187, HX_7FDF = 188, HX_9892 = 189, HX_9894 = 190, HX_98D7 = 191;
  localparam int HX_A460 = 192, HX_BFDB = 193;
endpackage

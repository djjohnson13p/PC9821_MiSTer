// The device-bus chip selects, decoded once: a pure function of the 16-bit port address, giving
// the selects pc9821_system routes on. It exists because the same decode was written twice - in
// pc9821_system and inside pc9821_interrupts - and because a module is the only shape
// a bench can sweep exhaustively over all 65,536 port addresses.
// The SHAPES matter as much as the duplication: a range test costs a carry chain, while the alias
// this core supports is a high-bit equality. Sparse devices decode as exact addresses.
`default_nettype none

module pc9821_device_select #(
    // Whether the MPU-PC98II exists (z486_mister.sv's MPU_EN). A parameter rather than a pin,
    // because it is a build-profile constant: with MPU_EN 0 `mpu_cs` is a constant 0 and
    // `gdc_cs` is the complement of exactly the list it had before the card existed.
    parameter MPU_EN = 1'b0
) (
    input  [15:0] addr,

    output wire pic_master_cs,   // 0x0000/0x0002, the master 8259
    output wire pic_slave_cs,    // 0x0008/0x000A, the slave 8259
    output wire pit_cs,          // 0x71/73/75/77 and 0x3FD9/DB/DD/DF
    output wire interrupt_cs,    // the 8259 pair and the PIT together
      // The calendar sits on the device bus, so it gets a real chip select and a real 4-bit decode.
    output wire cal_cs,          // 0x0020/0x0022/0x0128, the uPD4990
    output wire kbd_cs,          // 0x0041/0x0043, the uPD8251
    output wire ata_cs,          // the IDE connection ports and task file
      // The PC-9801-86's OPNA: the base pair and the extension pair the card adds. Both are decoded
      // because the card answers at both.
    output wire opna_cs,         // 0x0188/0x018A/0x018C/0x018E
      // The same board's OTHER device, the 86-PCM block: sparse, with nothing between its registers,
      // so it decodes as exact addresses rather than a range.
    output wire pcm_cs,          // 0x0A462/64/66/68/6A/6C/6E, the even ports
      // The PC-9801-118's game port, 0x1480-0x1487. The card answers all eight addresses and
      // does not distinguish them (NP2kai cbus/board118.c:816-822), so the claim is one range.
    output wire gameport_cs,
      // The Roland MPU-PC98II's two ports, 0xE0D0 (data) and 0xE0D2 (status/command). NP2kai
      // attaches the standalone card at `port` and `port | 2` (cbus/mpu98ii.c:1177-1179), which
      // is why the pair is +0/+2 and not +0/+1 (the PC-9801-118's variant is the +0/+1 pair).
      // MPU_EN 0 (the base build) leaves the decode exactly as it was: the card's two
      // addresses stay on the GDC's complement and the select never asserts.
    output wire mpu_cs,
    output wire gdc_cs           // everything else on the device bus
);
    assign pic_master_cs = (addr == 16'h0000) || (addr == 16'h0002);
    assign pic_slave_cs = (addr == 16'h0008) || (addr == 16'h000A);
    assign pit_cs = ((addr[15:3] == 13'h000E) || (addr[15:3] == 13'h07FB)) && addr[0];
    assign interrupt_cs = pic_master_cs || pic_slave_cs || pit_cs;
    assign cal_cs = (addr == 16'h0020) || (addr == 16'h0022) || (addr == 16'h0128);
    assign kbd_cs = (addr == 16'h0041) || (addr == 16'h0043);
      // The ATA task file is 0x0640-0x064E - one high-bit equality plus a low-bit range - so it is
      // cheap and it is the shape the alternate status port 0x074C shares.
    assign ata_cs = (addr == 16'h0430) || (addr == 16'h0432) ||
                    (addr == 16'h0433) || (addr == 16'h0435) ||
                    ((addr[15:4] == 12'h064) && (addr[3:0] != 4'hF)) ||
                    ((addr[15:4] == 12'h074) && (addr[3:0] != 4'hF));
    assign opna_cs = (addr == 16'h0188) || (addr == 16'h018A) ||
                     (addr == 16'h018C) || (addr == 16'h018E);
      // Every 86-PCM register is an exact address; the gaps between them answer nothing, which is
      // what the card does.
    assign pcm_cs = (addr == 16'h0A462) || (addr == 16'h0A464) ||
                    (addr == 16'h0A466) || (addr == 16'h0A468) ||
                    (addr == 16'h0A46A) || (addr == 16'h0A46C) ||
                    (addr == 16'h0A46E);
      // One high-bit equality covers the card's eight addresses: 0x1480-0x1487.
    assign gameport_cs = (addr[15:3] == 13'h0290);
      // The MPU-PC98II's two exact addresses, and only when the build has the card. MAME's
      // PC-9821 map lists the whole four-byte window 0xE0D0-0xE0D3 (as `<undefined>`,
      // pc9821.cpp:768), but NP2kai attaches two ports, and that divergence
      // is recorded here: 0xE0D1/0xE0D3 stay undecoded here.
    assign mpu_cs = MPU_EN && ((addr == 16'hE0D0) || (addr == 16'hE0D2));
    assign gdc_cs = !(interrupt_cs || kbd_cs || ata_cs || cal_cs || opna_cs || pcm_cs ||
                      gameport_cs || mpu_cs);
endmodule

`default_nettype wire

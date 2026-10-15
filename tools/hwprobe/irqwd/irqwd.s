/* irqwd.s - the masked-ack / request-withdraw probe for the PC-9821.
 *
 * WHAT IT SETTLES. The core's 8259 model (pc9821_pic.sv) is EDGE-latched: a
 * request bit is set on the line's rising edge and cleared ONLY by INTA or ICW1.
 * Every device lowers its own line on the guest's acking access, so a guest that
 * masks a line, acks the device, then unmasks can receive one phantom delivery.
 * NP2kai withdraws the request at the acking access for the keyboard (0x41), the
 * IDE (0x64E), the calendar (0x128), the OPNA (register 0x27) and the MPU, and
 * clears a masked timer request at the timer. This probe measures the masked-ack
 * case DIRECTLY, one line at a time, on the real machine.
 *
 * METHOD, per line: mask everything except the line under test, trigger a device
 * request, wait until the request is LATCHED (poll the controller's IRR), do the
 * acking access, and read the IRR again. The POST-ACK IRR BIT IS THE VERDICT: set
 * = the request is still pending (the machine HOLDS it, the core's edge latch is
 * faithful for that line); clear = the machine WITHDREW it (adopt pic_resetirq).
 * Nothing is delivered: the whole test runs with IF=0, and no interrupt vector is
 * touched, so the probe cannot leave a device's line stuck high (an earlier
 * version installed a stub that EOIs without reading the device, which left the
 * keyboard's 8251 RXRDY set and killed IRQ1 until reset).
 *
 * IRQ0 is the special case: it has no acking access, so its section masks IRQ0
 * and polls the master IRR bit 0 for a 1->0 transition (the STEELGUN idiom),
 * counting transitions. PITOUT is its control - it reads the PIT channel-0 OUT
 * pin back (the 8254 read-back status bit 7) and counts ITS transitions, so the
 * IRQ0 result is interpretable: PIT out toggling and IRR bit0 never falling is a
 * real HOLD; a static OUT means the timer was not running and the row is void.
 * PITCH0 is the second timer case (NP2kai io/pit.c:378/471 clears the request on
 * a channel-0 write).
 *
 * SAFETY: read-first; the as-found master/slave IMRs, the 0x0432 bank byte and
 * the PIT channel-0 count are saved and restored (the PIT is only ever sent the
 * READ-BACK command 0xC2 and the stateless latch command 0x00 - its mode and
 * divisor are never changed), and the restore is printed. The OPNA timers are
 * left stopped with both flags cleared. No disk write, no vector write, no
 * memory write. Every spin is bounded.
 */

    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

    .equ MPIC_CMD, 0x0000
    .equ MPIC_IMR, 0x0002
    .equ SPIC_CMD, 0x0008
    .equ SPIC_IMR, 0x000A

_start:
    push    cs
    pop     ds
    push    cs
    pop     es

    mov     dx, offset msg_banner
    call    puts

    call    sec_state
    call    sec_pitout
    call    sec_irq0
    call    sec_pitch0
    call    sec_irq1
    call    sec_irq9
    call    sec_irq12
    call    sec_irq15
    call    sec_verdict
    call    sec_restore

    mov     dx, offset msg_done
    call    puts
    mov     ax, 0x4C00
    int     0x21
    hlt

/* ==================================================================
 * section: STATE - the as-found PIC registers
 * ================================================================== */
sec_state:
    mov     dx, offset msg_begin_state
    call    puts
    cli
    mov     dx, MPIC_IMR
    in      al, dx
    mov     [m_imr_found], al
    mov     dx, SPIC_IMR
    in      al, dx
    mov     [s_imr_found], al
    call    pic_state_read
    sti

    mov     dx, offset msg_state_m
    call    puts
    mov     al, [m_imr_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [m_irr_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [m_isr_found]
    call    puthex8
    call    putnl

    mov     dx, offset msg_state_s
    call    puts
    mov     al, [s_imr_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [s_irr_found]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [s_isr_found]
    call    puthex8
    call    putnl

    mov     dx, offset msg_end_state
    call    puts
    ret

/* pic_state_read: m_irr/m_isr/s_irr/s_isr into the *_found bytes. */
pic_state_read:
    push    ax
    push    dx
    mov     dx, MPIC_CMD
    mov     al, 0x0A
    out     dx, al
    in      al, dx
    mov     [m_irr_found], al
    mov     al, 0x0B
    out     dx, al
    in      al, dx
    mov     [m_isr_found], al
    mov     dx, SPIC_CMD
    mov     al, 0x0A
    out     dx, al
    in      al, dx
    mov     [s_irr_found], al
    mov     al, 0x0B
    out     dx, al
    in     al, dx
    mov     [s_isr_found], al
    pop     dx
    pop     ax
    ret

/* ==================================================================
 * section: PITOUT - is PIT channel 0 actually toggling? (the IRQ0 control)
 * ================================================================== */
sec_pitout:
    mov     dx, offset msg_begin_pitout
    call    puts
    cli
    call    pit_status             /* status of ch0 in pit_stat */
    mov     al, [pit_stat]
    and     al, 0x80
    mov     bl, al                 /* prev OUT */
    mov     word ptr [out_lo], 0
    mov     word ptr [out_hi], 0
    mov     word ptr [out_fall], 0
    mov     word ptr [out_rise], 0
    mov     bp, 0x0004
po_outer:
    mov     cx, 0xFFFF
po_inner:
    call    pit_status
    mov     al, [pit_stat]
    and     al, 0x80
    cmp     al, 0
    jne     po_high
    inc     word ptr [out_lo]
    cmp     bl, 0x80
    jne     po_next
    inc     word ptr [out_fall]
    jmp     po_next
po_high:
    inc     word ptr [out_hi]
    cmp     bl, 0
    jne     po_next
    inc     word ptr [out_rise]
po_next:
    mov     bl, al
    loop    po_inner
    dec     bp
    jnz     po_outer
    sti

    mov     dx, offset msg_pitout_row
    call    puts
    mov     al, [pit_stat]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     ax, [out_lo]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [out_hi]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [out_fall]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [out_rise]
    call    putdec16
    call    putnl
    mov     dx, offset msg_end_pitout
    call    puts
    ret

/* pit_status_count: ch0 read-back status into pit_stat and the latched count
 * LSB/MSB into pit_cl/pit_ch (8254 read-back 0xC2; bit1 selects counter 0). */
pit_status_count:
    push    ax
    push    dx
    mov     dx, 0x0077
    mov     al, 0xC2
    out     dx, al
    mov     dx, 0x0071
    in      al, dx
    mov     [pit_stat], al
    in      al, dx
    mov     [pit_cl], al
    in      al, dx
    mov     [pit_ch], al
    pop     dx
    pop     ax
    ret

/* pit_status: read PIT ch0's read-back status into pit_stat (8254 read-back
 * 0xC2; on this part bit1 selects counter 0 - NP2kai io/pit.c:484). The two
 * following reads consume the latched count so the read pointer stays clean. */
pit_status:
    push    ax
    push    dx
    mov     dx, 0x0077
    mov     al, 0xC2
    out     dx, al
    mov     dx, 0x0071
    in      al, dx
    mov     [pit_stat], al
    in      al, dx
    in      al, dx
    pop     dx
    pop     ax
    ret

/* ==================================================================
 * section: IRQ0 - the masked timer request over time (the STEELGUN idiom)
 * ================================================================== */
sec_irq0:
    mov     dx, offset msg_begin_irq0
    call    puts
    cli
    /* Capture the ch0 status and count, then put the channel in mode 3 for the
     * test IF it is not already (mode 2's OUT low is one 2.4576 MHz clock, too
     * short for either a level-following IRR or a fast poll to see reliably).
     * The as-found mode/RL/BCD and count are written back afterwards. */
    call    pit_status_count
    mov     al, [pit_stat]
    and     al, 0x0E
    cmp     al, 0x06                /* mode 3 = bits3:1 == 011 */
    je      irq0_ready
    mov     dx, 0x0077
    mov     al, 0x36                /* ch0, LSB+MSB, mode 3 */
    out     dx, al
    mov     dx, 0x0071
    xor     al, al
    out     dx, al
    mov     al, 0x10                /* divisor 0x1000 -> ~600 Hz */
    out     dx, al
    mov     byte ptr [pit_reprog], 1
irq0_ready:
    mov     dx, MPIC_IMR
    in      al, dx
    mov     [m_imr_save], al
    or      al, 0x01                /* mask IRQ0 */
    out     dx, al

    call    pic_irr_m
    and     al, 0x01
    mov     bl, al                  /* prev */
    mov     word ptr [n_lo], 0
    mov     word ptr [n_hi], 0
    mov     word ptr [n_fall], 0
    mov     word ptr [n_rise], 0

    mov     bp, 0x0020              /* outer x 65535 polls */
irq0_outer:
    mov     cx, 0xFFFF
irq0_inner:
    call    pic_irr_m
    and     al, 0x01
    cmp     al, 0
    jne     irq0_high
    inc     word ptr [n_lo]
    cmp     bl, 1
    jne     irq0_next
    inc     word ptr [n_fall]
    jmp     irq0_next
irq0_high:
    inc     word ptr [n_hi]
    cmp     bl, 0
    jne     irq0_next
    inc     word ptr [n_rise]
irq0_next:
    mov     bl, al
    loop    irq0_inner
    dec     bp
    jnz     irq0_outer

    mov     dx, MPIC_IMR
    mov     al, [m_imr_save]
    out     dx, al
    /* put ch0 back if we changed it */
    cmp     byte ptr [pit_reprog], 1
    jne     irq0_no_restore
    mov     dx, 0x0077
    mov     al, [pit_stat]
    and     al, 0x3F                /* RL | mode | BCD, channel 0 */
    out     dx, al
    mov     dx, 0x0071
    mov     al, [pit_cl]
    out     dx, al
    mov     al, [pit_ch]
    out     dx, al
irq0_no_restore:
    sti

    mov     dx, offset msg_irq0_row
    call    puts
    mov     al, [pit_stat]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     ax, [n_lo]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [n_hi]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [n_fall]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [n_rise]
    call    putdec16
    call    putnl
    mov     dx, offset msg_end_irq0
    call    puts
    ret

/* ==================================================================
 * section: PITCH0 - does a PIT channel-0 control write clear IRQ0's request?
 * ================================================================== */
sec_pitch0:
    mov     dx, offset msg_begin_pitch0
    call    puts
    cli
    mov     dx, MPIC_IMR
    in      al, dx
    mov     [m_imr_save], al
    or      al, 0x01
    out     dx, al

    mov     bp, 0x0020
p0_outer:
    mov     cx, 0xFFFF
p0_inner:
    call    pic_irr_m
    test    al, 0x01
    jnz     p0_have
    loop    p0_inner
    dec     bp
    jnz     p0_outer
p0_have:
    mov     [p0_pre], al
    mov     dx, 0x0077             /* PIT ch0 latch command (stateless) */
    mov     al, 0x00
    out     dx, al
    call    pic_irr_m
    mov     [p0_post], al

    mov     dx, MPIC_IMR
    mov     al, [m_imr_save]
    out     dx, al
    sti

    mov     dx, offset msg_pitch0_row
    call    puts
    mov     al, [p0_pre]
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [p0_post]
    call    puthex8
    call    putnl
    mov     dx, offset msg_end_pitch0
    call    puts
    ret

/* ==================================================================
 * section: IRQ1 - keyboard, the 0x41 data read is the acking access
 * ================================================================== */
sec_irq1:
    mov     dx, offset msg_begin_irq1
    call    puts
    cli
    mov     word ptr [tgt_port], MPIC_CMD
    mov     byte ptr [tgt_bit], 0x02
    mov     byte ptr [tgt_m_imr], 0xFD       /* only IRQ1 clear */
    mov     byte ptr [tgt_s_imr], 0xFF
    call    begin_test
    /* the prompt goes to the SCREEN as well as stdout, so it is visible when
     * the capture is redirected to IRQWD.TXT */
    mov     dx, offset msg_irq1_prompt
    call    puts_bios
    mov     dx, offset msg_irq1_prompt
    call    puts
    call    spin_latch
    mov     byte ptr [trig_ok], 0
    jc      irq1_ack
    mov     byte ptr [trig_ok], 1
irq1_ack:
    cmp     byte ptr [trig_ok], 0
    je      irq1_done
    mov     dx, 0x0041
    in      al, dx
irq1_done:
    call    end_test
    mov     dx, offset msg_row1
    call    puts
    call    put_row
    mov     dx, offset msg_end_irq1
    call    puts
    ret

/* ==================================================================
 * section: IRQ9 - IDE, the 0x64E status read is the acking access
 * ================================================================== */
sec_irq9:
    mov     dx, offset msg_begin_irq9
    call    puts
    cli
    /* save the 0432 bank, then put the interface at bank 1 */
    mov     dx, 0x0432
    in      al, dx
    mov     [bank_save], al
    mov     al, 0x01
    out     dx, al

    mov     word ptr [tgt_port], SPIC_CMD
    mov     byte ptr [tgt_bit], 0x02
    mov     byte ptr [tgt_m_imr], 0x7F       /* cascade clear */
    mov     byte ptr [tgt_s_imr], 0xFD       /* only IRQ9 clear */
    call    begin_test

    mov     dx, 0x064C
    mov     al, 0xA0
    out     dx, al
    call    ata_settle
    mov     dx, 0x064E
    in      al, dx
    mov     dx, 0x064E
    mov     al, 0xEC                         /* IDENTIFY DEVICE */
    out     dx, al
    call    ata_settle

    call    spin_latch
    mov     byte ptr [trig_ok], 0
    jc      irq9_ack
    mov     byte ptr [trig_ok], 1
irq9_ack:
    cmp     byte ptr [trig_ok], 0
    je      irq9_done
    mov     dx, 0x064E
    in      al, dx
    mov     [ata_st], al
    test    al, 0x08                         /* DRQ: drain the block, bounded */
    jz      irq9_done
    mov     dx, 0x0640
    mov     cx, 256
    mov     di, offset drain_buf
    cld
irq9_drain:
    in      ax, dx
    stosw
    loop    irq9_drain
irq9_done:
    /* restore the bank BEFORE sti, so a still-latched IRQ9 is delivered to the
     * real INT 11h handler with the as-found bank */
    mov     dx, 0x0432
    mov     al, [bank_save]
    out     dx, al
    call    end_test

    mov     dx, offset msg_row9
    call    puts
    call    put_row
    mov     dx, offset msg_end_irq9
    call    puts
    ret

/* ==================================================================
 * section: IRQ12 - OPNA Timer B; register 0x27's stop/clear is the acking write
 * ================================================================== */
sec_irq12:
    mov     dx, offset msg_begin_irq12
    call    puts
    cli
    mov     word ptr [tgt_port], SPIC_CMD
    mov     byte ptr [tgt_bit], 0x10
    mov     byte ptr [tgt_m_imr], 0x7F
    mov     byte ptr [tgt_s_imr], 0xEF       /* only IRQ12 clear */
    call    begin_test

    /* Timer B: period 0x26 <- 0, then 0x27 <- 0x2A (run B + IRQ enable + clear) */
    mov     dx, 0x0188
    mov     al, 0x26
    out     dx, al
    mov     dx, 0x018A
    xor     al, al
    out     dx, al
    mov     dx, 0x0188
    mov     al, 0x27
    out     dx, al
    mov     dx, 0x018A
    mov     al, 0x2A
    out     dx, al

    call    spin_latch
    mov     byte ptr [trig_ok], 0
    jc      irq12_ack
    mov     byte ptr [trig_ok], 1
irq12_ack:
    cmp     byte ptr [trig_ok], 0
    je      irq12_done
    mov     dx, 0x0188
    mov     al, 0x27
    out     dx, al
    mov     dx, 0x018A
    mov     al, 0x30                         /* stop both, clear both flags */
    out     dx, al
irq12_done:
    call    end_test
    mov     dx, offset msg_row12
    call    puts
    call    put_row
    mov     dx, offset msg_end_irq12
    call    puts
    ret

/* ==================================================================
 * section: IRQ15 - calendar; the 0x128 rate read is the acking access
 * ================================================================== */
sec_irq15:
    mov     dx, offset msg_begin_irq15
    call    puts
    cli
    mov     word ptr [tgt_port], SPIC_CMD
    mov     byte ptr [tgt_bit], 0x80
    mov     byte ptr [tgt_m_imr], 0x7F
    mov     byte ptr [tgt_s_imr], 0x7F       /* only IRQ15 clear */
    call    begin_test

    /* make the tick rate deterministic: read the as-found rate (which also
     * clears any pending tick), run at 1/64 s, and restore the rate after */
    mov     dx, 0x0128
    in      al, dx
    mov     [cal_rate], al
    mov     al, 0x00
    out     dx, al

    call    spin_latch
    mov     byte ptr [trig_ok], 0
    jc      irq15_ack
    mov     byte ptr [trig_ok], 1
irq15_ack:
    cmp     byte ptr [trig_ok], 0
    je      irq15_done
    mov     dx, 0x0128
    in      al, dx
irq15_done:
    /* restore the rate BEFORE sti, so a still-latched IRQ15 is delivered to the
     * real INT 17h handler with the as-found rate */
    mov     dx, 0x0128
    mov     al, [cal_rate]
    out     dx, al
    call    end_test
    mov     dx, offset msg_row15
    call    puts
    call    put_row
    mov     dx, offset msg_end_irq15
    call    puts
    ret

/* ==================================================================
 * section: VERDICT - one decoded row per line
 * ================================================================== */
sec_verdict:
    mov     dx, offset msg_begin_verdict
    call    puts

    mov     dx, offset msg_v_pitout
    call    puts
    mov     ax, [out_fall]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [out_rise]
    call    putdec16
    call    putnl

    mov     dx, offset msg_v_irq0
    call    puts
    mov     ax, [n_fall]
    call    putdec16
    mov     dl, ' '
    call    putc
    mov     ax, [n_rise]
    call    putdec16
    call    putnl

    mov     dx, offset msg_v_pitch0
    call    puts
    mov     al, [p0_pre]
    and     al, 0x01
    call    puthex8
    mov     dl, ' '
    call    putc
    mov     al, [p0_post]
    and     al, 0x01
    call    puthex8
    call    putnl

    mov     dx, offset msg_end_verdict
    call    puts
    ret

/* ==================================================================
 * section: RESTORE
 * ================================================================== */
sec_restore:
    mov     dx, offset msg_begin_restore
    call    puts
    cli
    /* OPNA timers stopped, both flags cleared (the egcport.com end state) */
    mov     dx, 0x0188
    mov     al, 0x27
    out     dx, al
    mov     dx, 0x018A
    mov     al, 0x30
    out     dx, al
    /* IMRs back */
    mov     dx, MPIC_IMR
    mov     al, [m_imr_found]
    out     dx, al
    mov     dx, SPIC_IMR
    mov     al, [s_imr_found]
    out     dx, al
    sti

    mov     dx, offset msg_restore_m
    call    puts
    mov     al, [m_imr_found]
    call    puthex8
    mov     dx, offset msg_arrow
    call    puts
    mov     dx, MPIC_IMR
    in      al, dx
    call    puthex8
    call    putnl

    mov     dx, offset msg_restore_s
    call    puts
    mov     al, [s_imr_found]
    call    puthex8
    mov     dx, offset msg_arrow
    call    puts
    mov     dx, SPIC_IMR
    in      al, dx
    call    puthex8
    call    putnl

    mov     dx, offset msg_end_restore
    call    puts
    ret

/* ==================================================================
 * masked-ack test helpers
 * ================================================================== */

/* begin_test: save both IMRs and write the isolating masks. NO vector is touched
 * and nothing is delivered, so no device's line can be left stuck high. */
begin_test:
    push    ax
    push    dx
    mov     dx, MPIC_IMR
    in      al, dx
    mov     [m_imr_save], al
    mov     dx, SPIC_IMR
    in      al, dx
    mov     [s_imr_save], al
    mov     dx, MPIC_IMR
    mov     al, [tgt_m_imr]
    out     dx, al
    mov     dx, SPIC_IMR
    mov     al, [tgt_s_imr]
    out     dx, al
    mov     byte ptr [latched], 0
    mov     byte ptr [post_irr], 0
    pop     dx
    pop     ax
    ret

/* end_test: post-ack IRR, then restore both IMRs. The caller's section ends with
 * sti, at which point a still-latched request is delivered to the device's real
 * handler (which does the device ack) exactly as it would to any guest. */
end_test:
    push    ax
    push    dx
    call    pic_irr_tgt
    mov     [post_irr], al
    mov     dx, MPIC_IMR
    mov     al, [m_imr_save]
    out     dx, al
    mov     dx, SPIC_IMR
    mov     al, [s_imr_save]
    out     dx, al
    sti
    pop     dx
    pop     ax
    ret

/* pic_irr_tgt: AL = the IRR of the controller named by tgt_port. */
pic_irr_tgt:
    push    dx
    mov     dx, [tgt_port]
    mov     al, 0x0A
    out     dx, al
    in      al, dx
    pop     dx
    ret

/* pic_irr_m: AL = the master IRR. */
pic_irr_m:
    push    dx
    mov     dx, MPIC_CMD
    mov     al, 0x0A
    out     dx, al
    in      al, dx
    pop     dx
    ret

/* spin_latch: bounded wait for the request latched. CF set = timeout. On
 * success `latched` holds the IRR byte that showed the bit. */
spin_latch:
    push    ax
    push    bp
    push    cx
    mov     bp, 0x0040
sl_outer:
    mov     cx, 0xFFFF
sl_inner:
    call    pic_irr_tgt
    test    al, [tgt_bit]
    jnz     sl_hit
    loop    sl_inner
    dec     bp
    jnz     sl_outer
    stc
    jmp     sl_done
sl_hit:
    mov     [latched], al
    clc
sl_done:
    pop     cx
    pop     bp
    pop     ax
    ret

/* put_row: the shared one-line result row. */
put_row:
    push    ax
    push    dx
    mov     dx, offset msg_f_trig
    call    puts
    mov     al, [trig_ok]
    call    puthex8
    mov     dx, offset msg_f_irr
    call    puts
    mov     al, [latched]
    call    puthex8
    mov     dx, offset msg_f_post
    call    puts
    mov     al, [post_irr]
    call    puthex8
    call    putnl
    pop     dx
    pop     ax
    ret

/* ==================================================================
 * small device helpers
 * ================================================================== */
/* ata_settle: a short settle after an ATA register write. */
ata_settle:
    push    ax
    push    cx
    push    dx
    mov     cx, 20
asl_loop:
    mov     dx, 0x0060
    in      al, dx
    loop    asl_loop
    pop     dx
    pop     cx
    pop     ax
    ret

/* ==================================================================
 * output helpers
 * ================================================================== */
putc:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     ah, 0x02
    int     0x21
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

puts:
    push    ax
    push    dx
    mov     ah, 0x09
    int     0x21
    pop     dx
    pop     ax
    ret

/* puts_bios: DX = '$'-terminated string, printed to the SCREEN via INT 10h
 * AH=0Eh (so a redirected stdout still shows the prompt). */
puts_bios:
    push    ax
    push    bx
    push    si
    mov     si, dx
pb_loop:
    mov     al, [si]
    cmp     al, '$'
    je      pb_done
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    inc     si
    jmp     pb_loop
pb_done:
    pop     si
    pop     bx
    pop     ax
    ret

putnl:
    push    dx
    mov     dl, 0x0D
    call    putc
    mov     dl, 0x0A
    call    putc
    pop     dx
    ret

puthex8:
    push    ax
    push    cx
    mov     cl, al
    shr     al, 4
    call    puthexdig
    mov     al, cl
    and     al, 0x0F
    call    puthexdig
    pop     cx
    pop     ax
    ret

puthexdig:
    and     al, 0x0F
    cmp     al, 10
    jb      phd_num
    add     al, 'A' - 10
    jmp     phd_out
phd_num:
    add     al, '0'
phd_out:
    mov     dl, al
    call    putc
    ret

putdec16:                       /* AX */
    push    ax
    push    bx
    push    cx
    push    dx
    mov     bx, 10
    xor     cx, cx
pd_div:
    xor     dx, dx
    div     bx
    push    dx
    inc     cx
    test    ax, ax
    jnz     pd_div
pd_out:
    pop     dx
    add     dl, '0'
    call    putc
    loop    pd_out
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ==================================================================
 * strings and variables
 * ================================================================== */
msg_banner:
    .ascii "IRQWD - PC-9821 masked-ack / request-withdraw probe\r\n"
    .ascii "  Per line: mask it, trigger a request, poll the IRR until it latches,\r\n"
    .ascii "  do the acking access, read the IRR again. postack_irr bit SET = the\r\n"
    .ascii "  machine HOLDS the request (edge latch); bit CLEAR = it WITHDRAWS it.\r\n"
    .ascii "  Nothing is delivered and no vector is touched. IRQ0's row is the\r\n"
    .ascii "  1->0 transition count on the master IRR while masked (the STEELGUN\r\n"
    .ascii "  idiom); PITOUT is its control (the PIT ch0 OUT pin, read back).\r\n$"

msg_begin_state: .ascii "BEGIN:STATE\r\n$"
msg_state_m:     .ascii "  master IMR IRR ISR = $"
msg_state_s:     .ascii "  slave  IMR IRR ISR = $"
msg_end_state:   .ascii "END:STATE\r\n$"

msg_begin_pitout: .ascii "BEGIN:PITOUT\r\n$"
msg_pitout_row:   .ascii "  PITOUT ch0_status lo hi falls rises = $"
msg_end_pitout:
    .ascii "END:PITOUT\r\n"
    .ascii "  falls/rises > 0 = the PIT channel-0 OUT pin is toggling, so the\r\n"
    .ascii "  IRQ0 row below is interpretable. Static OUT = the timer was not\r\n"
    .ascii "  running and the IRQ0 row is void. ch0_status bit7 is the OUT pin\r\n"
    .ascii "  and bits3:1 are the mode (3 = square wave).\r\n$"

msg_begin_irq0:  .ascii "BEGIN:IRQ0\r\n$"
msg_irq0_row:    .ascii "  IRQ0 masked poll ch0_status lo hi falls rises = $"
msg_end_irq0:
    .ascii "END:IRQ0\r\n"
    .ascii "  falls>0 = the machine clears the masked IRQ0 request as the PIT runs;\r\n"
    .ascii "  falls=0 with PITOUT toggling = the request latches and is HELD.\r\n$"

msg_begin_pitch0: .ascii "BEGIN:PITCH0\r\n$"
msg_pitch0_row:   .ascii "  PITCH0 IRR before ch0-write after = $"
msg_end_pitch0:
    .ascii "END:PITCH0\r\n"
    .ascii "  before bit0 set and after bit0 clear = a PIT channel-0 control write\r\n"
    .ascii "  withdraws the request (NP2kai io/pit.c:378/471); after bit0 still set\r\n"
    .ascii "  = it does not.\r\n$"

msg_begin_irq1:  .ascii "BEGIN:IRQ1\r\n$"
msg_irq1_prompt:  .ascii "  IRQ1: press a key now (bounded wait)...\r\n$"
msg_row1:         .ascii "  IRQ1  keyboard 0x41 ack$"
msg_end_irq1:     .ascii "END:IRQ1\r\n$"

msg_begin_irq9:  .ascii "BEGIN:IRQ9\r\n$"
msg_row9:         .ascii "  IRQ9  IDE 0x64E ack$"
msg_end_irq9:     .ascii "END:IRQ9\r\n$"

msg_begin_irq12: .ascii "BEGIN:IRQ12\r\n$"
msg_row12:        .ascii "  IRQ12 OPNA reg 0x27 ack$"
msg_end_irq12:    .ascii "END:IRQ12\r\n$"

msg_begin_irq15: .ascii "BEGIN:IRQ15\r\n$"
msg_row15:        .ascii "  IRQ15 calendar 0x128 ack$"
msg_end_irq15:    .ascii "END:IRQ15\r\n$"

msg_f_trig:   .ascii " trig=$"
msg_f_irr:    .ascii " latch_irr=$"
msg_f_post:   .ascii " postack_irr=$"

msg_begin_verdict: .ascii "BEGIN:VERDICT\r\n$"
msg_v_pitout: .ascii "  PITOUT falls/rises=$"
msg_v_irq0:   .ascii "  IRQ0 falls/rises=$"
msg_v_pitch0: .ascii "  PITCH0 before/after bit0=$"
msg_end_verdict:
    .ascii "END:VERDICT\r\n"
    .ascii "  Decode: PITOUT falls/rises>0 -> the PIT toggles. IRQ0 falls>0 -> the\r\n"
    .ascii "  machine clears the masked timer (adopt the timer clear); falls=0 with\r\n"
    .ascii "  PITOUT toggling -> HOLD. PITCH0 after=0 -> clear. IRQ1/9/12/15: the\r\n"
    .ascii "  postack_irr bit set -> HOLD, clear -> WITHDRAW.\r\n$"

msg_begin_restore: .ascii "BEGIN:RESTORE\r\n$"
msg_restore_m:     .ascii "  master IMR as-found $"
msg_restore_s:     .ascii "  slave  IMR as-found $"
msg_arrow:         .ascii " -> now $"
msg_end_restore:
    .ascii "END:RESTORE\r\n"
    .ascii "  No interrupt vector was written. The OPNA timers are left stopped\r\n"
    .ascii "  with both flags cleared. The PIT was never reprogrammed.\r\n$"

msg_done: .ascii "END:IRQWD\r\n$"

/* ---- variables ---- */
m_imr_found:  .byte 0
s_imr_found:  .byte 0
m_irr_found:  .byte 0
m_isr_found:  .byte 0
s_irr_found:  .byte 0
s_isr_found:  .byte 0

m_imr_save:   .byte 0
s_imr_save:   .byte 0
bank_save:    .byte 0

tgt_port:     .word 0
tgt_bit:      .byte 0
tgt_m_imr:    .byte 0
tgt_s_imr:    .byte 0

trig_ok:      .byte 0
latched:      .byte 0
post_irr:     .byte 0

pit_stat:     .byte 0
pit_cl:       .byte 0
pit_ch:       .byte 0
pit_reprog:   .byte 0
p0_pre:       .byte 0
p0_post:      .byte 0
ata_st:       .byte 0
cal_rate:     .byte 0

n_lo:         .word 0
n_hi:         .word 0
n_fall:       .word 0
n_rise:       .word 0

out_lo:       .word 0
out_hi:       .word 0
out_fall:     .word 0
out_rise:     .word 0

drain_buf:    .space 512

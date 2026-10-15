/* d8bank.s - what the 0xD8000-0xDFFFF window holds for each I/O 0x063C bank select.
 *
 * THE QUESTION. Port 0x063C bits 1-0 bank the 0xD8000 ROM window on the PC-9821
 * (published PC-9821 memory-map notes: 01 = IDE BIOS, 10 = PCI/PnP BIOS,
 * 11 = C-bus PnP config, 00 = unknown; NP2kai io/pcidev.c pci_o063c swaps a second 32 KiB
 * image in for 01 instead). The core did not bank the window at all. MS-DOS 6.2's
 * EMM386 calls INT 1Fh AH=CEh during its initialisation; the Xe10 BIOS (FD80:0200 ->
 * F560:000C -> F560:00C3) answers it by writing 0x063C = (read & 0xFD) | 0x01 and far
 * returning into D800:0018. On the core that address is the IDE ROM's INT 1Bh entry, so
 * the call corrupted the stack and the boot hung (since fixed). This probe records what
 * the real machine maps there.
 *
 * METHOD. For SEL = 0, 1, 2, 3: CLI, read 0x063C, write (read & 0xFC) | SEL, read 0x063C
 * back, copy 0xD8000-0xDFFFF (32 KiB) into a DOS-allocated buffer, restore 0x063C, STI.
 * Then print the before/after port values, the first 32 bytes and a 16-bit byte sum, and
 * write the 32 KiB to D8BANKn.BIN. Interrupts are off only while the window is switched,
 * so no disk BIOS call can run against the wrong bank. Nothing else is written.
 *
 * Build: make -C tools/hwprobe d8bank/d8bank.com
 * Run:   D8BANK > D8BANK.TXT      (writes D8BANK0.BIN .. D8BANK3.BIN in the current dir)
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    /* Shrink our block to 64 KiB, then allocate the 32 KiB buffer. */
    mov     bx, 0x1000
    mov     ah, 0x4A
    int     0x21
    jc      no_mem
    mov     bx, 0x0800
    mov     ah, 0x48
    int     0x21
    jc      no_mem
    mov     [bufseg], ax

    mov     dx, offset s_banner
    call    puts
    mov     dx, 0x063C
    in      al, dx
    mov     [p63c_start], al
    mov     dx, 0x063D
    in      al, dx
    mov     [p63d_start], al
    mov     dx, offset s_start
    call    puts
    mov     al, [p63c_start]
    call    puthex8
    mov     dx, offset s_63d
    call    puts
    mov     al, [p63d_start]
    call    puthex8
    call    putnl

    mov     byte ptr [sel], 0
sel_loop:
    /* ---- the switched window: interrupts off ---- */
    cli
    mov     dx, 0x063C
    in      al, dx
    mov     [p_before], al
    and     al, 0xFC
    or      al, [sel]
    out     dx, al
    jmp     1f
1:  in      al, dx
    mov     [p_after], al
    push    ds
    mov     es, [bufseg]
    mov     ax, 0xD800
    mov     ds, ax
    xor     si, si
    xor     di, di
    mov     cx, 0x4000
    cld
    rep     movsw
    pop     ds
    mov     dx, 0x063C
    mov     al, [p_before]
    out     dx, al
    sti
    /* ---- report ---- */
    mov     dx, offset s_sel
    call    puts
    mov     al, [sel]
    call    puthexdig
    mov     dx, offset s_before
    call    puts
    mov     al, [p_before]
    call    puthex8
    mov     dx, offset s_after
    call    puts
    mov     al, [p_after]
    call    puthex8
    mov     dx, offset s_sum
    call    puts
    push    ds
    mov     ds, [cs:bufseg]
    xor     si, si
    xor     bx, bx
    mov     cx, 0x8000
    xor     ah, ah
2:  lodsb
    add     bx, ax
    loop    2b
    pop     ds
    mov     ax, bx
    xchg    al, ah
    call    puthex8
    mov     al, bl
    call    puthex8
    call    putnl
    /* first 32 bytes, two rows */
    xor     si, si
3:  mov     dx, offset s_row
    call    puts
    mov     ax, si
    xchg    al, ah
    call    puthex8
    mov     ax, si
    call    puthex8
    mov     dl, ':'
    call    putc
    mov     cx, 16
4:  mov     dl, ' '
    call    putc
    push    ds
    mov     ds, [cs:bufseg]
    lodsb
    pop     ds
    call    puthex8
    loop    4b
    call    putnl
    cmp     si, 32
    jb      3b
    /* the 32 KiB image to D8BANKn.BIN */
    mov     al, [sel]
    add     al, '0'
    mov     [fname_digit], al
    mov     dx, offset fname
    xor     cx, cx
    mov     ah, 0x3C
    int     0x21
    jc      file_err
    mov     bx, ax
    push    ds
    mov     ds, [cs:bufseg]
    xor     dx, dx
    mov     cx, 0x8000
    mov     ah, 0x40
    int     0x21
    pop     ds
    jc      file_err
    mov     ah, 0x3E
    int     0x21
    jmp     5f
file_err:
    mov     dx, offset s_ferr
    call    puts
5:  inc     byte ptr [sel]
    cmp     byte ptr [sel], 4
    jb      sel_loop

    mov     dx, 0x063C
    in      al, dx
    mov     [p_before], al
    mov     dx, offset s_end
    call    puts
    mov     al, [p_before]
    call    puthex8
    call    putnl
    mov     ax, 0x4C00
    int     0x21

no_mem:
    mov     dx, offset s_nomem
    call    puts
    mov     ax, 0x4C01
    int     0x21

putc:                           /* DL = character */
    push    ax
    mov     ah, 0x02
    int     0x21
    pop     ax
    ret
puts:                           /* DX = '$'-terminated string */
    push    ax
    mov     ah, 0x09
    int     0x21
    pop     ax
    ret
putnl:
    push    dx
    mov     dl, 13
    call    putc
    mov     dl, 10
    call    putc
    pop     dx
    ret
puthexdig:                      /* AL = 0..15 */
    push    ax
    push    dx
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     6f
    add     al, 7
6:  mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret
puthex8:                        /* AL */
    push    ax
    push    ax
    shr     al, 4
    call    puthexdig
    pop     ax
    call    puthexdig
    pop     ax
    ret

s_banner:   .ascii "D8BANK 0xD8000 window per I/O 0x063C bank select (tools/hwprobe/d8bank)\r\n$"
s_start:    .ascii "START 063C=$"
s_63d:      .ascii " 063D=$"
s_sel:      .ascii "SEL $"
s_before:   .ascii " 063C before=$"
s_after:    .ascii " after-write=$"
s_sum:      .ascii " sum=$"
s_row:      .ascii "  D800:$"
s_end:      .ascii "END 063C=$"
s_ferr:     .ascii "  FILE WRITE FAILED\r\n$"
s_nomem:    .ascii "D8BANK: cannot allocate the 32 KiB buffer\r\n$"
fname:      .ascii "D8BANK"
fname_digit: .ascii "0.BIN"
            .byte 0
bufseg:     .word 0
sel:        .byte 0
p_before:   .byte 0
p_after:    .byte 0
p63c_start: .byte 0
p63d_start: .byte 0

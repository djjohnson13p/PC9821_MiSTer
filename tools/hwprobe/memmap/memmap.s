/* memmap.s - what the machine says about its own memory, as DOS and an extender see it.
 *
 * WHY. DOOM (DOS/4GW) died on the core with a not-present page fault at linear 0x00A57A64
 * (since fixed in the CPU's TLB). The published memory maps, NP2kai and MAME agree that
 * 1-15 MiB is plain RAM in every reference, so
 * the open questions are about what the memory-size chain TELLS the extender and about the
 * 15-16 MiB system space - and only the real machine can answer them. Run the SAME binary
 * on the Xe10 and on the core, in the SAME boot configuration (DOOM's own CONFIG.SYS, and
 * a clean boot with no memory manager), and diff the two captures.
 *
 *   SEC MODE   SMSW (PE = V86 under EMM386), and the whole CR0 when PE is clear - CD/NW
 *              say whether the firmware left the caches on (the re-vendored CPU honours them).
 *   SEC BDA    0000:0400-05FF hex dump, plus 0x0401 (extended memory, 128 KiB units, 1-16 MiB)
 *              and the 0x0594 word (MiB above 16 MiB), named.
 *   SEC PORTS  reads of 0x043B (15-16 MiB system space), 0x0461/0x0463 (memory windows),
 *              0x063F (cache control) - READS ONLY.
 *   SEC XMS    INT 2Fh 4300h/4310h; XMS 00h (version), 08h (free KiB), 88h (free KiB, and
 *              ECX = the highest ending address of any memory block - the top the XMS
 *              driver believes in).
 *   SEC EMS    INT 67h device name; 42h (pages); VCPI DE00h, DE02h (EDX = physical address of
 *              the HIGHEST page - the top VCPI believes in), DE03h (free 4 KiB pages).
 *   SEC DPMI   INT 2Fh 1687h.
 *   SEC PHYS   only when PE is clear (no V86 monitor): unreal mode (FS with a 4 GiB limit).
 *              P1 the A20 state as found (a marker in this program compared with its +1 MiB
 *                 image), then A20 on (out 0xF2) for the section.
 *              P2 READS of the 15-16 MiB system space and its claimed mirrors: 0xF00000,
 *                 0xF7FFFC, 0xF80000, 0xF9FFFC, 0xFA0000 vs 0x0A0000, 0xFE8000 vs 0x0E8000,
 *                 0xFFFFF0 vs 0x0FFFF0, 0xFFF00000, 0xFFF7FFFC, 0xFFFFFFF0 vs 0x0FFFF0.
 *              P3 (WRITES; only with NO XMS driver) the hole test: 0xF80000 is read, written
 *                 with its complement, read back, and restored - RAM keeps the write, the hole
 *                 does not.
 *              P4 (WRITES; only with NO XMS driver) the RAM-top / alias scan: the dword at
 *                 N MiB + 0x100 for N = 1..127 is saved, then each is written with a
 *                 signature 0x5A5A0000+N in ascending order, then all are read back and
 *                 restored. A location that reads its own signature is distinct storage; one
 *                 that reads another N's signature ALIASES it; 0xFFFFFFFF is open bus.
 *              A20 is put back as found.
 *
 * SAFETY.
 *   - Under EMM386 (PE set) nothing privileged runs: SEC PHYS is skipped and says so.
 *   - The P3/P4 writes run only when no XMS driver is resident, because with HIMEM loaded
 *     extended memory may hold someone's data (a RAM disk, a disk cache, DOS=HIGH). Every
 *     written dword is saved first and restored, and the capture prints both.
 *   - Port 0x0461/0x0463/0x063F are only READ. The one port written is 0xF2/0xF6 (A20), put
 *     back as found.
 *   - Sections are BEGIN:/END: pairs, so a hang leaves a BEGIN with no END.
 *
 * Build: make -C tools/hwprobe memmap/memmap.com   (GNU as --32, linked at 0x100)
 * Run:   MEMMAP > MEMMAP.TXT   (memmap/RUNMEM.BAT; once in DOOM's boot config, once clean)
 */
    .code16
    .intel_syntax noprefix
    .section .text
    .global _start

_start:
    cld
    push    cs
    pop     ds
    push    cs
    pop     es
    mov     dx, offset msg_banner
    call    puts

    call    sec_mode
    call    sec_bda
    call    sec_ports
    call    sec_xms
    call    sec_ems
    call    sec_dpmi
    call    sec_phys

    mov     dx, offset msg_done
    call    puts
    mov     ax, 0x4C00
    int     0x21

/* ==================================================================
 * SEC MODE
 * ================================================================== */
sec_mode:
    mov     dx, offset msg_b_mode
    call    puts
    smsw    ax
    mov     [msw], ax
    mov     dx, offset msg_msw
    call    puts
    call    puthex16
    call    putnl
    test    byte ptr [msw], 1
    jz      1f
    mov     dx, offset msg_v86
    call    puts
    jmp     2f
1:  mov     eax, cr0
    mov     [cr0v], eax
    mov     dx, offset msg_cr0
    call    puts
    mov     eax, [cr0v]
    call    puthex32
    mov     dx, offset msg_cd
    call    puts
    mov     eax, [cr0v]
    shr     eax, 30
    and     al, 1
    call    puthexdig
    mov     dx, offset msg_nw
    call    puts
    mov     eax, [cr0v]
    shr     eax, 29
    and     al, 1
    call    puthexdig
    call    putnl
2:  mov     dx, offset msg_e_mode
    call    puts
    ret

/* ==================================================================
 * SEC BDA: 0000:0400-05FF
 * ================================================================== */
sec_bda:
    mov     dx, offset msg_b_bda
    call    puts
    push    es
    xor     ax, ax
    mov     es, ax
    mov     dx, offset msg_0401
    call    puts
    mov     al, es:[0x0401]
    call    puthex8
    mov     dx, offset msg_0594
    call    puts
    mov     ax, es:[0x0594]
    call    puthex16
    call    putnl
    mov     si, 0x0400
3:  mov     dx, offset msg_row
    call    puts
    mov     ax, si
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     cx, 16
4:  call    putsp
    mov     al, es:[si]
    call    puthex8
    inc     si
    loop    4b
    call    putnl
    cmp     si, 0x0600
    jb      3b
    pop     es
    mov     dx, offset msg_e_bda
    call    puts
    ret

/* ==================================================================
 * SEC PORTS: reads only
 * ================================================================== */
sec_ports:
    mov     dx, offset msg_b_ports
    call    puts
    mov     si, offset tbl_ports
5:  mov     dx, [si]
    or      dx, dx
    jz      6f
    push    dx
    mov     dx, offset msg_port
    call    puts
    pop     dx
    call    putport_only
    in      al, dx
    call    puthex8_eq
    call    putnl
    add     si, 2
    jmp     5b
6:  mov     dx, offset msg_e_ports
    call    puts
    ret

/* ==================================================================
 * SEC XMS
 * ================================================================== */
sec_xms:
    mov     dx, offset msg_b_xms
    call    puts
    mov     ax, 0x4300
    int     0x2F
    cmp     al, 0x80
    je      7f
    mov     dx, offset msg_none
    call    puts
    jmp     9f
7:  mov     byte ptr [have_xms], 1
    push    es
    mov     ax, 0x4310
    int     0x2F
    mov     [xms_entry], bx
    mov     [xms_entry+2], es
    pop     es
    /* 00h: version */
    mov     ah, 0x00
    call    DWORD PTR [xms_entry]
    push    bx
    mov     dx, offset msg_xver
    call    puts
    call    puthex16
    mov     dx, offset msg_xrev
    call    puts
    pop     ax
    call    puthex16
    call    putnl
    /* 08h: free KiB (AX largest, DX total) */
    mov     ah, 0x08
    xor     bl, bl
    call    DWORD PTR [xms_entry]
    push    dx
    mov     dx, offset msg_x08
    call    puts
    call    puthex16
    mov     dx, offset msg_total
    call    puts
    pop     ax
    call    puthex16
    mov     dx, offset msg_bl
    call    puts
    mov     al, bl
    call    puthex8
    call    putnl
    /* 88h: XMS 3 query - EAX largest, ECX highest ending address, EDX total */
    mov     ah, 0x88
    xor     bl, bl
    call    DWORD PTR [xms_entry]
    mov     [q_eax], eax
    mov     [q_ecx], ecx
    mov     [q_edx], edx
    mov     [q_bl], bl
    mov     dx, offset msg_x88
    call    puts
    mov     eax, [q_eax]
    call    puthex32
    mov     dx, offset msg_top
    call    puts
    mov     eax, [q_ecx]
    call    puthex32
    mov     dx, offset msg_total
    call    puts
    mov     eax, [q_edx]
    call    puthex32
    mov     dx, offset msg_bl
    call    puts
    mov     al, [q_bl]
    call    puthex8
    call    putnl
9:  mov     dx, offset msg_e_xms
    call    puts
    ret

/* ==================================================================
 * SEC EMS / VCPI
 * ================================================================== */
sec_ems:
    mov     dx, offset msg_b_ems
    call    puts
    push    es
    mov     ax, 0x3567
    int     0x21                /* ES:BX = INT 67h vector */
    mov     di, 0x000A
    mov     si, offset name_emm
    mov     cx, 8
    repe    cmpsb
    je      10f
    mov     di, 0x000A
    mov     si, offset name_emmq
    mov     cx, 8
    repe    cmpsb
    je      10f
    pop     es
    mov     dx, offset msg_none
    call    puts
    jmp     12f
10: pop     es
    mov     ah, 0x42
    int     0x67
    push    dx
    push    bx
    push    ax
    mov     dx, offset msg_e42
    call    puts
    pop     ax
    mov     al, ah
    call    puthex8
    mov     dx, offset msg_free
    call    puts
    pop     ax
    call    puthex16
    mov     dx, offset msg_total
    call    puts
    pop     ax
    call    puthex16
    call    putnl
    /* VCPI */
    mov     ax, 0xDE00
    int     0x67
    mov     [q_bl], ah
    push    bx
    push    ax
    mov     dx, offset msg_vcpi
    call    puts
    pop     ax
    mov     al, ah
    call    puthex8
    mov     dx, offset msg_ver
    call    puts
    pop     ax
    call    puthex16
    call    putnl
    cmp     byte ptr [q_bl], 0
    jne     12f
    mov     ax, 0xDE02
    int     0x67
    mov     [q_edx], edx
    mov     [q_bl], ah
    mov     dx, offset msg_de02
    call    puts
    mov     al, [q_bl]
    call    puthex8
    mov     dx, offset msg_top
    call    puts
    mov     eax, [q_edx]
    call    puthex32
    call    putnl
    mov     ax, 0xDE03
    int     0x67
    mov     [q_edx], edx
    mov     [q_bl], ah
    mov     dx, offset msg_de03
    call    puts
    mov     al, [q_bl]
    call    puthex8
    mov     dx, offset msg_free
    call    puts
    mov     eax, [q_edx]
    call    puthex32
    call    putnl
12: mov     dx, offset msg_e_ems
    call    puts
    ret

/* ==================================================================
 * SEC DPMI
 * ================================================================== */
sec_dpmi:
    mov     dx, offset msg_b_dpmi
    call    puts
    push    es
    mov     ax, 0x1687
    int     0x2F
    pop     es
    push    dx
    push    bx
    push    ax
    mov     dx, offset msg_d1687
    call    puts
    pop     ax
    call    puthex16
    mov     dx, offset msg_flags
    call    puts
    pop     ax
    call    puthex16
    mov     dx, offset msg_ver
    call    puts
    pop     ax
    call    puthex16
    call    putnl
    mov     dx, offset msg_e_dpmi
    call    puts
    ret

/* ==================================================================
 * SEC PHYS: unreal mode, real mode only
 * ================================================================== */
sec_phys:
    mov     dx, offset msg_b_phys
    call    puts
    test    byte ptr [msw], 1
    jz      13f
    mov     dx, offset msg_skip_v86
    call    puts
    jmp     19f
13: call    unreal_fs

    /* P1: the A20 state as found. The marker is this program's own byte; with A20 off
     * its +1 MiB image IS it, so flipping it moves both. */
    xor     eax, eax
    mov     ax, cs
    shl     eax, 4
    add     eax, offset a20_mark
    mov     [mark_lin], eax
    call    a20_wraps
    mov     [a20_found_off], al
    mov     dx, offset msg_a20
    call    puts
    mov     al, [a20_found_off]
    call    puthexdig
    call    putnl
    mov     al, 0
    out     0xF2, al            /* A20 on */
    call    a20_wraps
    push    ax
    mov     dx, offset msg_a20on
    call    puts
    pop     ax
    call    puthexdig
    call    putnl

    /* P2: reads */
    mov     si, offset tbl_reads
14: mov     eax, [si]
    cmp     eax, 0xFFFFFFFF
    je      15f
    call    read_pair
    add     si, 8
    jmp     14b

15: cmp     byte ptr [have_xms], 0
    je      16f
    mov     dx, offset msg_skip_xms
    call    puts
    jmp     18f

    /* P3: the hole test at 0xF80000 */
16: mov     dx, offset msg_p3
    call    puts
    mov     esi, 0x00F80000
    cli
    mov     eax, fs:[esi]
    mov     [p_before], eax
    not     eax
    mov     [p_wrote], eax
    mov     fs:[esi], eax
    mov     eax, fs:[esi]
    mov     [p_back], eax
    mov     eax, [p_before]
    mov     fs:[esi], eax
    mov     eax, fs:[esi]
    mov     [p_rest], eax
    sti
    call    print_p

    /* P4: the RAM-top / alias scan, N = 1..127 */
    mov     dx, offset msg_p4
    call    puts
    cli
    mov     cx, 1
17: call    scan_addr           /* ESI = N MiB + 0x100 */
    mov     eax, fs:[esi]
    mov     bx, cx
    shl     bx, 2
    mov     [scan_save+bx], eax
    inc     cx
    cmp     cx, 128
    jb      17b
    mov     cx, 1
171:call    scan_addr
    mov     eax, 0x5A5A0000
    mov     ax, cx
    mov     fs:[esi], eax
    inc     cx
    cmp     cx, 128
    jb      171b
    mov     cx, 1
172:call    scan_addr
    mov     eax, fs:[esi]
    mov     bx, cx
    shl     bx, 2
    mov     [scan_seen+bx], eax
    inc     cx
    cmp     cx, 128
    jb      172b
    /* restore in DESCENDING order, so an aliased pair ends holding the LOWER address's
     * original (the one that was really there before the scan's first write to it) */
    mov     cx, 127
173:call    scan_addr
    mov     bx, cx
    shl     bx, 2
    mov     eax, [scan_save+bx]
    mov     fs:[esi], eax
    dec     cx
    jnz     173b
    sti
    mov     cx, 1
174:mov     dx, offset msg_scan
    call    puts
    mov     ax, cx
    call    puthex8
    mov     dx, offset msg_saved
    call    puts
    mov     bx, cx
    shl     bx, 2
    mov     eax, [scan_save+bx]
    call    puthex32
    mov     dx, offset msg_seen
    call    puts
    mov     eax, [scan_seen+bx]
    call    puthex32
    call    putnl
    inc     cx
    cmp     cx, 128
    jb      174b

    /* A20 back as found */
18: cmp     byte ptr [a20_found_off], 0
    je      181f
    mov     al, 0x03
    out     0xF6, al            /* A20 off */
181:call    a20_wraps
    push    ax
    mov     dx, offset msg_a20end
    call    puts
    pop     ax
    call    puthexdig
    call    putnl
19: mov     dx, offset msg_e_phys
    call    puts
    ret

/* ESI = CX MiB + 0x100 */
scan_addr:
    movzx   esi, cx
    shl     esi, 20
    add     esi, 0x100
    ret

/* AL = 1 when phys mark_lin and mark_lin + 1 MiB are the same storage (A20 off). */
a20_wraps:
    push    esi
    push    edi
    mov     esi, [mark_lin]
    mov     edi, esi
    add     edi, 0x00100000
    cli
    mov     bl, fs:[esi]
    mov     bh, fs:[edi]
    xor     byte ptr fs:[esi], 0xFF
    mov     al, fs:[edi]
    mov     fs:[esi], bl
    sti
    cmp     al, bh
    mov     al, 0
    je      1f
    mov     al, 1               /* the +1 MiB image followed the flip: one storage */
1:  pop     edi
    pop     esi
    ret

/* SI -> {addr, ref}; prints "  RD aaaaaaaa=vvvvvvvv" and, with a ref, " REF rrrrrrrr=vvvvvvvv SAME|DIFF" */
read_pair:
    push    si
    mov     eax, [si]
    mov     [p_addr], eax
    mov     eax, [si+4]
    mov     [p_ref], eax
    mov     esi, [p_addr]
    cli
    mov     eax, fs:[esi]
    mov     [p_before], eax
    mov     esi, [p_ref]
    or      esi, esi
    jz      1f
    mov     eax, fs:[esi]
    mov     [p_back], eax
1:  sti
    mov     dx, offset msg_rd
    call    puts
    mov     eax, [p_addr]
    call    puthex32
    mov     dl, '='
    call    putc
    mov     eax, [p_before]
    call    puthex32
    cmp     dword ptr [p_ref], 0
    je      3f
    mov     dx, offset msg_ref
    call    puts
    mov     eax, [p_ref]
    call    puthex32
    mov     dl, '='
    call    putc
    mov     eax, [p_back]
    call    puthex32
    mov     eax, [p_before]
    cmp     eax, [p_back]
    mov     dx, offset msg_same
    je      2f
    mov     dx, offset msg_diff
2:  call    puts
3:  call    putnl
    pop     si
    ret

print_p:
    mov     dx, offset msg_before
    call    puts
    mov     eax, [p_before]
    call    puthex32
    mov     dx, offset msg_wrote
    call    puts
    mov     eax, [p_wrote]
    call    puthex32
    mov     dx, offset msg_back
    call    puts
    mov     eax, [p_back]
    call    puthex32
    mov     dx, offset msg_rest
    call    puts
    mov     eax, [p_rest]
    call    puthex32
    call    putnl
    ret

/* Load FS with a 4 GiB-limit flat descriptor, then return to real mode: FS keeps the limit. */
unreal_fs:
    xor     eax, eax
    mov     ax, cs
    shl     eax, 4
    add     eax, offset gdt
    mov     [gdtr+2], eax
    cli
    lgdt    [gdtr]
    mov     eax, cr0
    or      al, 1
    mov     cr0, eax
    jmp     1f
1:  mov     bx, 8
    mov     fs, bx
    and     al, 0xFE
    mov     cr0, eax
    jmp     2f
2:  xor     ax, ax
    mov     fs, ax
    sti
    ret

/* ==================================================================
 * Helpers
 * ================================================================== */
putc:                           /* DL = character */
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

puts:                           /* DX = '$'-terminated string */
    push    ax
    push    dx
    mov     ah, 0x09
    int     0x21
    pop     dx
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

putsp:
    push    dx
    mov     dl, ' '
    call    putc
    pop     dx
    ret

puthex32:                       /* EAX */
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
    call    puthex16
    ret

puthex16:                       /* AX */
    push    ax
    xchg    al, ah
    call    puthex8
    xchg    al, ah
    call    puthex8
    pop     ax
    ret

puthex8:                        /* AL */
    push    ax
    push    ax
    shr     al, 4
    call    puthexdig
    pop     ax
    and     al, 0x0F
    call    puthexdig
    pop     ax
    ret

puthex8_eq:                     /* AL, printed as "=HH" */
    push    dx
    push    ax
    mov     dl, '='
    call    putc
    pop     ax
    call    puthex8
    pop     dx
    ret

puthexdig:                      /* AL = 0..15 */
    push    ax
    push    dx
    and     al, 0x0F
    cmp     al, 10
    jb      1f
    add     al, 'A' - 10
    jmp     2f
1:  add     al, '0'
2:  mov     dl, al
    call    putc
    pop     dx
    pop     ax
    ret

putport_only:                   /* DX = port, printed as "PPPP" */
    push    ax
    mov     ax, dx
    call    puthex16
    pop     ax
    ret

/* ==================================================================
 * Strings ('$'-terminated, CRLF for DOS)
 * ================================================================== */
msg_banner:   .ascii "MEMMAP 1 - the memory map as DOS and an extender see it\r\n$"
msg_done:     .ascii "MEMMAP DONE\r\n$"
msg_b_mode:   .ascii "BEGIN:MODE\r\n$"
msg_e_mode:   .ascii "END:MODE\r\n$"
msg_msw:      .ascii "  MSW=$"
msg_v86:      .ascii "  PE=1 (V86 monitor resident): CR0 not read\r\n$"
msg_cr0:      .ascii "  CR0=$"
msg_cd:       .ascii " CD=$"
msg_nw:       .ascii " NW=$"
msg_b_bda:    .ascii "BEGIN:BDA\r\n$"
msg_e_bda:    .ascii "END:BDA\r\n$"
msg_0401:     .ascii "  0401=$"
msg_0594:     .ascii " 0594w=$"
msg_row:      .ascii "  BDA $"
msg_b_ports:  .ascii "BEGIN:PORTS\r\n$"
msg_e_ports:  .ascii "END:PORTS\r\n$"
msg_port:     .ascii "  PORT $"
msg_b_xms:    .ascii "BEGIN:XMS\r\n$"
msg_e_xms:    .ascii "END:XMS\r\n$"
msg_none:     .ascii "  NONE\r\n$"
msg_xver:     .ascii "  X00 ver=$"
msg_xrev:     .ascii " rev=$"
msg_x08:      .ascii "  X08 largestKB=$"
msg_x88:      .ascii "  X88 largestKB=$"
msg_top:      .ascii " top=$"
msg_total:    .ascii " total=$"
msg_bl:       .ascii " BL=$"
msg_b_ems:    .ascii "BEGIN:EMS\r\n$"
msg_e_ems:    .ascii "END:EMS\r\n$"
msg_e42:      .ascii "  E42 AH=$"
msg_free:     .ascii " free=$"
msg_vcpi:     .ascii "  DE00 AH=$"
msg_ver:      .ascii " ver=$"
msg_de02:     .ascii "  DE02 AH=$"
msg_de03:     .ascii "  DE03 AH=$"
msg_b_dpmi:   .ascii "BEGIN:DPMI\r\n$"
msg_e_dpmi:   .ascii "END:DPMI\r\n$"
msg_d1687:    .ascii "  1687 AX=$"
msg_flags:    .ascii " BX=$"
msg_b_phys:   .ascii "BEGIN:PHYS\r\n$"
msg_e_phys:   .ascii "END:PHYS\r\n$"
msg_skip_v86: .ascii "  SKIPPED: PE=1 (V86) - boot without EMM386 to run this section\r\n$"
msg_skip_xms: .ascii "  P3/P4 SKIPPED: an XMS driver is resident - boot without HIMEM to run the write tests\r\n$"
msg_a20:      .ascii "  A20 found wrapping=$"
msg_a20on:    .ascii "  A20 after out F2 wrapping=$"
msg_a20end:   .ascii "  A20 restored wrapping=$"
msg_rd:       .ascii "  RD $"
msg_ref:      .ascii " REF $"
msg_same:     .ascii " SAME$"
msg_diff:     .ascii " DIFF$"
msg_p3:       .ascii "  P3 F80000$"
msg_p4:       .ascii "  P4 scan: N MiB + 0x100, saved / seen after writing 5A5A00NN ascending\r\n$"
msg_scan:     .ascii "  MB $"
msg_saved:    .ascii " saved=$"
msg_seen:     .ascii " seen=$"
msg_before:   .ascii " before=$"
msg_wrote:    .ascii " wrote=$"
msg_back:     .ascii " back=$"
msg_rest:     .ascii " restored=$"

name_emm:     .ascii "EMMXXXX0"
name_emmq:    .ascii "EMMQXXX0"

    .balign 2
tbl_ports:    .word 0x043B, 0x0461, 0x0463, 0x063F, 0
    .balign 4
tbl_reads:                      /* {addr, ref or 0} */
    .long 0x00F00000, 0
    .long 0x00F7FFFC, 0
    .long 0x00F80000, 0
    .long 0x00F9FFFC, 0
    .long 0x00FA0000, 0x000A0000
    .long 0x00FE8000, 0x000E8000
    .long 0x00FFFFF0, 0x000FFFF0
    .long 0xFFF00000, 0x00F00000
    .long 0xFFF7FFFC, 0x00F7FFFC
    .long 0xFFFFFFF0, 0x000FFFF0
    .long 0xFFFFFFFF

    .balign 8
gdt:          .quad 0
              .quad 0x00CF92000000FFFF   /* flat data, base 0, limit 4 GiB, writable */
gdtr:         .word 15
              .long 0

    .balign 4
xms_entry:    .long 0
cr0v:         .long 0
mark_lin:     .long 0
q_eax:        .long 0
q_ecx:        .long 0
q_edx:        .long 0
p_addr:       .long 0
p_ref:        .long 0
p_before:     .long 0
p_wrote:      .long 0
p_back:       .long 0
p_rest:       .long 0
scan_save:    .fill 128, 4, 0
scan_seen:    .fill 128, 4, 0
msw:          .word 0
q_bl:         .byte 0
have_xms:     .byte 0
a20_found_off:.byte 0
a20_mark:     .byte 0x3C

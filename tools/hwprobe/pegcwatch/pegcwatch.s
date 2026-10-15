/* pegcwatch.s - PEGCW.COM: a resident EXEC-wrapper that watches DOOM's own
 *
 * THE FILE IS PEGCW.COM, NOT PEGCWATCH.COM: DOS 8.3 allows eight characters for a filename stem
 * and "PEGCWATCH" is nine, so a DOS filesystem cannot hold that name - the probe could not be
 * copied to the machine at all until the makefile emitted the short one. Nothing else moved: the ROWS this program prints still begin
 * PEGCWATCH, and pegcwatch_decode.py parses those, not the filename.
 * video path and reports the PEGC state it left behind.
 *
 *   PEGCWATCH <program> [args]      e.g.  PEGCWATCH DOOM.EXE
 *                                         PEGCWATCH D:\GAMES\DOOM2\DOOM2.EXE
 *   PEGCWATCH                       no child: the CALIBRATION run - it prints
 *                                   the machine's PEGC state and one raw plane
 *                                   sample where 16-colour DOS left it, so the
 *                                   readback rows can be believed before they
 *                                   are used to answer anything.
 *   /NOP before the program name:   skip the plane-register sampling (the one
 *                                   part of this probe that reads through a
 *                                   window the child may be using).
 *
 * WHY THIS EXISTS. A census of the target games' files established that
 * DOOM and DOOM2 select a 9821-only video driver (`DEFAULT.CFG` ->
 * `video_driver "pc9821.drv"`, carried LZ-compressed inside `DRIVERS.ARK`) and
 * could not read a single byte of it, so the one question the feature
 * decision rests on - does that driver need ONLY PEGC's display half (packed
 * scanout + the 256-entry palette + the VRAM route, 41-51 LABs) or ALSO its
 * plane/dot engine (69-76 LABs total) - is invisible to every static instrument
 * on this disk. This probe measures it on the machine instead, which is the top
 * of the evidence hierarchy and needs no decompressor.
 *
 * WHAT IT MEASURES, AND WHY THOSE ADDRESSES.
 *
 * 1. THE 256-COLOUR MODE BIT. Port 0x9A0 is an INDEX/DATA query into the GDC's
 *    extension state: write the index, read the indexed bit (NP2kai io/gdc.c
 *    `gdc_o9a0`/`gdc_i9a0`; MAME `src/mame/nec/pc9821.cpp` `ext2_video_ff_r`/
 *    `ext2_video_ff_w`; this core models the same table in `pc9821_iobus.sv`'s
 *    `gdc_ff2_query`). Index 0x0A answers `gdc.analog` bit GDCANALOG_256 - the
 *    256-colour / PEGC-mode bit. It is the BIOS's OWN probe: the machine's
 *    firmware polls it to decide "256-colour machine" (this tree's
 *    the 0x09A0 row of `docs/probes/PROBE.TXT`,
 *    which measured `FF 9A0 after writing 0x0A: 00` - clear - at the 16-colour
 *    DOS prompt). Index 0x04 is mode2 bit 0 (the analog-16 select), 0x08 is
 *    mode2 bit 3 (the PEGC register write enable), 0x0D is GDCANALOG_256E and
 *    0x03 is mode1 bit 7 (DISP). So a run that leaves `A0A=01` entered PEGC
 *    256-colour and NEEDS THE DISPLAY HALF; a run that leaves `A0A=00` did not.
 *
 * 2. THE MODE FLIP-FLOP ITSELF. Port 0x6A is the extended-video mode f/f, and
 *    NP2kai's read handler (`gdc_i6a`) returns `gdc.mode2`; the machine's own
 *    capture reads 0x00 there in 16-colour text mode (the 0x006A column of the
 *    measured PORTS table). The 16-colour mode set writes `0x6A = 1`; the
 *    firmware's own PEGC mode set writes `0x6A = 0x07, 0x21, 0x06, 0x41` (the
 *    sequence decoded below), so a captured 0x6A of 0x21 is a second,
 *    independent witness of the same event - which matters because it is the
 *    value the DRIVER would have written if it drives the hardware itself
 *    rather than going through the BIOS.
 *
 * 3. THE BIOS'S OWN PEGC SERVICE, AND WHERE IT IS. The Xe10 dumps carry a
 *    complete 256-colour mode set as a far-callable routine:
 *      BANK6 (the 0xF0000-0xF7FFF window, bank 6 = the main BIOS's second half)
 *      0x7D24 `push es / mov ax,0 / mov es,ax / test es:0x45C,0x40` - it does
 *      nothing unless the 9821 flag and `es:0x597 & 3 == 2` hold - then `CH = 0`
 *      runs `0x6A = 0x07, 0x20, 0x06, 0x41` + work-byte 0x54D bit 7 clear (the
 *      DESELECT: 0x20 is the PEGC MMIO view off) and `CH = 1` runs `0x6A = 0x07,
 *      0x21, 0x06, 0x41` + `or es:0x54D,0x80` (the SELECT: 0x21 is the PEGC MMIO
 *      view on and the analog-256 mode bit, MAME's `pegc_mmio_view.select(0)`
 *      and NP2kai's `gdc_analogext(TRUE)`), then copies 0x54D bit 5.
 *      The byte-exact sequence is at BANK6 0x7D4F (enable) and 0x7D75 (disable).
 *      It is reached by a thin BANK7 stub at 0x491A (`call 0xF760:0x0724`), and
 *      the same writes appear inline at BANK6 0x6231 (enable) and 0x65B0
 *      (disable). **A static scan of all ten dump files finds NO caller of that
 *      stub**: it is the only `9A 24 07 60 F7` byte group in the set (BANK7
 *      0x491B), and no near call, jump or far pointer in BANK0-7 or BIOS.ROM
 *      targets 0x491A. So on this firmware the BIOS route to PEGC 256-colour is
 *      either dead or reached by a mechanism the dumps do not show - which is
 *      exactly why this probe watches the INT *and* the hardware, and treats
 *      "which INT/AH" as an OUTPUT of the run rather than an input to it.
 *    The BIOS graphics services themselves are INT 18h. Its AH>=0x40 handlers
 *    are the BANK7 far-call stubs at 0x4543-0x456C into the 0xF760 window, and
 *    the machine-verified set for a mode set is AH=0x41 (graphics display off),
 *    AH=0x42 (mode) and AH=0x40 (display on) with `out 0x6A,1` between them -
 *    `tools/hwprobe/probe2/probe2.s`'s `wp_modeset` documents and issues exactly
 *    that sequence, so this probe logs every INT 18h call rather than guessing
 *    at one AH.
 *
 * 4. THE PLANE ENGINE. Whether the driver merely WRITES PIXELS THROUGH THE
 *    WINDOW (the cheap half, and the half the core already has: the 0xF00000
 *    aperture is decoded into SDRAM, `tb_pc9821_pegvram`) or PROGRAMS THE PLANE
 *    ENGINE (the expensive half) is a question about two disjoint address
 *    ranges, and neither is a port:
 *      - the packed-pixel VRAM routes: 0xA8000-0xAFFFF and 0xB0000-0xB7FFF,
 *        whose bank is selected by the PPM bank registers at 0xE0004 / 0xE0006
 *        (NP2kai io/pegc.h PEGC_REG_PPM_BANK_A8/B0; MAME `pegc_mmio_map`
 *        map(0x004,0x004).select(2)), and the flat 0xF00000-0xF7FFFF aperture
 *        (NP2kai mem/memvga.c `memvgaf_*`, gated by PEGC_REG_VRAM_ENABLE);
 *      - the plane engine's register block, 0xE0104-0xE011F (NP2kai io/pegc.h
 *        PEGC_REG_PLANE_ACCESS 0x104, PLANE_ROP 0x108, DATASELECT 0x10A, MASK
 *        0x10C, LENGTH 0x110, SHIFT 0x112, PALETTE1 0x114, PALETTE2 0x118,
 *        PATTERN 0x120; MAME maps 0x104-0x11F as byte-wide read/write registers
 *        and 0x120-0x19F as 32-bit pattern registers).
 *    Those registers live only in the PEGC MMIO VIEW of the 0xE0000-0xE7FFF
 *    window, and with that view off the very same addresses are GVRAM (plane E
 *    in 16-colour mode), so sampling them is meaningful ONLY while the view is
 *    on - and both references tie "view on" to the mode bit this probe already
 *    reads: NP2kai's `gdc_analogext(TRUE)` sets GDCANALOG_256 and VOPBIT_VGA
 *    together and `memm_vram` selects the `memvgaio_*` handlers when VOPBIT_VGA
 *    is set, and MAME's `pc9821_video_ff_w` does `m_pegc_mmio_view.select(0)` on
 *    the same write that sets ANALOG_256_MODE. So the sampler reads index 0x0A
 *    FIRST and skips the block entirely while it is clear.
 *    Two deliberate limits, both stated rather than papered over: the sampler
 *    only READS (it never writes a window, so it cannot corrupt a frame), and it
 *    reads only 0xE0004/0xE0006 and 0xE0104-0xE0118 as BYTES - never the
 *    0xE0120+ pattern block, whose MAME read handler is not a plain register read
 *    (it is the `rop & 0x8000` pattern-shift path) and could disturb the run.
 *    The engine's registers are STICKY, which is what makes an 18.2 Hz sample
 *    useful: a fill leaves its ROP/length/mask in place until the next one, so a
 *    single sample taken after an operation still sees it.
 *    The one thing this probe CANNOT see is the flat aperture's own enable: it
 *    is written at 0xE0102, which MAME maps write-only, so a driver that uses
 *    0xF00000 without touching 0xE0004/0xE0006 or the engine block shows up here
 *    only as "256-colour mode, no plane registers, no PPM bank" - which is the
 *    cheap half by definition, so the classification is unaffected.
 *
 * THE ANSWER THE CAPTURE GIVES (pegcwatch_decode.py prints this table):
 *   POST A0A=00                       -> the driver never entered PEGC 256-colour
 *   POST A0A=01, PLANE all NZ=0       -> DISPLAY HALF ONLY (41-51 LABs)
 *   POST A0A=01, any PLANE NZ=1       -> DISPLAY + PLANE ENGINE (69-76 LABs)
 * A `MODE` row with `A0A=01` dates the transition and a `MODE` row with `P6A=21`
 * names the write that caused it - so the capture also says whether the mode came
 * from the BIOS (an INT 18h row whose PRE/POST straddles the transition) or from
 * the driver's own `out 0x6A,0x21`.
 *
 * HOW IT STAYS RESIDENT, AND WHY NOTHING IS PATCHED. Exactly the logtime
 * discipline, whose header carries the byte-level proof: this is an EXEC wrapper,
 * not a /TSR hook - it shrinks its own DOS block with INT 21h AH=4Ah so DOS loads
 * the child ABOVE it, and it keeps the child's vectors until the child has
 * returned, so the wrapper dies with its child and cannot outlive it. DS:DX is
 * the child's ASCIZ FILENAME and ES:BX the parameter block (passing the block in
 * both means DOS reads an empty name and answers "file not found"); child_name is
 * what DOS loads, the tail is the child's PSP:80/81 arguments only, and the FCBs
 * are blank because this wrapper cannot re-parse a tail for the child. The child
 * runs byte-identical to a direct load.
 *
 * NO DOS CALL IS MADE INSIDE ANY HOOK. The hook bodies do port and window reads
 * and append to fixed tables; every row is printed AFTER the child has returned
 * and the vectors are restored. That is not tidiness: on this machine DOS's own
 * console output can reach the BIOS graphics path, so an INT 18h hook that
 * printed would re-enter itself - the same reason logtime writes a ring and dumps
 * it at exit. The ISR bodies are `cli`-atomic (the gate cleared IF and nothing in
 * the body sets it), all registers are saved and restored, and both hooks CHAIN
 * to the as-found handler - the INT 18h one with the caller's own FLAGS (not
 * `pushf`: passing IF=0 to a BIOS routine that waits on VSYNC hangs it) so its
 * result flags land in the caller's frame - and every as-found vector is printed
 * and read back as proof at exit.
 *
 * RADIO SILENCE IS A RESULT. Once an extender child is in protected mode, INT 1Ch
 * may stop arriving at a real-mode handler; the plane sampler then keeps its last
 * value and the SAMP row's tick count simply stops growing. Read SAMP and I18
 * before concluding anything from an unchanged POST row: a run where NOTHING was
 * sampled is a capture that did not observe, not a driver that did nothing. The
 * MODE rows carry the tick of every state change observed, which is what makes
 * that distinction checkable from the file alone.
 *
 * OUTPUT: one machine-readable line per fact on stdout (INT 21h AH=02, so a
 * redirect captures it), `PEGCWATCH BEGIN V=1` first and `PEGCWATCH END V=1` last
 * so a torn capture is visible. Decode on the host with
 * tools/hwprobe/pegcwatch/pegcwatch_decode.py; run it with RUNPEGC.BAT.
 *
 * SAFETY: no disk write, no port WRITE other than the 0x9A0 index latch that
 * every consumer of that port already writes before reading it, no window write,
 * and nothing written to the child. The only non-read this program performs on
 * the child's behalf is the DOS loader call itself.
 */

    .code16
    .intel_syntax noprefix

    .section .text
    .global _start

/* ------------------------------------------------------------------ */
/* constants (every .equ this file uses is defined here, above all use: a
 * forward-referenced name in an operand assembles as a MEMORY reference - the
 * trap probe2.s's header documents - so a constant used before its own line
 * would silently become DS:0x0001 instead of an immediate)              */
/* ------------------------------------------------------------------ */
    .equ SW_NOP,      1      /* /NOP: skip the plane-register sampling      */
    .equ VEC_N,       4      /* 18h, 1Ch, 23h, 24h                          */
    .equ I18_MAX,     32     /* full INT 18h rows kept (the rest counted)   */
    .equ MODE_MAX,    24     /* state-change rows kept                      */
    .equ PLANE_N,     10     /* plane/PPM registers sampled                 */
    .equ NAME_MAX,    80     /* DOS 8.3 with drive, root, dir and NUL       */
    .equ TAIL_MAX,    126    /* a PSP:80 command line's own limit           */

/* the ten sampled registers, as offsets inside the 0xE0000-0xE7FFF window. The
 * first two are the packed-pixel bank selects (a driver that paints the screen
 * through 0xA8000/0xB0000 must bank them), the rest are the plane engine's. */
    .equ PL_0004,     0x0004
    .equ PL_0006,     0x0006
    .equ PL_0104,     0x0104
    .equ PL_0108,     0x0108
    .equ PL_0109,     0x0109
    .equ PL_010C,     0x010C
    .equ PL_0110,     0x0110
    .equ PL_0112,     0x0112
    .equ PL_0114,     0x0114
    .equ PL_0118,     0x0118

/* One register read + accumulate. `off` is a window offset (ES is already
 * 0xE000), `idx` the slot: pl_last[idx] keeps the last byte seen and pl_nz's
 * bit `idx` latches "ever non-zero". */
    .macro PLREAD idx, off
    mov     al, es:[\off]
    mov     [pl_last + \idx], al
    test    al, al
    jz      9f
    or      word ptr [pl_nz], (1 << \idx)
9:
    .endm

/* ------------------------------------------------------------------ */
_start:
    cld
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    /* mode256_t is a "never seen" stamp: -1 until the first sample sees the
     * 256-colour bit set, so a capture can tell "never" from "at tick 0". */
    mov     dword ptr [mode256_t], -1
    call    pw_parse

    mov     si, offset msg_begin
    call    puts

    /* The calibration row: the machine's PEGC state where this program started,
     * before any hook exists. On a freshly-booted machine at the DOS prompt the
     * machine's own capture says 0x9A0 index 0x0A is CLEAR and 0x6A reads 0x00;
     * a capture that disagrees is telling you the machine was not in the state
     * this row assumes. */
    call    print_cap
    call    blk_read
    call    print_mem

    cmp     byte ptr [have_child], 0
    je      pw_calib

    call    print_cmd

    /* ---- shrink this program's block so DOS can load the child above it ----
     * INLINE, not a subroutine: the AH=4Ah leaves every byte above the block
     * free for the child, and the SS:SP move immediately after would make a
     * `ret` pop from the new stack. The block size is this image's own end
     * offset rounded up to a paragraph (our segment IS the PSP segment, so the
     * image offset is already relative to the PSP). */
    mov     ax, cs
    mov     es, ax
    call    res_paras
    mov     bx, ax
    mov     ax, 0x4A00
    int     0x21
    jnc     pw_shrunk
    /* The shrink cannot normally fail (BX is smaller than the block this program
     * already owns), but moving SS:SP on a failed setblock would put the stack in
     * the child's region, so the failure path returns on the ORIGINAL stack and
     * reports instead of crashing on the machine. */
    inc     byte ptr [run_fail]
    mov     si, offset msg_shrinkfail
    call    puts
    jmp     pw_finish
pw_shrunk:
    cli
    mov     ax, cs
    mov     ss, ax
    mov     sp, offset image_end
    sti

    call    blk_read
    call    print_mem_b
    call    build_exec
    call    vecs_install
    call    exec_child
    call    vecs_restore
    call    print_post
    call    print_modes
    call    print_i18
    call    print_plane
    call    print_samp
    call    print_run
    jmp     pw_finish

pw_calib:
    /* No child: print the usage and one raw plane sample. The sample's VIEWON
     * field is what makes it readable - with the PEGC MMIO view OFF (the DOS
     * prompt) those addresses are GVRAM and their bytes are framebuffer data,
     * NOT registers, and the row says so instead of inviting that mistake. */
    call    print_usage
    call    peg_sample
    call    print_plane
    call    print_samp
    jmp     pw_finish

pw_finish:
    call    fail_print
    mov     si, offset msg_end
    call    puts
    mov     al, 0
    cmp     byte ptr [run_fail], 0
    je      pw_exit
    mov     al, 1
pw_exit:
    mov     ah, 0x4C
    int     0x21
    hlt

/* ------------------------------------------------------------------ */
/* argument parsing: PSP:0x80 holds a length byte then the text        */
/* ------------------------------------------------------------------ */
/* One optional switch (/NOP or -NOP, case-sensitive like every DOS switch),
 * then the child's name and its arguments. The switches are matched as WHOLE
 * tokens: a prefix match would let "/NO" swallow "/NOP", and a typo that
 * silently did nothing would be read as "the sampling was installed". */
pw_parse:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    mov     byte ptr [have_child], 0
    mov     byte ptr [sw], 0
    mov     byte ptr [child_name], 0
    mov     byte ptr [child_tail], 0
    mov     bx, 0x0080
    mov     cl, [bx]
    xor     ch, ch
    mov     si, 0x0081
    mov     ax, si
    add     ax, cx
    mov     [tail_end], ax
pp_scan:
    cmp     si, [tail_end]
    jae     pp_done
    mov     al, [si]
    cmp     al, ' '
    je      pp_ws
    cmp     al, 9
    je      pp_ws
    jmp     pp_tok
pp_ws:
    inc     si
    jmp     pp_scan
pp_tok:
    cmp     al, '/'
    je      pp_sw
    cmp     al, '-'
    je      pp_sw
    jmp     pp_prog
pp_sw:
    mov     di, offset sw_nop
    call    tok_eq
    jc      pp_sw_nop
    /* An unknown switch is skipped, not fatal (DOS itself ignores them), but it
     * is named in the capture so a typo cannot look like an installed hook. */
    mov     si, offset msg_badsw
    call    puts
    call    puts_tok
    call    putnl
    call    skip_tok
    jmp     pp_scan
pp_sw_nop:
    or      byte ptr [sw], SW_NOP
    call    skip_tok
    jmp     pp_scan

pp_prog:
    /* SI = the program's first character. TWO strings come off this one token
     * and they are NOT the same string: child_name is the ASCIZ filename DOS is
     * handed in DS:DX - the whole token as typed, so a path is legal - and
     * child_tail is the child's own PSP:80/81 command line, which is the rest of
     * the line AFTER the name, the delimiter included, and NOT the name. */
    mov     bx, si
    mov     di, offset child_name
    mov     cx, NAME_MAX-1
pp_name_copy:
    test    cx, cx
    jz      pp_name_done
    cmp     si, [tail_end]
    jae     pp_name_done
    mov     al, [si]
    cmp     al, ' '
    je      pp_name_done
    cmp     al, 9
    je      pp_name_done
    cmp     al, 13
    je      pp_name_done
    test    al, al
    jz      pp_name_done
    mov     [di], al
    inc     di
    inc     si
    dec     cx
    jmp     pp_name_copy
pp_name_done:
    mov     byte ptr [di], 0
    mov     si, bx
    call    skip_tok
    mov     di, offset child_tail
    xor     cx, cx
pp_tail_copy:
    cmp     si, [tail_end]
    jae     pp_tail_done
    cmp     cx, TAIL_MAX
    jae     pp_tail_done
    mov     al, [si]
    cmp     al, 13
    je      pp_tail_done
    test    al, al
    jz      pp_tail_done
    mov     [di+1], al
    inc     di
    inc     si
    inc     cx
    jmp     pp_tail_copy
pp_tail_done:
    mov     [child_tail], cl
    mov     byte ptr [di+1], 0x0D
    mov     byte ptr [di+2], 0
    mov     byte ptr [have_child], 1
pp_done:
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* skip_tok: SI -> the first character after the token (its delimiter). */
skip_tok:
    push    ax
st_loop:
    cmp     si, [tail_end]
    jae     st_done
    mov     al, [si]
    cmp     al, ' '
    je      st_done
    cmp     al, 9
    je      st_done
    cmp     al, 13
    je      st_done
    inc     si
    jmp     st_loop
st_done:
    pop     ax
    ret

/* puts_tok: print the token at SI (up to its delimiter) without advancing SI. */
puts_tok:
    push    ax
    push    si
pt_loop:
    cmp     si, [tail_end]
    jae     pt_done
    mov     al, [si]
    cmp     al, ' '
    je      pt_done
    cmp     al, 9
    je      pt_done
    cmp     al, 13
    je      pt_done
    test    al, al
    jz      pt_done
    mov     dl, al
    call    putc
    inc     si
    jmp     pt_loop
pt_done:
    pop     si
    pop     ax
    ret

/* tok_eq: SI = a token, DI = a NUL-terminated name -> CF = 1 when the token IS
 * that name (nothing but a delimiter after it). Preserves SI and DI. */
tok_eq:
    push    si
    push    di
    push    bx
te_loop:
    mov     al, [di]
    test    al, al
    jz      te_name_end
    mov     bl, [si]
    cmp     bl, al
    jne     te_no
    inc     si
    inc     di
    jmp     te_loop
te_name_end:
    mov     bl, [si]
    cmp     bl, ' '
    je      te_yes
    cmp     bl, 9
    je      te_yes
    cmp     bl, 13
    je      te_yes
    test    bl, bl
    jz      te_yes
te_no:
    clc
    jmp     te_out
te_yes:
    stc
te_out:
    pop     bx
    pop     di
    pop     si
    ret

/* ------------------------------------------------------------------ */
/* output helpers (INT 21h AH=02, so every row is redirectable)        */
/* ------------------------------------------------------------------ */
putc:                           /* DL */
    push    ax
    mov     ah, 0x02
    int     0x21
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

puts:                           /* DS:SI, NUL terminated */
    push    ax
    push    si
lps_loop:
    mov     al, [si]
    test    al, al
    jz      lps_done
    mov     dl, al
    call    putc
    inc     si
    jmp     lps_loop
lps_done:
    pop     si
    pop     ax
    ret

puthex8:                        /* AL */
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

puthexdig:                      /* AL = 0..15 */
    push    dx
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
    pop     dx
    ret

puthex16:                       /* AX */
    push    ax
    mov     al, ah
    call    puthex8
    pop     ax
    call    puthex8
    ret

puthex32:                       /* EAX */
    push    eax
    shr     eax, 16
    call    puthex16
    pop     eax
    call    puthex16
    ret

/* put_dec16: AX in decimal, no padding. Clobbers AX, BX, CX, DX, DI. */
put_dec16:
    push    ax
    push    bx
    push    cx
    push    dx
    push    di
    mov     di, offset dec_buf
    xor     cx, cx
    mov     bx, 10
pd_loop:
    xor     dx, dx
    div     bx
    add     dl, '0'
    mov     [di], dl
    inc     di
    inc     cx
    test    ax, ax
    jnz     pd_loop
pd_out:
    dec     di
    mov     dl, [di]
    call    putc
    loop    pd_out
    pop     di
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* the ARTIC free-running counter: the time base for the MODE rows      */
/* ------------------------------------------------------------------ */
/* artic_read: EAX = the counter at 005C (bits 15:0) / 005F (bits 23:16).
 * The port block is NOT four adjacent bytes: 005D and 005E both carry
 * cnt[15:8] and 005F carries cnt[23:16] (the core's HX_005C..005F decode;
 * NP2kai io/artic.c attaches 005D and 005E to the same handler), so reading
 * 005E as if it were cnt[23:16] mixes cnt[23:8] into the high half. 005F is a
 * byte, not a word: 0060 is the GDC status. The low word wraps every 213 ms at
 * the documented 307200 Hz, so it is read again after the high byte and a wrap
 * (lo2 < lo1) bumps the high byte. Read-only; the same routine probe2 uses. */
artic_read:
    push    dx
    push    bx
    push    cx
    mov     dx, 0x005C
    in      ax, dx
    movzx   ebx, ax
    mov     dx, 0x005F
    in      al, dx
    movzx   ecx, al
    mov     dx, 0x005C
    in      ax, dx
    cmp     ax, bx
    jae     ar_nowrap
    inc     ecx
ar_nowrap:
    movzx   eax, ax
    shl     ecx, 16
    or      eax, ecx
    pop     cx
    pop     bx
    pop     dx
    ret

/* ------------------------------------------------------------------ */
/* the PEGC state capture: 8 bytes at DS:DI                             */
/* ------------------------------------------------------------------ */
/*   +0 port 0x6A      (the extended-video mode f/f; NP2kai gdc_i6a reads
 *                      gdc.mode2 back, measured 0x00 in 16-colour text mode)
 *   +1 0x9A0 index 0x0A  the 256-colour / analog-256 bit - THE bit
 *   +2 0x9A0 index 0x04  mode2 bit 0, the analog-16 select
 *   +3 0x9A0 index 0x08  mode2 bit 3, the PEGC register write enable
 *   +4 0x9A0 index 0x0D  GDCANALOG_256E
 *   +5 0000:054D         the BIOS/GDC graphics work byte (bit 7 is set by the
 *                        firmware's own PEGC select; this core's GDC2 already
 *                        reads this byte's bit 2)
 *   +6 port 0x68         MODE FF1 (the measured text-mode byte is 0x18)
 *   +7 0x9A0 index 0x03  mode1 bit 7 DISP
 * Port 0x9A0 is index-then-data: the write selects, the read answers, and every
 * consumer of that port writes the index first - so that write is both what the
 * machine's own firmware does and the only non-read this program performs.
 * Clobbers AX, DX, ES. */
peg_cap:
    push    ax
    push    dx
    mov     dx, 0x9A0
    mov     al, 0x0A
    out     dx, al
    in      al, dx
    mov     [di+1], al
    mov     al, 0x04
    out     dx, al
    in      al, dx
    mov     [di+2], al
    mov     al, 0x08
    out     dx, al
    in      al, dx
    mov     [di+3], al
    mov     al, 0x0D
    out     dx, al
    in      al, dx
    mov     [di+4], al
    mov     al, 0x03
    out     dx, al
    in      al, dx
    mov     [di+7], al
    mov     dx, 0x006A
    in      al, dx
    mov     [di+0], al
    mov     dx, 0x0068
    in      al, dx
    mov     [di+6], al
    push    es
    xor     ax, ax
    mov     es, ax
    mov     al, es:[0x054D]
    pop     es
    mov     [di+5], al
    pop     dx
    pop     ax
    ret

/* ------------------------------------------------------------------ */
/* the plane/PPM sampler, called from the INT 1Ch hook                  */
/* ------------------------------------------------------------------ */
/* Reads (never writes) the ten bytes that decide the question:
 *   0xE0004, 0xE0006  the PPM bank selects for the packed-pixel windows - a
 *                     driver painting 0xA8000/0xB0000 must bank them
 *   0xE0104  plane access (the write-protect mask)
 *   0xE0108, 0xE0109  the plane ROP
 *   0xE010C  the pixel mask
 *   0xE0110  the block length (what a fill or a copy sets)
 *   0xE0112  the read/write bit shift
 *   0xE0114, 0xE0118  the two palette-compare registers
 * ONLY while the PEGC MMIO view is on (0x9A0 index 0x0A bit 0): with it off
 * those addresses are GVRAM plane E and their bytes are framebuffer data, so a
 * sample taken then would be a fabricated "the engine was used". The view-on
 * test is the sourced one: NP2kai's gdc_analogext(TRUE) sets GDCANALOG_256 (the
 * bit this reads) and VOPBIT_VGA (which selects memvgaio_*) in the same call,
 * and MAME's pc9821_video_ff_w enables m_pegc_mmio_view on the same write that
 * sets ANALOG_256_MODE.
 * Accumulates: pl_last[] keeps the last byte seen per register, pl_nz the
 * ever-non-zero bitmask, pl_view_n counts the samples taken with the view on.
 * Clobbers AX, BX, CX, DX, ES. */
peg_sample:
    inc     word ptr [samp_n]
    mov     dx, 0x9A0
    mov     al, 0x0A
    out     dx, al
    in      al, dx
    mov     [s_9a0a], al
    mov     al, 0x04
    out     dx, al
    in      al, dx
    mov     [s_9a0_04], al
    mov     dx, 0x006A
    in      al, dx
    mov     [s_6a], al
    push    es
    xor     ax, ax
    mov     es, ax
    mov     al, es:[0x054D]
    pop     es
    mov     [s_54d], al
    test    byte ptr [s_9a0a], 1
    jz      ps_done
    test    byte ptr [sw], SW_NOP
    jnz     ps_done
    inc     word ptr [pl_view_n]
    /* ES is restored: this routine is also called from the calibration path,
     * which returns to DOS with ES live (DOS's own calls must not be handed a
     * segment this program picked). */
    push    es
    mov     ax, 0xE000
    mov     es, ax
    PLREAD 0, PL_0004
    PLREAD 1, PL_0006
    PLREAD 2, PL_0104
    PLREAD 3, PL_0108
    PLREAD 4, PL_0109
    PLREAD 5, PL_010C
    PLREAD 6, PL_0110
    PLREAD 7, PL_0112
    PLREAD 8, PL_0114
    PLREAD 9, PL_0118
    pop     es
ps_done:
    ret

/* ------------------------------------------------------------------ */
/* hook: INT 1Ch - the sampler                                          */
/* ------------------------------------------------------------------ */
/* A LEAF hook: it does its body with every register saved and then jumps to the
 * previous handler with the stack frame exactly as the CPU built it, so that
 * handler's iret returns to the interrupted program with the caller's flags. A
 * state CHANGE appends one MODE record (tick, 6A, A0A, A04, 54D) so the capture
 * carries a timeline, and the first sample that sees A0A set stamps mode256_t -
 * which is what dates the transition if the child's own writes are invisible to
 * the INT 18h hook. No DOS call is made here. */
h_i1c:
    push    es
    push    ds
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    cs
    pop     ds
    call    peg_sample
    /* the change test: a 4-byte tuple, so the row appears once per transition
     * rather than 18 times a second */
    mov     al, [s_6a]
    cmp     al, [last_6a]
    jne     mi_rec
    mov     al, [s_9a0a]
    cmp     al, [last_9a0a]
    jne     mi_rec
    mov     al, [s_9a0_04]
    cmp     al, [last_9a0_04]
    jne     mi_rec
    mov     al, [s_54d]
    cmp     al, [last_54d]
    je      mi_done
mi_rec:
    mov     al, [s_6a]
    mov     [last_6a], al
    mov     al, [s_9a0a]
    mov     [last_9a0a], al
    mov     al, [s_9a0_04]
    mov     [last_9a0_04], al
    mov     al, [s_54d]
    mov     [last_54d], al
    test    byte ptr [s_9a0a], 1
    jz      mi_nomode
    cmp     dword ptr [mode256_t], -1
    jne     mi_nomode
    call    artic_read
    mov     [mode256_t], eax
mi_nomode:
    mov     ax, [mode_n]
    cmp     ax, MODE_MAX
    jae     mi_over
    mov     di, ax
    shl     di, 1
    shl     di, 1
    shl     di, 1                   /* di = index * 8 */
    add     di, offset mode_rec
    call    artic_read
    mov     [di+0], eax
    mov     al, [s_6a]
    mov     [di+4], al
    mov     al, [s_9a0a]
    mov     [di+5], al
    mov     al, [s_9a0_04]
    mov     [di+6], al
    mov     al, [s_54d]
    mov     [di+7], al
    inc     word ptr [mode_n]
    jmp     mi_done
mi_over:
    inc     word ptr [mode_over]
mi_done:
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    pop     ds
    pop     es
    jmp     dword ptr cs:[VT_I1C]

/* ------------------------------------------------------------------ */
/* hook: INT 18h - the BIOS graphics services                            */
/* ------------------------------------------------------------------ */
/* The chain-with-return idiom (RBIL-documented, and logtime's): push bp, save
 * the caller's registers, push the CALLER'S OWN FLAGS - not `pushf`, which would
 * hand a BIOS routine that waits on VSYNC an IF=0 world - then far-call the
 * as-found handler. A far call pushes CS:IP, so the pushed FLAGS completes an
 * interrupt frame for it, and its iret returns to the instruction after our call
 * with its result flags live; the resume then merges those flags back into the
 * caller's own frame. The mode bit is captured BEFORE and AFTER the chain, so a
 * row whose PRE/POST straddles the transition is the BIOS being the thing that
 * entered 256-colour mode - the only way "which INT/AH" gets answered without
 * guessing it out of the ROM.
 *
 * Nothing is printed here (DOS's console output can itself reach the BIOS
 * graphics path, so a printing INT 18h hook would re-enter itself): the row is
 * appended to i18_rec and printed after the child has returned. i18_depth passes
 * a nested delivery straight through, counted but not recorded. */
h_i18:
    inc     word ptr [i18_seen]
    cmp     word ptr [i18_depth], 0
    jne     h_i18_nested
    push    bp
    push    es
    push    ds
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    mov     bp, sp
    mov     ax, [bp+10]             /* the caller's AX, from the saved copies */
    mov     [s_ax], ax
    mov     ax, [bp+8]
    mov     [s_bx], ax
    mov     ax, [bp+6]
    mov     [s_cx], ax
    mov     ax, [bp+4]
    mov     [s_dx], ax
    push    cs
    pop     ds
    mov     di, offset cap_pre
    call    peg_cap
    call    artic_read
    mov     [s_t0], eax
    inc     word ptr [i18_depth]
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    pop     ds
    pop     es
    pop     bp
    push    bp
    mov     bp, sp
    push    word ptr [bp+6]         /* the caller's own FLAGS */
    call    dword ptr cs:[VT_I18]
    pop     bp
    /* ---- resume: the chained handler returned through its iret ---- */
    pushf
    push    es
    push    ds
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    cs
    pop     ds
    dec     word ptr [i18_depth]
    mov     di, offset cap_post
    call    peg_cap
    call    i18_record
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    pop     ds
    pop     es
    popf
    push    bp
    mov     bp, sp
    pushf
    pop     word ptr [bp+6]         /* the chain's result flags, into the caller's frame */
    pop     bp
    iret

h_i18_nested:
    inc     word ptr [i18_rec_drop]
    jmp     dword ptr cs:[VT_I18]

/* i18_record: append the call's row (16 bytes), bounded. Silent when full -
 * i18_drop carries the loss into the capture. DS = this program's segment. */
i18_record:
    push    ax
    push    di
    mov     ax, [i18_n]
    cmp     ax, I18_MAX
    jae     ir_full
    mov     di, ax
    shl     di, 1
    shl     di, 1
    shl     di, 1
    shl     di, 1                   /* di = index * 16 */
    add     di, offset i18_rec
    mov     ax, [s_ax]
    mov     [di+0], ax
    mov     ax, [s_bx]
    mov     [di+2], ax
    mov     ax, [s_cx]
    mov     [di+4], ax
    mov     ax, [s_dx]
    mov     [di+6], ax
    mov     al, [cap_pre+0]
    mov     [di+8], al
    mov     al, [cap_pre+1]
    mov     [di+9], al
    mov     al, [cap_post+0]
    mov     [di+10], al
    mov     al, [cap_post+1]
    mov     [di+11], al
    mov     eax, [s_t0]
    mov     [di+12], eax
    inc     word ptr [i18_n]
    jmp     ir_out
ir_full:
    inc     word ptr [i18_drop]
ir_out:
    pop     di
    pop     ax
    ret

/* INT 23h/24h: inert, so a ^C or a critical error cannot abandon the vector
 * restore (probe2's idiom; the 24h one fails the operation rather than
 * retrying - a retry loop on a real disk error is a hang). */
h_iret:
    iret

h_int24:
    mov     al, 3
    iret

/* ------------------------------------------------------------------ */
/* the vector ledger: install, print, restore, prove                     */
/* ------------------------------------------------------------------ */
vecs_install:
    xor     di, di
    xor     ax, ax
    mov     es, ax
vi_loop:
    cmp     di, VEC_N
    jae     vi_done
    mov     si, di
    shl     si, 1
    shl     si, 1
    shl     si, 1                   /* si = the row's base, 8 bytes */
    mov     bx, [si + vec_tab]
    shl     bx, 1
    shl     bx, 1                   /* bx = the vector number * 4 */
    mov     ax, es:[bx]
    mov     [si + vec_tab+4], ax
    mov     ax, es:[bx+2]
    mov     [si + vec_tab+6], ax
    mov     ax, [si + vec_tab+2]
    mov     es:[bx], ax
    mov     ax, cs
    mov     es:[bx+2], ax
    mov     si, offset msg_hook
    call    puts
    call    put_vecnum
    mov     si, offset msg_old
    call    puts
    call    put_vecold
    mov     si, offset msg_new
    call    puts
    mov     ax, cs
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     si, di
    shl     si, 1
    shl     si, 1
    shl     si, 1
    mov     ax, [si + vec_tab+2]
    call    puthex16
    call    putnl
    inc     di
    jmp     vi_loop
vi_done:
    mov     ax, cs
    mov     es, ax
    ret

put_vecnum:                     /* DI = the row index -> the vector as 2 hex */
    push    ax
    push    si
    mov     si, di
    shl     si, 1
    shl     si, 1
    shl     si, 1
    mov     ax, [si + vec_tab]
    call    puthex8
    pop     si
    pop     ax
    ret

put_vecold:                     /* DI = the row index -> SSSS:OOOO as found */
    push    ax
    push    si
    mov     si, di
    shl     si, 1
    shl     si, 1
    shl     si, 1
    mov     ax, [si + vec_tab+6]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     ax, [si + vec_tab+4]
    call    puthex16
    pop     si
    pop     ax
    ret

vecs_restore:
    xor     di, di
    xor     ax, ax
    mov     es, ax
vr_loop:
    cmp     di, VEC_N
    jae     vr_done
    mov     si, di
    shl     si, 1
    shl     si, 1
    shl     si, 1
    mov     bx, [si + vec_tab]
    shl     bx, 1
    shl     bx, 1
    mov     ax, [si + vec_tab+6]
    mov     es:[bx+2], ax
    mov     ax, [si + vec_tab+4]
    mov     es:[bx], ax
    /* the read-back proof */
    mov     ax, es:[bx]
    mov     [back_o], ax
    mov     ax, es:[bx+2]
    mov     [back_s], ax
    mov     si, offset msg_vec
    call    puts
    call    put_vecnum
    mov     si, offset msg_old
    call    puts
    call    put_vecold
    mov     si, offset msg_back
    call    puts
    mov     ax, [back_s]
    call    puthex16
    mov     dl, ':'
    call    putc
    mov     ax, [back_o]
    call    puthex16
    mov     si, di
    shl     si, 1
    shl     si, 1
    shl     si, 1
    mov     ax, [back_o]
    cmp     ax, [si + vec_tab+4]
    jne     vr_bad
    mov     ax, [back_s]
    cmp     ax, [si + vec_tab+6]
    jne     vr_bad
    mov     si, offset msg_ok
    call    puts
    jmp     vr_next
vr_bad:
    mov     si, offset msg_notrest
    call    puts
    inc     byte ptr [run_fail]
vr_next:
    inc     di
    jmp     vr_loop
vr_done:
    mov     ax, cs
    mov     es, ax
    ret

/* ------------------------------------------------------------------ */
/* the rows                                                             */
/* ------------------------------------------------------------------ */
/* print_cap_fields: the 8 captured bytes at DS:DI as one row's fields. */
print_cap_fields:
    mov     si, offset msg_p6a
    call    puts
    mov     al, [di+0]
    call    puthex8
    mov     si, offset msg_a0a
    call    puts
    mov     al, [di+1]
    call    puthex8
    mov     si, offset msg_a04
    call    puts
    mov     al, [di+2]
    call    puthex8
    mov     si, offset msg_a08
    call    puts
    mov     al, [di+3]
    call    puthex8
    mov     si, offset msg_a0d
    call    puts
    mov     al, [di+4]
    call    puthex8
    mov     si, offset msg_w54d
    call    puts
    mov     al, [di+5]
    call    puthex8
    mov     si, offset msg_m68
    call    puts
    mov     al, [di+6]
    call    puthex8
    mov     si, offset msg_a03
    call    puts
    mov     al, [di+7]
    call    puthex8
    call    putnl
    ret

/* print_cap / print_post: the same row with its label and the tick it was
 * taken at, so the two can be compared to each other and to a MODE row. */
print_cap:
    call    artic_read
    push    eax
    mov     si, offset msg_pw
    call    puts
    mov     si, offset lbl_base
    call    puts
    mov     si, offset msg_t
    call    puts
    pop     eax
    call    puthex32
    mov     di, offset cap_a
    call    print_cap_fields
    ret

print_post:
    call    artic_read
    push    eax
    mov     si, offset msg_pw
    call    puts
    mov     si, offset lbl_post
    call    puts
    mov     si, offset msg_t
    call    puts
    pop     eax
    call    puthex32
    mov     di, offset cap_post
    call    print_cap_fields
    ret

print_cmd:
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_cmd
    call    puts
    mov     si, offset child_name
    call    puts
    mov     si, offset msg_tail
    call    puts
    mov     cl, [child_tail]
    xor     ch, ch
    mov     si, offset child_tail + 1
    test    cx, cx
    jz      pc_cmd_done
pc_cmd_loop:
    mov     dl, [si]
    call    putc
    inc     si
    loop    pc_cmd_loop
pc_cmd_done:
    mov     dl, ']'
    call    putc
    call    putnl
    ret

/* blk_read / print_mem*: DOS's own largest-free-block answer, so a child that
 * could not be loaded for want of memory is a printed number rather than a
 * guess. AH=48h with BX=0xFFFF fails and leaves BX = the largest free block in
 * paragraphs; 1 paragraph = 16 bytes and 64 paragraphs = 1 KiB. */
blk_read:
    push    ax
    push    bx
    mov     ah, 0x48
    mov     bx, 0xFFFF
    int     0x21
    mov     [mem_para], bx
    pop     bx
    pop     ax
    ret

print_mem:                      /* PH=A (before the child) */
    mov     dl, 'A'
    jmp     print_mem_go
print_mem_b:                    /* PH=B (after it) */
    mov     dl, 'B'
print_mem_go:
    push    dx
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_mem
    call    puts
    pop     dx
    call    putc
    mov     si, offset msg_free
    call    puts
    mov     ax, [mem_para]
    call    puthex16
    mov     si, offset msg_para
    call    puts
    mov     ax, [mem_para]
    mov     cl, 6
    shr     ax, cl
    call    put_dec16
    mov     si, offset msg_kb
    call    puts
    call    putnl
    ret

/* print_modes: the state-change timeline. One row per observed change of
 * (6A, A0A, A04, 54D), each with the ARTIC tick it was seen at. */
print_modes:
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_modes
    call    puts
    mov     ax, [mode_n]
    call    puthex16
    mov     si, offset msg_over
    call    puts
    mov     ax, [mode_over]
    call    puthex16
    call    putnl
    mov     di, 0
pm_loop:
    cmp     di, [mode_n]
    jae     pm_done
    mov     si, offset msg_pw
    call    puts
    mov     si, offset lbl_mode
    call    puts
    mov     si, offset msg_n
    call    puts
    mov     ax, di
    call    puthex16
    mov     si, offset msg_t
    call    puts
    mov     bx, di
    shl     bx, 1
    shl     bx, 1
    shl     bx, 1
    add     bx, offset mode_rec
    mov     eax, [bx+0]
    call    puthex32
    mov     si, offset msg_p6a
    call    puts
    mov     al, [bx+4]
    call    puthex8
    mov     si, offset msg_a0a
    call    puts
    mov     al, [bx+5]
    call    puthex8
    mov     si, offset msg_a04
    call    puts
    mov     al, [bx+6]
    call    puthex8
    mov     si, offset msg_w54d
    call    puts
    mov     al, [bx+7]
    call    puthex8
    call    putnl
    inc     di
    jmp     pm_loop
pm_done:
    ret

/* print_i18: one row per INT 18h call (the first I18_MAX of them). PRE and POST
 * are the 256-colour bit and the mode f/f before and after the chained handler
 * ran: a row whose two differ is the BIOS performing that transition. */
print_i18:
    mov     di, 0
pi_loop:
    cmp     di, [i18_n]
    jae     pi_done
    mov     si, offset msg_pw
    call    puts
    mov     si, offset lbl_i18
    call    puts
    mov     si, offset msg_n
    call    puts
    mov     ax, di
    call    puthex16
    mov     si, offset msg_t
    call    puts
    mov     bx, di
    shl     bx, 1
    shl     bx, 1
    shl     bx, 1
    shl     bx, 1
    add     bx, offset i18_rec
    mov     eax, [bx+12]
    call    puthex32
    mov     si, offset msg_ax
    call    puts
    mov     ax, [bx+0]
    call    puthex16
    mov     si, offset msg_bx
    call    puts
    mov     ax, [bx+2]
    call    puthex16
    mov     si, offset msg_cx
    call    puts
    mov     ax, [bx+4]
    call    puthex16
    mov     si, offset msg_dx
    call    puts
    mov     ax, [bx+6]
    call    puthex16
    mov     si, offset msg_pre6a
    call    puts
    mov     al, [bx+8]
    call    puthex8
    mov     si, offset msg_prea0a
    call    puts
    mov     al, [bx+9]
    call    puthex8
    mov     si, offset msg_post6a
    call    puts
    mov     al, [bx+10]
    call    puthex8
    mov     si, offset msg_posta0a
    call    puts
    mov     al, [bx+11]
    call    puthex8
    call    putnl
    inc     di
    jmp     pi_loop
pi_done:
    ret

/* print_plane: one row per sampled register. ADDR is the offset inside the
 * 0xE0000 window, printed as 0E<off>, so the row names the physical address it
 * read (0E0108 = 0xE0108). NZ is 1 when that register has been seen non-zero -
 * the engine-used signal. LAST is the last byte seen (00 when never sampled). */
print_plane:
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_plane
    call    puts
    mov     ax, [pl_view_n]
    call    puthex16
    mov     si, offset msg_plane_nz
    call    puts
    mov     ax, [pl_nz]
    call    puthex16
    mov     si, offset msg_nopchk
    call    puts
    mov     al, [sw]
    and     al, SW_NOP
    call    puthex8
    call    putnl
    xor     di, di                  /* the slot index */
ppg_loop:
    cmp     di, PLANE_N
    jae     ppg_done
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_plreg
    call    puts
    mov     si, offset msg_0e
    call    puts
    mov     bx, di
    add     bx, bx
    mov     ax, [plane_tab + bx]
    call    puthex16
    mov     si, offset msg_last
    call    puts
    mov     al, [pl_last + di]
    call    puthex8
    mov     si, offset msg_nz1
    call    puts
    mov     cx, di
    mov     bx, 1
    shl     bx, cl
    mov     ax, [pl_nz]
    test    ax, bx
    jz      ppg_zero
    mov     dl, '1'
    jmp     ppg_nzout
ppg_zero:
    mov     dl, '0'
ppg_nzout:
    call    putc
    call    putnl
    inc     di
    jmp     ppg_loop
ppg_done:
    ret

/* print_samp: the coverage row. Read it BEFORE concluding anything from an
 * unchanged POST row: a run whose N/MODE256T say nothing was ever sampled is a
 * capture that did not observe. I18REC counts nested deliveries passed through
 * unrecorded. */
print_samp:
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_samp
    call    puts
    mov     ax, [samp_n]
    call    puthex16
    mov     si, offset msg_viewon
    call    puts
    mov     ax, [pl_view_n]
    call    puthex16
    mov     si, offset msg_m256t
    call    puts
    mov     eax, [mode256_t]
    call    puthex32
    mov     si, offset msg_i18n
    call    puts
    mov     ax, [i18_seen]
    call    puthex16
    mov     si, offset msg_i18kept
    call    puts
    mov     ax, [i18_n]
    call    puthex16
    mov     si, offset msg_i18drop
    call    puts
    mov     ax, [i18_drop]
    call    puthex16
    mov     si, offset msg_i18rec
    call    puts
    mov     ax, [i18_rec_drop]
    call    puthex16
    call    putnl
    ret

print_run:
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_run
    call    puts
    mov     al, [exec_cf]
    call    puthex8
    mov     si, offset msg_ax
    call    puts
    mov     ax, [exec_ax]
    call    puthex16
    call    putnl
    ret

fail_print:
    cmp     byte ptr [run_fail], 0
    je      fp_none
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_fail
    call    puts
    mov     al, [run_fail]
    call    puthex8
    call    putnl
    ret
fp_none:
    mov     si, offset msg_pw
    call    puts
    mov     si, offset msg_nofail
    call    puts
    ret

print_usage:
    mov     si, offset msg_usage1
    call    puts
    mov     si, offset msg_usage2
    call    puts
    mov     si, offset msg_usage3
    call    puts
    mov     si, offset msg_usage4
    call    puts
    ret

/* ------------------------------------------------------------------ */
/* the EXEC itself                                                       */
/* ------------------------------------------------------------------ */
/* The parameter block for a normal AL=0 load: the environment segment (0 =
 * inherit the parent's), the command line pointer, and two FCB pointers. The
 * FCBs point at a BLANK pair (drive 0, blank name) - what DOS's parser leaves
 * for a load with no arguments - because this wrapper hands the child an
 * arguments-only tail and cannot re-parse one for it; unlike a self-relaunching
 * shell, a wrapper that passed its OWN PSP:5C/6C would give the child the FCBs
 * parsed from the wrapper's line. */
build_exec:
    mov     word ptr [exec_pb+0], 0
    mov     word ptr [exec_pb+2], offset child_tail
    mov     word ptr [exec_pb+4], cs
    mov     word ptr [exec_pb+6], offset fcb_blank
    mov     word ptr [exec_pb+8], cs
    mov     word ptr [exec_pb+10], offset fcb_blank+16
    mov     word ptr [exec_pb+12], cs
    mov     word ptr [exec_pb+14], 0
    mov     word ptr [exec_pb+16], 0
    ret

exec_child:
    cmp     byte ptr [child_name], 0
    jne     ec_go
    mov     si, offset msg_noname
    call    puts
    inc     byte ptr [run_fail]
    mov     byte ptr [exec_cf], 2
    ret
ec_go:
    /* THE ABI, exactly: DS:DX -> the child's ASCIZ filename, ES:BX -> the
     * parameter block. Passing the block in both makes DOS read its filename out
     * of the block's first byte - the environment word 0 - and the child never
     * loads. */
    push    cs
    pop     es
    mov     ax, 0x4B00
    mov     dx, offset child_name
    mov     bx, offset exec_pb
    int     0x21
    mov     byte ptr [exec_cf], 0
    jnc     ec_ok
    mov     byte ptr [exec_cf], 1
    inc     byte ptr [run_fail]
ec_ok:
    mov     [exec_ax], ax
    ret

/* res_paras: AX = the size of this program's own DOS block, in paragraphs. One
 * home for it: the AH=4Ah shrink comes from here. */
res_paras:
    mov     ax, offset image_end
    add     ax, 15
    shr     ax, 4
    ret

/* ------------------------------------------------------------------ */
/* data                                                                 */
/* ------------------------------------------------------------------ */
sw_nop:         .asciz "/NOP"

/* The vector ledger: one 8-byte row per hooked vector -
 *   +0 word: the vector number        +2 word: this program's handler
 *   +4 word: the as-found offset      +6 word: the as-found segment
 * The two as-found words ARE the far pointer the handlers chain through (offset
 * first, then segment - exactly an m16:16 operand), so the install loop writes
 * the ledger entry and the chain reads the same bytes: there is no second copy
 * of the old vector that could drift, and the restore loop's read-back compares
 * against the pair it saved. */
vec_tab:
    .word 0x0018, h_i18,   0, 0
    .word 0x001C, h_i1c,   0, 0
    .word 0x0023, h_iret,  0, 0
    .word 0x0024, h_int24, 0, 0

    .equ VT_I18, vec_tab + 4
    .equ VT_I1C, vec_tab + 12

/* the ten sampled window offsets, in slot order (slot i is pl_last + i) */
plane_tab:
    .word PL_0004, PL_0006, PL_0104, PL_0108, PL_0109
    .word PL_010C, PL_0110, PL_0112, PL_0114, PL_0118

msg_begin:      .asciz "PEGCWATCH BEGIN V=1\r\n"
msg_end:        .asciz "PEGCWATCH END V=1\r\n"
msg_pw:         .asciz "PEGCWATCH "
lbl_base:       .asciz "BASE"
lbl_post:       .asciz "POST"
lbl_mode:       .asciz "MODE"
lbl_i18:        .asciz "I18"
msg_t:          .asciz " T="
msg_p6a:        .asciz " P6A="
msg_a0a:        .asciz " A0A="
msg_a04:        .asciz " A04="
msg_a08:        .asciz " A08="
msg_a0d:        .asciz " A0D="
msg_a03:        .asciz " A03="
msg_w54d:       .asciz " W54D="
msg_m68:        .asciz " M68="
msg_cmd:        .asciz "CMD NAME="
msg_tail:       .asciz " TAIL=["
msg_hook:       .asciz "HOOK VEC="
msg_old:        .asciz " OLD="
msg_new:        .asciz " NEW="
msg_vec:        .asciz "VEC VEC="
msg_back:       .asciz " BACK="
msg_ok:         .asciz " OK"
msg_notrest:    .asciz " BAD (NOT RESTORED)"
msg_mem:        .asciz "MEM PH="
msg_free:       .asciz " FREE="
msg_para:       .asciz " PARA "
msg_kb:         .asciz "KB"
msg_modes:      .asciz "MODES N="
msg_over:       .asciz " OVER="
msg_n:          .asciz " N="
msg_nz:         .asciz " NZ="
msg_nopchk:     .asciz " NOP="
msg_plane:      .asciz "PLANE VIEWON="
msg_plane_nz:   .asciz " NZ="
msg_plreg:      .asciz "PLREG ADDR="
msg_0e:         .asciz "0E"
msg_last:       .asciz " LAST="
msg_nz1:        .asciz " NZ="
msg_samp:       .asciz "SAMP N="
msg_viewon:     .asciz " VIEWON="
msg_m256t:      .asciz " MODE256T="
msg_i18n:       .asciz " I18="
msg_i18kept:    .asciz " I18KEPT="
msg_i18drop:    .asciz " I18DROP="
msg_i18rec:     .asciz " I18REC="
msg_ax:         .asciz " AX="
msg_bx:         .asciz " BX="
msg_cx:         .asciz " CX="
msg_dx:         .asciz " DX="
msg_pre6a:      .asciz " PRE6A="
msg_prea0a:     .asciz " PREA0A="
msg_post6a:     .asciz " POST6A="
msg_posta0a:    .asciz " POSTA0A="
msg_run:        .asciz "RUN CF="
msg_fail:       .asciz "FAIL N="
msg_nofail:     .asciz "NOFAIL\r\n"
msg_noname:     .asciz "PEGCWATCH FAIL n=02 (no child filename - nothing was run)\r\n"
msg_shrinkfail: .asciz "PEGCWATCH FAIL n=01 (int 21h ah=4ah refused to shrink this block; nothing was run)\r\n"
msg_badsw:      .asciz "PEGCWATCH WARN unknown switch "
msg_usage1:     .asciz "PEGCWATCH USAGE: PEGCWATCH [/NOP] <program> [args]   - run a child under the PEGC watcher\r\n"
msg_usage2:     .asciz "PEGCWATCH USAGE: PEGCWATCH                            - no child: print this machine's PEGC state\r\n"
msg_usage3:     .asciz "PEGCWATCH USAGE: /NOP skips the plane-register sampling (the only part that reads a\r\n"
msg_usage4:     .asciz "PEGCWATCH USAGE: window the child may be using). Rows: see pegcwatch_decode.py.\r\n"

/* ------------------------------------------------------------------ */
/* state                                                                */
/* ------------------------------------------------------------------ */
sw:            .byte 0
have_child:    .byte 0
run_fail:      .byte 0
exec_cf:       .byte 0
exec_ax:       .word 0
tail_end:      .word 0
mem_para:      .word 0
child_name:    .space NAME_MAX
child_tail:    .space 130
exec_pb:       .space 20
dec_buf:       .space 16

/* the blank FCB the child's PSP:5C/6C are filled from: drive 0 and a blank
 * 11-byte name, two 16-byte FCBs. */
fcb_blank:     .byte 0
               .fill 11, 1, 0x20
               .fill 4, 1, 0
               .byte 0
               .fill 11, 1, 0x20
               .fill 4, 1, 0

cap_a:         .space 8
cap_pre:       .space 8
cap_post:      .space 8

/* the ISR scratch: a hook body is atomic (the gate cleared IF and the body never
 * sets it), so one set cannot be interleaved by a second delivery of the SAME
 * hook. The INT 18h hook's resume also runs with IF clear; a NESTED delivery is
 * passed through unrecorded (i18_rec_drop) rather than overwriting the outer
 * call's identity, the same guard logtime uses for INT 13h. */
s_ax:          .word 0
s_bx:          .word 0
s_cx:          .word 0
s_dx:          .word 0
s_t0:          .space 4
i18_seen:      .word 0
i18_n:         .word 0
i18_drop:      .word 0
i18_rec_drop:  .word 0
i18_depth:     .word 0
samp_n:        .word 0
s_6a:          .byte 0
s_9a0a:        .byte 0
s_9a0_04:      .byte 0
s_54d:         .byte 0
last_6a:       .byte 0xFF
last_9a0a:     .byte 0xFF
last_9a0_04:   .byte 0xFF
last_54d:      .byte 0xFF
mode_n:        .word 0
mode_over:     .word 0
mode256_t:     .space 4
pl_last:       .space PLANE_N
pl_nz:         .word 0
pl_view_n:     .word 0
back_o:        .word 0
back_s:        .word 0

mode_rec:      .space MODE_MAX*8
i18_rec:       .space I18_MAX*16

/* the wrapper's own stack, INSIDE the block it keeps: SP is set to offset
 * image_end after the AH=4Ah, so the stack grows down into this. */
    .space 0x400

/* image_end must be the LAST label in the image: the AH=4Ah block size is this
 * offset rounded up to a paragraph, and SP is set to it. */
image_end:
    .byte 0

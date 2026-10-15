# The CPU-throttle tier's guest (tests/pc9821/tb_pc9821_throttle.sv). GNU as, 16-bit real
# mode, assembled into the 32 KiB ITF bank by firmware/diagnostic/build.py --itf-src.
#
# It drives every platform<->CPU handshake the gated clock has to carry (fork
# src/z486/docs/cpu-review2-2026-10-10.md section 7 point 9): a CPU reset (`out 0xF0`), I/O writes and
# an I/O read, burst line fills (the timed code runs from cacheable RAM, and the checksum
# re-reads the filled region after a whole-L1 flush), the 0x043F cache flush, and INTA (the
# VSYNC interrupt on IRQ2, as the diagnostic POST takes it). The two timed sections are a
# 12288-dword REP STOSD and a 4096-iteration DEC/JNZ, the shapes of the fork's own
# test_throttle_rate.py: a throttle that acts only at instruction boundaries runs the REP
# unthrottled.
#
# POST codes on port 0x0EE0 (the bench keys on them):
#   C8 the reset leg (then `out 0xF0`)   C0 REP start   C1 REP end / loop start
#   C2 loop end    C3 checksum stored at 0000:0610    C4 the interrupt was taken
#   C6 the re-request leg starts (IRQ0 + IRQ2)   C5 IRQ0 was taken after the IRQ2 ack
#   CF done        EF the interrupt never arrived

.intel_syntax noprefix
.code16

.set PAYLOAD, 0x2000            # where the timed code runs: cacheable guest RAM

.org 0
start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov ss, ax
    mov sp, 0x7f00

    # The reset leg: the first entry of each run marks low RAM and resets the CPU with
    # `out 0xF0` (pc9821_iobus's CPU-reset class); the re-entry finds the mark and clears it,
    # so the bench's next run (a platform reset, which keeps RAM) takes the leg again.
    cmp byte ptr [0x0600], 0x5a
    je  reset_done
    mov byte ptr [0x0600], 0x5a
    mov al, 0xc8
    mov dx, 0x0ee0
    out dx, al
    out 0xf0, al
1:  hlt
    jmp 1b
reset_done:
    mov byte ptr [0x0600], 0

    # Copy the payload into RAM and run it there, so its fetches are cached I-cache line
    # fills rather than uncached ROM reads (a throttled CPU sees memory as faster, so a
    # memory-bound timed loop could not show the clock ratio).
    push cs
    pop ds
    xor ax, ax
    mov es, ax
    mov si, offset payload
    mov di, PAYLOAD
    mov cx, offset payload_end - payload
    rep movsb
    xor ax, ax
    mov ds, ax
    ljmp 0x0000, PAYLOAD

payload:
    mov al, 0xc0
    mov dx, 0x0ee0
    out dx, al
    # Timed 1: REP STOSD, 12288 dwords at 1000:0000.
    mov ax, 0x1000
    mov es, ax
    xor di, di
    mov ecx, 12288
    mov eax, 0x5a5a1234
    rep stosd
    mov al, 0xc1
    out dx, al
    # Timed 2: DEC/JNZ x 4096 (cached, CPU-bound).
    mov cx, 4096
2:  dec cx
    jnz 2b
    mov al, 0xc2
    out dx, al

    # Data-dependent work over the first 1024 dwords: each result feeds the next.
    mov ax, 0x1000
    mov ds, ax
    xor si, si
    mov ebx, 0x13579bdf
    mov cx, 1024
3:  mov eax, [si]
    xor eax, ebx
    rol eax, 5
    add eax, ecx
    mov [si], eax
    mov ebx, eax
    add si, 4
    loop 3b
    # An I/O read (the system port 0x31 strap, constant) mixed in.
    in  al, 0x31
    movzx eax, al
    add ebx, eax
    # The whole-L1 flush (0x043F = 0xA0): the write completes on the CPU's flush done.
    mov dx, 0x043f
    mov al, 0xa0
    out dx, al
    # The checksum re-reads the whole region through line fills.
    xor si, si
    mov cx, 12288
    xor edx, edx
4:  lodsd
    add edx, eax
    rol edx, 1
    loop 4b
    add edx, ebx
    xor ax, ax
    mov ds, ax
    mov dword ptr [0x0610], edx
    mov al, 0xc3
    mov dx, 0x0ee0
    out dx, al

    # INTA: the VSYNC interrupt on IRQ2 (vector 0x0A), as post.s takes it.
    xor ax, ax
    mov es, ax
    mov word ptr es:[0x28], PAYLOAD + (int_vsync - payload)
    mov word ptr es:[0x2a], 0
    mov al, 0x11                # ICW1: cascade, edge, ICW4 follows
    out 0x00, al
    mov al, 0x08                # ICW2: master base vector
    out 0x02, al
    mov al, 0x80                # ICW3: slave on IR7
    out 0x02, al
    mov al, 0x1d                # ICW4
    out 0x02, al
    mov al, 0xfb                # IMR: IRQ2 (VSYNC) only
    out 0x02, al
    mov byte ptr [0x0500], 0
    sti
    out 0x64, al                # arm the VSYNC interrupt
    mov bx, 64
5:  mov cx, 0xffff
6:  cmp byte ptr [0x0500], 0
    jne 7f
    loop 6b
    dec bx
    jnz 5b
    mov al, 0xef
    mov dx, 0x0ee0
    out dx, al
    jmp 8f
7:  cli
    mov al, 0xc4
    mov dx, 0x0ee0
    out dx, al

    # The re-request leg: IRQ2 (VSYNC) and IRQ0 unmasked. The bench raises IR0 a few
    # platform cycles after the master acknowledges IRQ2, so the 8259's INT drops at that
    # acknowledge and comes straight back for the higher-priority IRQ0 - for less than one
    # CPU clock period at a throttled setting. A 486 samples INTR as a level, so IRQ0 must
    # be taken once the IRQ2 handler's IRET sets IF again (the guest waits for it without a
    # bound; the bench's own timeout is the verdict).
    mov word ptr es:[0x20], PAYLOAD + (int_irq0 - payload)
    mov word ptr es:[0x22], 0
    mov byte ptr [0x0502], 0
    mov al, 0xc6
    out dx, al                  # the bench arms its IR0 trigger on this code
    mov al, 0xfa                # IMR: IRQ0 and IRQ2
    out 0x02, al
    out 0x64, al                # re-arm the VSYNC interrupt
    sti
9:  cmp byte ptr [0x0502], 0
    je  9b
    cli
    mov al, 0xc5
    mov dx, 0x0ee0
    out dx, al
    mov al, 0xcf
    out dx, al
8:  jmp 8b

int_irq0:
    push ax
    inc byte ptr [0x0502]
    mov al, 0x20                # non-specific EOI
    out 0x00, al
    pop ax
    iret

int_vsync:
    push ax
    inc byte ptr [0x0500]
    mov al, 0x20                # non-specific EOI
    out 0x00, al
    pop ax
    iret
payload_end:

# x86 reset starts at FFFFFFF0, mapped to ITF offset 7FF0.
.org 0x7ff0
    ljmp 0xf800, start

.org 0x8000

# Redistributable PC-98 fixed-disk IPL for deterministic ATA boot testing.
.intel_syntax noprefix
.code16
.text
.org 0
    jmp start
    nop
    nop
.org 4
    .ascii "IPL1"
start:
    cli
    xor ax, ax
    mov ds, ax
    mov dword ptr [0x0700], 0x0d05b007
    mov al, 0xa5
    mov dx, 0x0ee0          # out takes only an 8-bit immediate port
    out dx, al
    mov ax, 0xa000
    mov es, ax
    mov byte ptr es:[0x00a0], 'I'
    mov byte ptr es:[0x00a1], 0
    mov byte ptr es:[0x20a0], 0xe1
hang:
    jmp hang
.org 512

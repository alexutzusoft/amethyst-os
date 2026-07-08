; AmethystOS - Stage 1 Boot Sector
; Pure x86 real-mode assembly. Loaded by BIOS at 0x7C00.
; Prints "Hello, Amethyst!" and halts.

[BITS 16]
[ORG 0x7C00]

start:
    cli                     ; disable interrupts while we set up segments
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov ax, 0x0003          ; set video mode 3 (80x25 text) - clears screen
    int 0x10

    mov si, msg
.print_char:
    lodsb                   ; load byte at [si] into al, advance si
    or al, al
    jz .done
    mov ah, 0x0E            ; BIOS teletype output
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp .print_char

.done:
    cli
.hang:
    hlt
    jmp .hang

msg db "Hello, Amethyst!", 0

times 510 - ($ - $$) db 0     ; pad to 510 bytes
dw 0xAA55                     ; boot signature

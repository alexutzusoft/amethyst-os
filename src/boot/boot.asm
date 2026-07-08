; AmethystOS - Stage 1 Boot Sector
; Real mode -> Protected mode -> prints "Hello, Amethyst!" via VGA memory.
; Loaded by BIOS at 0x7C00.

[BITS 16]
[ORG 0x7C00]

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    mov ax, 0x0003          ; set video mode 3 (80x25 text) - clears screen
    int 0x10

    call enable_a20
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1                ; set PE (protection enable) bit
    mov cr0, eax

    jmp CODE_SEG:protected_mode_start   ; far jump flushes the prefetch queue

; --- Fast A20 gate enable (via system control port 0x92) ---
enable_a20:
    in al, 0x92
    or al, 2
    out 0x92, al
    ret

; --- Global Descriptor Table: null, flat code, flat data ---
gdt_start:
gdt_null:
    dq 0x0

gdt_code:
    dw 0xFFFF        ; limit low
    dw 0x0000        ; base low
    db 0x00          ; base mid
    db 10011010b     ; access: present, ring0, code, executable, readable
    db 11001111b     ; flags: 4K granularity, 32-bit + limit high
    db 0x00          ; base high

gdt_data:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b     ; access: present, ring0, data, writable
    db 11001111b
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

[BITS 32]
protected_mode_start:
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    mov esi, msg
    mov edi, 0xB8000         ; VGA text buffer
    mov ah, 0x07              ; light grey on black
.print_char:
    mov al, [esi]
    or al, al
    jz .done
    mov [edi], al
    mov [edi + 1], ah
    add edi, 2
    inc esi
    jmp .print_char

.done:
    cli
.hang:
    hlt
    jmp .hang

msg db "Hello, Amethyst!", 0

times 510 - ($ - $$) db 0
dw 0xAA55

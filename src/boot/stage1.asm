; AmethystOS - Stage 1
; Real mode -> Protected mode -> Long mode, then hands off to kernel.asm.
; Loaded by BIOS/El Torito at 0x7C00: the whole combined stage1+kernel
; blob (see tools/build.sh -boot-load-size) is auto-loaded as one flat
; chunk, no disk I/O needed yet - kernel.asm is just %include'd below so
; it assembles right after stage1 in the same binary.

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

    jmp CODE32_SEG:protected_mode_start   ; far jump flushes the prefetch queue

; --- Fast A20 gate enable (via system control port 0x92) ---
enable_a20:
    in al, 0x92
    or al, 2
    out 0x92, al
    ret

; --- Global Descriptor Table: null, flat 32-bit code/data, flat 64-bit code ---
gdt_start:
gdt_null:
    dq 0x0

gdt_code32:
    dw 0xFFFF        ; limit low
    dw 0x0000        ; base low
    db 0x00          ; base mid
    db 10011010b     ; access: present, ring0, code, executable, readable
    db 11001111b     ; flags: 4K granularity, 32-bit + limit high
    db 0x00          ; base high

gdt_data32:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b     ; access: present, ring0, data, writable
    db 11001111b
    db 0x00

gdt_code64:
    dw 0x0000
    dw 0x0000
    db 0x00
    db 10011010b     ; access: present, ring0, code, executable, readable
    db 00100000b     ; flags: long-mode code segment (L bit set)
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE32_SEG equ gdt_code32 - gdt_start
DATA32_SEG equ gdt_data32 - gdt_start
CODE64_SEG equ gdt_code64 - gdt_start

; --- Page table locations (identity-mapped low memory scratch area) ---
PML4_ADDR equ 0x1000
PDPT_ADDR equ 0x2000
PD_ADDR   equ 0x3000

%include "src/boot/kernel.asm"

times 8192 - ($ - $$) db 0

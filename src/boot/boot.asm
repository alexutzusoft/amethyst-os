; AmethystOS - Stage 1 Boot Sector
; Real mode -> Protected mode -> Long mode -> prints "Hello, Amethyst!" via VGA memory.
; Loaded by BIOS/El Torito at 0x7C00. First 2048 bytes of the ISO boot image
; are loaded into memory (see tools/build.sh -boot-load-size 4), giving us
; room beyond the classic 512-byte limit for the page tables long mode needs.

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

[BITS 32]
protected_mode_start:
    mov ax, DATA32_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; zero the three page-table pages (0x1000-0x3FFF)
    mov edi, PML4_ADDR
    xor eax, eax
    mov ecx, 3 * 1024        ; 3 pages * 4096 bytes / 4 bytes per dword
    rep stosd

    ; PML4[0] -> PDPT, PDPT[0] -> PD, PD[0] -> 2MB identity-mapped page
    mov dword [PML4_ADDR], PDPT_ADDR | 0b11   ; present + writable
    mov dword [PDPT_ADDR], PD_ADDR   | 0b11
    mov dword [PD_ADDR],   0x000000  | 0b10000011 ; present + writable + 2MB page

    mov eax, PML4_ADDR
    mov cr3, eax

    mov eax, cr4
    or eax, 1 << 5             ; enable PAE
    mov cr4, eax

    mov ecx, 0xC0000080        ; EFER MSR
    rdmsr
    or eax, 1 << 8              ; set LME (Long Mode Enable)
    wrmsr

    mov eax, cr0
    or eax, 1 << 31             ; enable paging
    mov cr0, eax

    jmp CODE64_SEG:long_mode_start

[BITS 64]
long_mode_start:
    mov ax, DATA32_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    mov rsi, msg
    mov rdi, 0xB8000          ; VGA text buffer
    mov ah, 0x0D               ; light magenta on black
.print_char:
    mov al, [rsi]
    or al, al
    jz .done
    mov [rdi], al
    mov [rdi + 1], ah
    add rdi, 2
    inc rsi
    jmp .print_char

.done:
    cli
.hang:
    hlt
    jmp .hang

msg db "Hello, Amethyst!", 0

times 2048 - ($ - $$) db 0

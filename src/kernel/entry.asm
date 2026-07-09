[BITS 32]
protected_mode_start:
    mov ax, DATA32_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; zero the page-table pages and the IDT page (0x1000-0x4FFF)
    mov edi, PML4_ADDR
    xor eax, eax
    mov ecx, 4 * 1024        ; 4 pages * 4096 bytes / 4 bytes per dword
    rep stosd

    ; PML4[0] -> PDPT, PDPT[0] -> PD, PD[0..511] -> 512 identity 2MB pages (1GB).
    ; The wider map (vs. a single 2MB page) is so peek/mem/poke and the
    ; shutdown command's ACPI table scan can touch memory outside the first
    ; 2MB without page-faulting (there's no page-fault handler installed).
    mov dword [PML4_ADDR], PDPT_ADDR | 0b11   ; present + writable
    mov dword [PDPT_ADDR], PD_ADDR   | 0b11

    mov edi, PD_ADDR
    mov eax, 0b10000011        ; present + writable + 2MB page, address 0
    mov ecx, 512
.map_pd_loop:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .map_pd_loop

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

IDT_ADDR equ 0x4000

[BITS 64]
long_mode_start:
    mov ax, DATA32_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    mov qword [cursor_pos], 0
    mov rsi, msg
    call print_string

    call setup_idt
    call remap_pic
    call enable_kbd_irq
    call enable_mouse_port
    call mouse_detect_wheel
    call setup_pit

    mov al, 0x0D
    call print_char
    mov rsi, prompt
    call print_string
    mov rax, [cursor_pos]
    mov [line_start_pos], rax

    sti
.idle:
    hlt
    jmp .idle

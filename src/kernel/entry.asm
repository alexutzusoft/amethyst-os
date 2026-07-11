[BITS 32]
protected_mode_start:
    mov ax, DATA32_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; zero the page-table pages (0x1000-0x4FFF) - leaves 0x5000 (BIOS mmap
    ; capture) untouched, and the IDT page is zeroed separately below since
    ; it isn't contiguous with these (see PML4_ADDR comment).
    mov edi, PML4_ADDR
    xor eax, eax
    mov ecx, 4 * 1024        ; 4 pages * 4096 bytes / 4 bytes per dword
    rep stosd
    mov edi, IDT_ADDR
    xor eax, eax
    mov ecx, 1024
    rep stosd

    ; PML4[0] -> PDPT. PDPT[0] -> PD0 (identity 2MB pages for 0-1GB).
    ; PDPT[3] -> PD3 (identity 2MB pages for 3-4GB, the usual PCI MMIO hole).
    ; PDPT[1]/[2] (1-3GB) stay not-present/unmapped.
    mov dword [PML4_ADDR], PDPT_ADDR | 0b11   ; present + writable
    mov dword [PDPT_ADDR],      PD0_ADDR | 0b11
    mov dword [PDPT_ADDR + 24], PD3_ADDR | 0b11

    mov edi, PD0_ADDR
    mov eax, 0b10000011        ; present + writable + 2MB page, address 0
    mov ecx, 512
.map_pd0_loop:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .map_pd0_loop

    mov edi, PD3_ADDR
    mov eax, 0xC0000000 | 0b10000011   ; present + writable + 2MB page, address 3GB
    mov ecx, 512
.map_pd3_loop:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .map_pd3_loop

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

IDT_ADDR equ 0x6000   ; clear of the 0x5000-0x5607 BIOS mmap capture and 0x7C00 load addr

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
    call net_init

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

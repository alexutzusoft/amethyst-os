; AmethystOS Kernel - everything from protected mode onward.
; %include'd by stage1.asm right after the GDT/segment equs it needs,
; and assembled into the same flat binary (no separate linking step).

; --- VGA text-mode framebuffer layout ---
VGA_MEM       equ 0xB8000
VGA_COLS      equ 80
VGA_ROWS      equ 25
VGA_ROW_BYTES equ VGA_COLS * 2
VGA_SIZE      equ VGA_ROW_BYTES * VGA_ROWS      ; 4000: one byte past the last cell
VGA_LAST_ROW  equ VGA_ROW_BYTES * (VGA_ROWS - 1) ; 3840: start of the bottom row
VGA_ATTR      equ 0x0D                            ; light magenta on black

; --- 8259 PIC ports/values ---
PIC1_CMD  equ 0x20
PIC1_DATA equ 0x21
PIC2_CMD  equ 0xA0
PIC2_DATA equ 0xA1
PIC_EOI            equ 0x20
ICW1_INIT          equ 0x11
PIC1_VECTOR_OFFSET equ 0x20
PIC2_VECTOR_OFFSET equ 0x28
ICW3_MASTER        equ 0x04
ICW3_SLAVE         equ 0x02
ICW4_8086          equ 0x01
PIC1_MASK          equ 0xFC   ; unmask IRQ0 (timer) + IRQ1 (keyboard)
PIC2_MASK_ALL      equ 0xFF   ; mask everything on the slave

IRQ0_VECTOR equ 0x20
IRQ1_VECTOR equ 0x21

; --- 8042 keyboard controller ports/values ---
KBD_DATA_PORT equ 0x60
KBD_CMD_PORT  equ 0x64
KBD_CMD_READ_CFG        equ 0x20
KBD_CMD_WRITE_CFG        equ 0x60
KBD_IRQ1_ENABLE_BIT      equ 0x01
KBD_STATUS_OUTPUT_FULL   equ 0x01
KBD_STATUS_INPUT_FULL    equ 0x02
KBD_BREAK_BIT      equ 0x80
KBD_SCANCODE_MASK  equ 0x7F
SC_LSHIFT   equ 0x2A
SC_RSHIFT   equ 0x36
SC_CAPSLOCK equ 0x3A

; --- CRT controller (hardware cursor) ports/registers ---
CRTC_INDEX       equ 0x3D4
CRTC_DATA        equ 0x3D5
CRTC_CURSOR_LOW  equ 0x0F
CRTC_CURSOR_HIGH equ 0x0E

; --- ASCII control characters ---
ASCII_CR equ 0x0D
ASCII_BS equ 0x08

CMD_BUFFER_SIZE equ 128
EXEC_BUFFER_SIZE equ 256

PIT_HZ equ 100
PIT_DIVISOR equ 11931   ; 1193182 / PIT_HZ, rounded

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
    call setup_pit

    mov al, 0x0D
    call print_char
    mov rsi, prompt
    call print_string

    sti
.idle:
    hlt
    jmp .idle

; --- Build IDT entries (vector 0x20 timer, vector 0x21 keyboard) and load it ---
setup_idt:
    mov rax, timer_isr
    mov rdi, IDT_ADDR + (IRQ0_VECTOR * 16)
    call write_idt_entry

    mov rax, keyboard_isr
    mov rdi, IDT_ADDR + (IRQ1_VECTOR * 16)
    call write_idt_entry

    lidt [idt_descriptor]
    ret

write_idt_entry:
    mov word [rdi], ax             ; offset bits 0-15
    mov word [rdi + 2], CODE64_SEG ; selector
    mov byte [rdi + 4], 0          ; IST = 0
    mov byte [rdi + 5], 0x8E       ; present, ring0, 64-bit interrupt gate
    shr rax, 16
    mov word [rdi + 6], ax         ; offset bits 16-31
    shr rax, 16
    mov dword [rdi + 8], eax       ; offset bits 32-63
    mov dword [rdi + 12], 0        ; reserved
    ret

; IRQ0 (PIT) is kept unmasked and just EOI'd here. Hypothesis: BIOS leaves
; IRQ0 in-service (via its own POST-time timer handling) without ever
; sending a matching EOI before we take over; remap_pic now sends a
; defensive EOI to both PICs before reinitializing to clear any such
; stuck ISR bit, since a pending higher-priority in-service IRQ0 can
; block delivery of lower-priority IRQs (like IRQ1) on some PICs/BIOS
; combos. Left IRQ0 unmasked as a safety net since we can't rule out the
; defensive EOI alone being sufficient without further interactive testing.
timer_isr:
    push rax
    inc qword [timer_ticks]
    mov al, PIC_EOI
    out PIC1_CMD, al
    pop rax
    iretq

; --- Program PIT channel 0 for PIT_HZ square-wave interrupts ---
setup_pit:
    push rax
    mov al, 0x36            ; channel 0, lobyte/hibyte, mode 3
    out 0x43, al
    call io_wait
    mov ax, PIT_DIVISOR
    out 0x40, al
    call io_wait
    mov al, ah
    out 0x40, al
    call io_wait
    pop rax
    ret

idt_descriptor:
    dw 0x0FFF
    dq IDT_ADDR

; --- I/O delay: an out to the unused POST diagnostic port costs one bus cycle ---
io_wait:
    out 0x80, al
    ret

; --- Remap the 8259 PICs so IRQs land at 0x20-0x2F, then mask all but IRQ1 ---
remap_pic:
    ; defensive EOI: clear any ISR bit BIOS left pending before we took over
    mov al, PIC_EOI
    out PIC1_CMD, al
    call io_wait
    out PIC2_CMD, al
    call io_wait

    mov al, ICW1_INIT
    out PIC1_CMD, al
    call io_wait
    out PIC2_CMD, al
    call io_wait
    mov al, PIC1_VECTOR_OFFSET
    out PIC1_DATA, al
    call io_wait
    mov al, PIC2_VECTOR_OFFSET
    out PIC2_DATA, al
    call io_wait
    mov al, ICW3_MASTER
    out PIC1_DATA, al
    call io_wait
    mov al, ICW3_SLAVE
    out PIC2_DATA, al
    call io_wait
    mov al, ICW4_8086
    out PIC1_DATA, al
    call io_wait
    out PIC2_DATA, al
    call io_wait
    mov al, PIC1_MASK
    out PIC1_DATA, al
    call io_wait
    mov al, PIC2_MASK_ALL
    out PIC2_DATA, al
    ret

; --- Ensure the 8042 keyboard controller has IRQ1 generation enabled ---
enable_kbd_irq:
    call kbd_wait_input
    mov al, KBD_CMD_READ_CFG   ; command: read controller command byte
    out KBD_CMD_PORT, al
    call kbd_wait_output
    in al, KBD_DATA_PORT
    or al, KBD_IRQ1_ENABLE_BIT
    mov bl, al

    call kbd_wait_input
    mov al, KBD_CMD_WRITE_CFG  ; command: write controller command byte
    out KBD_CMD_PORT, al
    call kbd_wait_input
    mov al, bl
    out KBD_DATA_PORT, al
    ret

kbd_wait_input:
    in al, KBD_CMD_PORT
    test al, KBD_STATUS_INPUT_FULL
    jnz kbd_wait_input
    ret

kbd_wait_output:
    in al, KBD_CMD_PORT
    test al, KBD_STATUS_OUTPUT_FULL
    jz kbd_wait_output
    ret

; --- IRQ1 handler: read scancode, translate, echo, buffer, run on Enter ---
keyboard_isr:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    in al, KBD_DATA_PORT
    mov bl, al                     ; bl = raw scancode, break bit included

    mov al, bl
    and al, KBD_SCANCODE_MASK       ; base scancode, ignoring make/break
    cmp al, SC_LSHIFT
    je .shift_key
    cmp al, SC_RSHIFT
    je .shift_key
    cmp al, SC_CAPSLOCK
    je .capslock_key

    test bl, KBD_BREAK_BIT
    jnz .eoi                 ; ignore other key-release codes

    movzx rbx, bl
    cmp rbx, scancode_table_end - scancode_table
    jae .eoi

    cmp byte [shift_state], 0
    je .use_base_table
    mov al, [shifted_scancode_table + rbx]
    jmp .have_char
.use_base_table:
    mov al, [scancode_table + rbx]
.have_char:
    or al, al
    jz .eoi                  ; unmapped key

    cmp byte [caps_lock], 0
    je .no_caps_adjust
    cmp byte [shift_state], 0
    jne .caps_with_shift
    cmp al, 'a'
    jb .no_caps_adjust
    cmp al, 'z'
    ja .no_caps_adjust
    sub al, 0x20              ; caps, no shift: lowercase letter -> uppercase
    jmp .no_caps_adjust
.caps_with_shift:
    cmp al, 'A'
    jb .no_caps_adjust
    cmp al, 'Z'
    ja .no_caps_adjust
    add al, 0x20              ; caps + shift: uppercase letter -> lowercase
.no_caps_adjust:

    cmp al, ASCII_CR
    je .handle_enter
    cmp al, ASCII_BS
    je .handle_backspace

    movzx rcx, byte [cmd_len]
    cmp rcx, CMD_BUFFER_SIZE - 1
    jae .eoi
    mov [cmd_buffer + rcx], al
    inc byte [cmd_len]
    call print_char
    jmp .eoi

.handle_backspace:
    cmp byte [cmd_len], 0
    je .eoi
    dec byte [cmd_len]
    call print_char
    jmp .eoi

.shift_key:
    test bl, KBD_BREAK_BIT
    jz .shift_make
    mov byte [shift_state], 0
    jmp .eoi
.shift_make:
    mov byte [shift_state], 1
    jmp .eoi

.capslock_key:
    test bl, KBD_BREAK_BIT
    jnz .eoi                 ; only toggle on the make code
    xor byte [caps_lock], 1
    jmp .eoi

.handle_enter:
    movzx rcx, byte [cmd_len]
    mov byte [cmd_buffer + rcx], 0
    call print_char
    call process_command
    mov byte [cmd_len], 0
    mov rsi, prompt
    call print_string

.eoi:
    mov al, PIC_EOI
    out PIC1_CMD, al
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    iretq

; --- Look up cmd_buffer in command_table and dispatch to its handler.
; Each table entry is {name_ptr, name_len, handler_ptr}, 24 bytes, and the
; table ends with a zero name_ptr. A handler is called with rsi pointing
; at its (possibly empty) nul-terminated argument string. ---
process_command:
    cmp byte [cmd_buffer], 0
    je .done

    mov r11, command_table
.find_loop:
    mov rax, [r11]
    or rax, rax
    jz .not_found

    mov r9, [r11 + 8]           ; command name length
    mov r10, [r11 + 16]         ; handler address

    mov rsi, cmd_buffer
    mov rdi, rax
    mov rcx, r9
    repe cmpsb
    jne .next_entry

    mov al, [cmd_buffer + r9]   ; char right after the matched name
    or al, al
    jz .call_handler             ; e.g. "echo" with no arguments
    cmp al, ' '
    je .call_handler
    jmp .next_entry                ; e.g. "echoX" is not a match

.next_entry:
    add r11, 24
    jmp .find_loop

.call_handler:
    lea rsi, [cmd_buffer + r9]  ; defaults to the trailing nul (no args)
    cmp al, ' '
    jne .invoke
    lea rsi, [cmd_buffer + r9 + 1]
.invoke:
    call r10
    jmp .newline_only

.not_found:
    mov rsi, unknown_msg
    call print_string
    mov rsi, cmd_buffer
    call print_string

.newline_only:
    mov al, ASCII_CR
    call print_char
.done:
    ret

; --- "echo" handler: rsi -> nul-terminated argument string ---
cmd_echo:
    call print_string
    ret

; --- "run" handler: rsi -> nul-terminated hex-byte string, e.g.
; "b8 34 12 cd 10 c3". Decodes it straight into exec_buffer and calls
; into it - no validation of what the bytes actually do, no sandboxing;
; a bad or missing `ret` will crash or hang the kernel outright. That's
; the point: this is a deliberately unguarded raw-machine-code runner. ---
cmd_run:
    lea rdi, [exec_buffer]
    xor rcx, rcx
.parse_loop:
    call skip_spaces
    mov al, [rsi]
    or al, al
    jz .execute
    call hex_nibble
    jc .bad_hex
    mov bl, al
    shl bl, 4
    inc rsi
    mov al, [rsi]
    call hex_nibble
    jc .bad_hex
    or bl, al
    inc rsi
    cmp rcx, EXEC_BUFFER_SIZE
    jae .too_long
    mov [rdi + rcx], bl
    inc rcx
    jmp .parse_loop
.execute:
    or rcx, rcx
    jz .ret
    call exec_buffer
.ret:
    ret
.bad_hex:
    mov rsi, run_bad_hex_msg
    call print_string
    ret
.too_long:
    mov rsi, run_too_long_msg
    call print_string
    ret

; --- Skip spaces at RSI (used between hex byte pairs) ---
skip_spaces:
    mov al, [rsi]
    cmp al, ' '
    jne .done
    inc rsi
    jmp skip_spaces
.done:
    ret

; --- Convert ASCII hex digit in AL to its 4-bit value in AL; CF set if
; AL isn't a valid hex digit. ---
hex_nibble:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .digit
    cmp al, 'A'
    jb .bad
    cmp al, 'F'
    jbe .upper
    cmp al, 'a'
    jb .bad
    cmp al, 'f'
    ja .bad
    sub al, 'a' - 10
    clc
    ret
.upper:
    sub al, 'A' - 10
    clc
    ret
.digit:
    sub al, '0'
    clc
    ret
.bad:
    stc
    ret

; --- Print RCX bytes starting at RSI (no null terminator needed) ---
print_len:
    or rcx, rcx
    jz .done
    mov al, [rsi]
    call print_char
    inc rsi
    dec rcx
    jmp print_len
.done:
    ret

; --- Print AL as two hex digits ---
print_hex8:
    push rax
    mov ah, al
    shr al, 4
    call .nibble
    mov al, ah
    and al, 0x0F
    call .nibble
    pop rax
    ret
.nibble:
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .out
.digit:
    add al, '0'
.out:
    call print_char
    ret

; --- Print RAX as 16 zero-padded hex digits ---
print_hex64:
    push rax
    push rbx
    push rcx
    mov rbx, rax
    mov rcx, 16
.loop:
    rol rbx, 4
    mov al, bl
    and al, 0x0F
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .have
.digit:
    add al, '0'
.have:
    call print_char
    dec rcx
    jnz .loop
    pop rcx
    pop rbx
    pop rax
    ret

; --- Print RAX as an unsigned decimal number ---
print_dec64:
    push rax
    push rbx
    push rdx
    push rsi
    push rdi

    lea rdi, [dec_buffer + 20]
    mov byte [rdi], 0
    mov rbx, 10
    or rax, rax
    jnz .conv_loop
    dec rdi
    mov byte [rdi], '0'
    jmp .print
.conv_loop:
    or rax, rax
    jz .print
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    jmp .conv_loop
.print:
    mov rsi, rdi
    call print_string

    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    ret

; --- Parse a hex number at RSI into RAX, advancing RSI past it and a single
; trailing space (if any). Leading spaces are skipped. RAX = 0 if no digits. ---
parse_hex_arg:
    push rbx
    push rcx
    push rdx
    call skip_spaces
    xor rax, rax
.loop:
    mov dl, [rsi]
    or dl, dl
    jz .done
    cmp dl, ' '
    je .trailing_space
    mov cl, dl
    push rax
    mov al, cl
    call hex_nibble
    mov bl, al
    pop rax
    jc .done
    shl rax, 4
    movzx rbx, bl
    or rax, rbx
    inc rsi
    jmp .loop
.trailing_space:
    inc rsi
.done:
    pop rdx
    pop rcx
    pop rbx
    ret

; --- "clear" handler: blank the screen and home the cursor ---
cmd_clear:
    push rax
    push rcx
    push rdi
    mov rdi, VGA_MEM
    mov rcx, VGA_COLS * VGA_ROWS
.loop:
    mov byte [rdi], ' '
    mov byte [rdi + 1], VGA_ATTR
    add rdi, 2
    loop .loop
    mov qword [cursor_pos], 0
    call update_cursor
    pop rdi
    pop rcx
    pop rax
    ret

; --- "help" handler: list every command in command_table ---
cmd_help:
    push r9
    push r11
    push rsi
    push rcx
    mov r11, command_table
.loop:
    mov rax, [r11]
    or rax, rax
    jz .done
    mov r9, [r11 + 8]
    mov rsi, rax
    mov rcx, r9
    call print_len
    mov al, ' '
    call print_char
    add r11, 24
    jmp .loop
.done:
    pop rcx
    pop rsi
    pop r11
    pop r9
    ret

; --- "reboot" handler: 8042 pulse-reset, falling back to a forced triple fault ---
cmd_reboot:
    mov rsi, reboot_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    call kbd_wait_input
    mov al, 0xFE
    out KBD_CMD_PORT, al
    lidt [null_idt_descriptor]
    int3
.hang:
    hlt
    jmp .hang

; --- "halt" handler: stop the CPU for good ---
cmd_halt:
    mov rsi, halt_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    cli
.hang:
    hlt
    jmp .hang

; --- "mem <addr> <len>" handler: hexdump LEN bytes at ADDR, 16 per line ---
cmd_mem:
    call parse_hex_arg
    mov rbx, rax
    call parse_hex_arg
    mov rcx, rax
    xor rdx, rdx
.byte_loop:
    or rcx, rcx
    jz .done
    mov al, [rbx]
    call print_hex8
    mov al, ' '
    call print_char
    inc rbx
    dec rcx
    inc rdx
    cmp rdx, 16
    jne .byte_loop
    xor rdx, rdx
    mov al, ASCII_CR
    call print_char
    jmp .byte_loop
.done:
    ret

; --- "peek <addr>" handler: print the byte at ADDR ---
cmd_peek:
    call parse_hex_arg
    mov al, [rax]
    call print_hex8
    ret

; --- "poke <addr> <value>" handler: write VALUE's low byte to ADDR ---
cmd_poke:
    call parse_hex_arg
    mov rbx, rax
    call parse_hex_arg
    mov [rbx], al
    ret

; --- "cpuid [leaf]" handler: leaf 0 prints the vendor string, else raw regs ---
cmd_cpuid:
    xor rax, rax
    cmp byte [rsi], 0
    je .have_leaf
    call parse_hex_arg
.have_leaf:
    mov r8, rax
    push rbx
    cpuid
    cmp r8, 0
    jne .dump_regs

    mov [cpuid_vendor], ebx
    mov [cpuid_vendor + 4], edx
    mov [cpuid_vendor + 8], ecx
    mov byte [cpuid_vendor + 12], 0
    mov rsi, cpuid_vendor
    call print_string
    pop rbx
    ret

.dump_regs:
    mov r9, rax
    mov r10, rbx
    mov r11, rcx
    push rdx
    mov rax, r9
    call print_hex64
    mov al, ' '
    call print_char
    mov rax, r10
    call print_hex64
    mov al, ' '
    call print_char
    mov rax, r11
    call print_hex64
    mov al, ' '
    call print_char
    pop rax
    call print_hex64
    pop rbx
    ret

; --- "uptime" handler: seconds elapsed since boot ---
cmd_uptime:
    mov rax, [timer_ticks]
    xor rdx, rdx
    mov rbx, PIT_HZ
    div rbx
    call print_dec64
    mov rsi, uptime_suffix
    call print_string
    ret

; rbx = start addr, r8 = length; returns match addr in rax or 0
scan_for_rsdp:
.step:
    cmp r8, 16
    jb .none
    mov rsi, rbx
    mov rdi, rsdp_sig
    mov rcx, 8
    repe cmpsb
    jne .next
    mov rsi, rbx
    mov rcx, 20
    xor dl, dl
.sum:
    add dl, [rsi]
    inc rsi
    loop .sum
    or dl, dl
    jnz .next
    mov rax, rbx
    ret
.next:
    add rbx, 16
    sub r8, 16
    jmp .step
.none:
    xor rax, rax
    ret

; --- Locate the RSDP in the EBDA or the 0xE0000-0xFFFFF BIOS area.
; Returns pointer in RAX, or 0 if not found. ---
find_rsdp:
    movzx rbx, word [0x40E]
    shl rbx, 4
    mov r8, 0x400
    call scan_for_rsdp
    or rax, rax
    jnz .done

    mov rbx, 0xE0000
    mov r8, 0x20000
    call scan_for_rsdp
.done:
    ret

; --- Walk an RSDT's table pointers for a 4-byte signature.
; RBX = RSDT address, EDX = signature (e.g. 'FACP'). Returns table
; address in RAX, or 0 if not found. ---
find_table:
    push rcx
    push rsi
    push rdx
    mov eax, [rbx + 4]
    sub eax, 36
    xor edx, edx
    mov ecx, 4
    div ecx
    mov ecx, eax
    pop rdx
    lea rsi, [rbx + 36]
.loop:
    or rcx, rcx
    jz .none
    mov eax, [rsi]
    cmp dword [rax], edx
    je .found
    add rsi, 4
    dec rcx
    jmp .loop
.found:
    pop rsi
    pop rcx
    ret
.none:
    xor rax, rax
    pop rsi
    pop rcx
    ret

; --- Scan a DSDT for the "_S5_" AML name. RBX = DSDT address.
; Returns a pointer just past the match in RAX, or 0 if not found. ---
find_s5:
    mov eax, [rbx + 4]
    lea r9, [rbx + rax]
    sub r9, 4
    mov rsi, rbx
.scan:
    cmp rsi, r9
    ja .none
    cmp dword [rsi], '_S5_'
    je .match
    inc rsi
    jmp .scan
.match:
    lea rax, [rsi + 4]
    ret
.none:
    xor rax, rax
    ret

; --- "shutdown" handler: real ACPI S5 power-off via RSDP -> RSDT -> FADT ->
; DSDT _S5 scan (the standard minimal hobby-OS ACPI shutdown path - no full
; AML interpreter, and assumes an RSDT is present rather than XSDT-only).
; Falls back to the common emulator magic shutdown ports, and finally to a
; plain halt, if any step of the real ACPI path fails. ---
cmd_shutdown:
    call find_rsdp
    or rax, rax
    jz .fallback_ports
    mov rbx, rax
    mov eax, [rbx + 16]         ; RSDT address
    or eax, eax
    jz .fallback_ports
    mov rbx, rax

    mov edx, 'FACP'
    call find_table
    or rax, rax
    jz .fallback_ports
    mov rbx, rax                 ; rbx = FADT address

    mov eax, [rbx + 64]
    mov [pm1a_cnt], eax
    mov eax, [rbx + 68]
    mov [pm1b_cnt], eax
    mov eax, [rbx + 40]
    mov [dsdt_addr], eax
    mov eax, [rbx + 48]
    mov [smi_cmd], eax
    movzx eax, byte [rbx + 52]
    mov [acpi_enable_val], al

    mov edx, [pm1a_cnt]
    in ax, dx
    test al, 1
    jnz .acpi_enabled
    mov edx, [smi_cmd]
    or edx, edx
    jz .fallback_ports
    mov al, [acpi_enable_val]
    out dx, al
    mov rcx, 1000000
.wait_enable:
    mov edx, [pm1a_cnt]
    in ax, dx
    test al, 1
    jnz .acpi_enabled
    loop .wait_enable
    jmp .fallback_ports
.acpi_enabled:

    mov rbx, [dsdt_addr]
    or rbx, rbx
    jz .fallback_ports
    call find_s5
    or rax, rax
    jz .fallback_ports

    mov rsi, rax
    cmp byte [rsi], 0x12
    jne .fallback_ports
    inc rsi
    mov al, [rsi]
    and al, 0xC0
    shr al, 6
    movzx rcx, al
    add rcx, 2
    add rsi, rcx
    mov al, [rsi]
    cmp al, 0x0A
    jne .typa_raw
    inc rsi
.typa_raw:
    movzx rax, byte [rsi]
    mov [slp_typa], rax
    inc rsi
    mov al, [rsi]
    cmp al, 0x0A
    jne .typb_raw
    inc rsi
.typb_raw:
    movzx rax, byte [rsi]
    mov [slp_typb], rax

    mov rax, [slp_typa]
    shl rax, 10
    or rax, 1 << 13
    mov edx, [pm1a_cnt]
    out dx, ax

    mov eax, [pm1b_cnt]
    or eax, eax
    jz .after_b
    mov rax, [slp_typb]
    shl rax, 10
    or rax, 1 << 13
    mov edx, [pm1b_cnt]
    out dx, ax
.after_b:
.fallback_ports:
    mov dx, 0x604
    mov ax, 0x2000
    out dx, ax
    mov dx, 0xB004
    mov ax, 0x2000
    out dx, ax
    mov dx, 0x4004
    mov ax, 0x3400
    out dx, ax

    mov rsi, shutdown_fail_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    cli
.hang:
    hlt
    jmp .hang

command_table:
    dq echo_cmd, echo_cmd_end - echo_cmd, cmd_echo
    dq run_cmd, run_cmd_end - run_cmd, cmd_run
    dq clear_cmd, clear_cmd_end - clear_cmd, cmd_clear
    dq help_cmd, help_cmd_end - help_cmd, cmd_help
    dq reboot_cmd, reboot_cmd_end - reboot_cmd, cmd_reboot
    dq halt_cmd, halt_cmd_end - halt_cmd, cmd_halt
    dq mem_cmd, mem_cmd_end - mem_cmd, cmd_mem
    dq peek_cmd, peek_cmd_end - peek_cmd, cmd_peek
    dq poke_cmd, poke_cmd_end - poke_cmd, cmd_poke
    dq cpuid_cmd, cpuid_cmd_end - cpuid_cmd, cmd_cpuid
    dq uptime_cmd, uptime_cmd_end - uptime_cmd, cmd_uptime
    dq shutdown_cmd, shutdown_cmd_end - shutdown_cmd, cmd_shutdown
    dq 0

; --- Print a null-terminated string starting at RSI ---
print_string:
    mov al, [rsi]
    or al, al
    jz .done
    call print_char
    inc rsi
    jmp print_string
.done:
    ret

; --- Move the hardware text-mode cursor to match cursor_pos ---
update_cursor:
    push rax
    push rbx
    push rdx

    mov rax, [cursor_pos]
    shr rax, 1              ; byte offset -> character cell index
    mov bx, ax

    mov dx, CRTC_INDEX
    mov al, CRTC_CURSOR_LOW
    out dx, al
    mov dx, CRTC_DATA
    mov al, bl
    out dx, al

    mov dx, CRTC_INDEX
    mov al, CRTC_CURSOR_HIGH
    out dx, al
    mov dx, CRTC_DATA
    mov al, bh
    out dx, al

    pop rdx
    pop rbx
    pop rax
    ret

; --- Print one character in AL to the VGA buffer, tracking cursor_pos ---
print_char:
    cmp al, ASCII_CR
    je .newline
    cmp al, ASCII_BS
    je .backspace

    mov rdi, [cursor_pos]
    add rdi, VGA_MEM
    mov [rdi], al
    mov byte [rdi + 1], VGA_ATTR
    add qword [cursor_pos], 2
    jmp .wrap_check

.newline:
    mov rax, [cursor_pos]
    mov rbx, VGA_ROW_BYTES
    xor rdx, rdx
    div rbx
    inc rax
    mov rbx, VGA_ROW_BYTES
    mul rbx
    mov [cursor_pos], rax
    jmp .wrap_check

.backspace:
    cmp qword [cursor_pos], 0
    je .ret
    sub qword [cursor_pos], 2
    mov rdi, [cursor_pos]
    add rdi, VGA_MEM
    mov byte [rdi], ' '
    mov byte [rdi + 1], VGA_ATTR
    jmp .ret

.wrap_check:
    cmp qword [cursor_pos], VGA_SIZE
    jl .ret
    call scroll_screen
    mov qword [cursor_pos], VGA_LAST_ROW  ; back to the start of the (now-cleared) last row
.ret:
    call update_cursor
    ret

; --- Scroll the VGA text buffer up one row, clearing the new bottom row ---
scroll_screen:
    push rsi
    push rdi
    push rcx

    mov rsi, VGA_MEM + VGA_ROW_BYTES
    mov rdi, VGA_MEM
    mov rcx, VGA_LAST_ROW      ; (VGA_ROWS-1) rows worth of bytes, safe to copy forward
    rep movsb

    mov rdi, VGA_MEM + VGA_LAST_ROW
    mov rcx, VGA_COLS
.clear_loop:
    mov byte [rdi], ' '
    mov byte [rdi + 1], VGA_ATTR
    add rdi, 2
    loop .clear_loop

    pop rcx
    pop rdi
    pop rsi
    ret

msg db "Hello, Amethyst!", 0
prompt db "> ", 0
echo_cmd db "echo"
echo_cmd_end:
run_cmd db "run"
run_cmd_end:
clear_cmd db "clear"
clear_cmd_end:
help_cmd db "help"
help_cmd_end:
reboot_cmd db "reboot"
reboot_cmd_end:
halt_cmd db "halt"
halt_cmd_end:
mem_cmd db "mem"
mem_cmd_end:
peek_cmd db "peek"
peek_cmd_end:
poke_cmd db "poke"
poke_cmd_end:
cpuid_cmd db "cpuid"
cpuid_cmd_end:
uptime_cmd db "uptime"
uptime_cmd_end:
shutdown_cmd db "shutdown"
shutdown_cmd_end:
unknown_msg db "Unknown command: ", 0
run_bad_hex_msg db "Invalid hex byte", 0
run_too_long_msg db "Too many bytes for exec_buffer", 0
reboot_msg db "Rebooting...", 0
halt_msg db "Halted.", 0
shutdown_fail_msg db "Shutdown failed - it's now safe to turn off your computer.", 0
uptime_suffix db " s", 0
rsdp_sig db "RSD PTR "

null_idt_descriptor:
    dw 0
    dq 0

cursor_pos dq 0
cmd_len db 0
cmd_buffer times CMD_BUFFER_SIZE db 0
timer_ticks dq 0
cpuid_vendor times 13 db 0
dec_buffer times 21 db 0
pm1a_cnt dq 0
pm1b_cnt dq 0
dsdt_addr dq 0
smi_cmd dq 0
acpi_enable_val db 0
slp_typa dq 0
slp_typb dq 0

; Scratch buffer for `run`'s raw machine code - no execute-permission
; distinction is set up in the page tables, so this is directly callable.
exec_buffer times EXEC_BUFFER_SIZE db 0
shift_state db 0
caps_lock db 0

; US QWERTY set-1 scancode -> lowercase ASCII (0 = unmapped/ignored)
scancode_table:
    db 0, 0, '1', '2', '3', '4', '5', '6', '7', '8'
    db '9', '0', '-', '=', 0x08, 0
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0x0D, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', 39, '`', 0
    db 0x5C, 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0
    db 0, 0, ' '
scancode_table_end:

; Same layout as scancode_table, but for shift held (uppercase letters,
; shifted symbols). Caps-lock-only adjustment is applied separately in
; keyboard_isr so caps lock doesn't also shift symbols/digits.
shifted_scancode_table:
    db 0, 0, '!', '@', '#', '$', '%', '^', '&', '*'
    db '(', ')', '_', '+', 0x08, 0
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0x0D, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0
    db '|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0
    db 0, 0, ' '

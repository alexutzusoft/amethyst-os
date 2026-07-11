; --- "echo <text>" prints text; "echo <text> > <filename>" writes it to a
; file instead (FAT only - see fs_echo_root in commands_fs.asm). rsi ->
; nul-terminated argument string. ---
cmd_echo:
    push rsi
    mov rdi, rsi
.find_redir:
    mov al, [rdi]
    or al, al
    jz .no_redir
    cmp al, '>'
    je .redir
    inc rdi
    jmp .find_redir
.redir:
    mov rax, rdi                     ; rax -> '>' char, rsi (on stack) -> text start
    mov [redir_pos], rax
    inc rdi                          ; rdi -> filename field
.skip_fname_spaces:
    mov al, [rdi]
    cmp al, ' '
    jne .have_fname
    inc rdi
    jmp .skip_fname_spaces
.have_fname:
    mov al, [rdi]
    or al, al
    jz .usage
    mov [fs_echo_fname], rdi         ; filename field, saved before rdi is reused
    ; trim trailing spaces off the text part [rsi .. redir_pos)
    pop rsi
    push rsi
    mov rax, [redir_pos]
.trim:
    cmp rax, rsi
    jbe .len_done
    cmp byte [rax - 1], ' '
    jne .len_done
    dec rax
    jmp .trim
.len_done:
    sub rax, rsi
    mov ecx, eax
    lea rdi, [echo_data_buf]
    call fs_echo_unescape
    mov [fs_echo_len], eax
    lea rax, [echo_data_buf]
    mov [fs_echo_ptr], rax
    mov rsi, [fs_echo_fname]
    call fs_build_target_name
    mov byte [fs_action], 2
    call fs_scan_devices
    pop rsi
    ret
.no_redir:
    pop rsi
    push rsi
    xor ecx, ecx
.strlen:
    cmp byte [rsi + rcx], 0
    je .strlen_done
    inc ecx
    jmp .strlen
.strlen_done:
    lea rdi, [echo_data_buf]
    call fs_echo_unescape
    pop rsi
    lea rsi, [echo_data_buf]
    call print_string
    ret
.usage:
    pop rsi
    mov rsi, echo_redir_usage_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

; --- Copy rsi[0..ecx) to rdi, translating "\n" -> CR and "\\" -> "\"
; (a lone trailing backslash is copied literally). nul-terminates the
; result. Returns the output length in eax. ---
fs_echo_unescape:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor ebx, ebx
.loop:
    test ecx, ecx
    jz .done
    mov al, [rsi]
    cmp al, '\'
    jne .plain
    cmp ecx, 1
    je .plain
    mov dl, [rsi + 1]
    cmp dl, 'n'
    je .esc_n
    cmp dl, '\'
    je .esc_bs
.plain:
    mov [rdi + rbx], al
    inc rbx
    inc rsi
    dec ecx
    jmp .loop
.esc_n:
    mov byte [rdi + rbx], ASCII_CR
    inc rbx
    add rsi, 2
    sub ecx, 2
    jmp .loop
.esc_bs:
    mov byte [rdi + rbx], '\'
    inc rbx
    add rsi, 2
    sub ecx, 2
    jmp .loop
.done:
    mov byte [rdi + rbx], 0
    mov eax, ebx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
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

parse_dec_arg:
    push rbx
    push rcx
    push rdx
    call skip_spaces
    xor rax, rax
    xor cl, cl
    mov dl, [rsi]
    cmp dl, '-'
    jne .no_sign
    mov cl, 1
    inc rsi
.no_sign:
.loop:
    mov dl, [rsi]
    or dl, dl
    jz .done
    cmp dl, ' '
    je .trailing_space
    cmp dl, '0'
    jb .done
    cmp dl, '9'
    ja .done
    sub dl, '0'
    imul rax, rax, 10
    movzx rbx, dl
    add rax, rbx
    inc rsi
    jmp .loop
.trailing_space:
    inc rsi
.done:
    cmp cl, 0
    je .positive
    neg rax
.positive:
    pop rdx
    pop rcx
    pop rbx
    ret

print_dec64_signed:
    push rax
    or rax, rax
    jns .positive
    push rax
    mov al, '-'
    call print_char
    pop rax
    neg rax
.positive:
    call print_dec64
    pop rax
    ret

isqrt64:
    push rbx
    push rcx
    push rdx
    mov rbx, rax
    xor rax, rax
    mov rcx, 0x4000000000000000
.find_bit:
    cmp rcx, rbx
    jbe .have_bit
    shr rcx, 2
    jmp .find_bit
.have_bit:
.loop:
    or rcx, rcx
    jz .done
    mov rdx, rax
    add rdx, rcx
    cmp rbx, rdx
    jb .skip
    sub rbx, rdx
    shr rax, 1
    add rax, rcx
    jmp .next
.skip:
    shr rax, 1
.next:
    shr rcx, 2
    jmp .loop
.done:
    pop rdx
    pop rcx
    pop rbx
    ret

; --- "clear" handler: blank the screen and home the cursor ---
cmd_clear:
    push rax
    push rcx
    push rdx
    push rdi
    mov rdi, VGA_MEM
    mov rcx, VGA_COLS * VGA_ROWS
    mov dl, [text_attr]
.loop:
    mov byte [rdi], ' '
    mov [rdi + 1], dl
    add rdi, 2
    loop .loop
    mov qword [cursor_pos], 0
    call update_cursor
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; --- "help" handler: list every command in command_table with its description ---
cmd_help:
    push rax
    push rdx
    push rsi
    push rcx
    push r9
    push r11
    push r12
    mov r11, command_table
    mov r12, command_descriptions
.loop:
    mov rax, [r11]
    or rax, rax
    jz .done
    mov r9, [r11 + 8]
    mov rsi, rax
    mov rcx, r9
    call print_len
    mov rcx, HELP_NAME_WIDTH
    sub rcx, r9
    jle .pad_done
.pad_loop:
    mov al, ' '
    call print_char
    dec rcx
    jnz .pad_loop
.pad_done:
    mov rsi, help_sep
    call print_string
    mov rsi, [r12]
    mov rcx, [r12 + 8]
    call print_len
    mov al, ASCII_CR
    call print_char
    add r11, 24
    add r12, 16
    jmp .loop
.done:
    pop r12
    pop r11
    pop r9
    pop rcx
    pop rsi
    pop rdx
    pop rax
    ret

; --- "color" handler: set the foreground/background text attribute.
; Accepts a preset name (red/green/blue/yellow/white) or a 2-digit HEX
; attribute byte (high nibble = background, low nibble = foreground). ---
cmd_color:
    mov rdi, color_names
.find_loop:
    mov rax, [rdi]
    or rax, rax
    jz .try_hex
    mov r9, [rdi + 8]
    movzx r10, byte [rdi + 16]

    mov r11, rsi
    mov r8, rax
    mov rcx, r9
.cmp_loop:
    or rcx, rcx
    jz .name_end_check
    mov al, [r11]
    mov bl, [r8]
    cmp al, bl
    jne .next_name
    inc r11
    inc r8
    dec rcx
    jmp .cmp_loop
.name_end_check:
    mov al, [r11]
    or al, al
    jz .matched
.next_name:
    add rdi, 24
    jmp .find_loop
.matched:
    mov [text_attr], r10b
    call recolor_screen
    ret

.try_hex:
    call skip_spaces
    mov al, [rsi]
    or al, al
    jz .usage
    call hex_nibble
    jc .usage
    mov bl, al
    shl bl, 4
    inc rsi
    mov al, [rsi]
    call hex_nibble
    jc .usage
    or bl, al
    inc rsi
    call skip_spaces
    mov al, [rsi]
    or al, al
    jnz .usage
    mov [text_attr], bl
    call recolor_screen
    ret
.usage:
    mov rsi, color_usage_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

; --- overwrite the attribute byte of every cell already on screen ---
recolor_screen:
    push rax
    push rcx
    push rdx
    push rdi
    mov rdi, VGA_MEM
    mov rcx, VGA_COLS * VGA_ROWS
    mov dl, [text_attr]
.loop:
    mov [rdi + 1], dl
    add rdi, 2
    loop .loop
    pop rdi
    pop rdx
    pop rcx
    pop rax
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

; --- "sysinfo [cpu|ram|gpu|general]" handler: dispatches to the section
; below matching the argument, or all three (in cpu/ram/gpu order) when
; no argument (or "general") is given. ---

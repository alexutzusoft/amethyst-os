cmd_date:
    mov al, 0x07
    call rtc_get
    call print_dec2
    mov al, '/'
    call print_char
    mov al, 0x08
    call rtc_get
    call print_dec2
    mov al, '/'
    call print_char
    mov al, 0x09
    call rtc_get
    movzx eax, al
    add eax, 2000
    call print_dec64
    mov al, ASCII_CR
    call print_char
    ret

; --- "time" handler: prints the RTC time as HH:MM:SS ---
cmd_time:
    mov al, 0x04
    call rtc_get
    call print_dec2
    mov al, ':'
    call print_char
    mov al, 0x02
    call rtc_get
    call print_dec2
    mov al, ':'
    call print_char
    mov al, 0x00
    call rtc_get
    call print_dec2
    mov al, ASCII_CR
    call print_char
    ret

; --- "draw [gem|cat|amethyst_text]" handler: prints a fun ASCII drawing ---
cmd_draw:
    call skip_spaces
    mov al, [rsi]
    or al, al
    jz .default

    mov rdi, draw_gem_str
    call sysinfo_arg_match
    jc .do_gem
    mov rdi, draw_cat_str
    call sysinfo_arg_match
    jc .do_cat
    mov rdi, draw_logo_str
    call sysinfo_arg_match
    jc .do_logo

    mov rsi, draw_usage_msg
    call print_string
    ret

.default:
.do_gem:
    mov rsi, draw_art_gem
    call print_string
    ret
.do_cat:
    mov rsi, draw_art_cat
    call print_string
    ret
.do_logo:
    mov rsi, draw_art_logo
    call print_string
    ret

; --- RSI = input string. If it starts with "sqrt" followed by a space or
; end of string, advances RSI past "sqrt" (and the space, if any) and
; returns CF=1. Otherwise RSI is unchanged and CF=0. Clobbers rax; saves
; and restores rbx/rdi/rsi (the pushed rsi is only popped on no-match). ---
calc_match_sqrt_token:
    push rbx
    push rdi
    push rsi
    mov rdi, calc_sqrt_str
.loop:
    mov al, [rsi]
    mov bl, [rdi]
    or bl, bl
    jz .name_end
    cmp al, bl
    jne .no_match
    inc rsi
    inc rdi
    jmp .loop
.name_end:
    cmp al, ' '
    je .match_space
    or al, al
    jz .match_end
    jmp .no_match
.match_space:
    inc rsi
.match_end:
    add rsp, 8
    pop rdi
    pop rbx
    stc
    ret
.no_match:
    pop rsi
    pop rdi
    pop rbx
    clc
    ret

cmd_calc:
    call skip_spaces
    call calc_match_sqrt_token
    jc .prefix_sqrt

    call parse_dec_arg
    mov rbx, rax
    call skip_spaces

    call calc_match_sqrt_token
    jc .do_sqrt

    mov al, [rsi]
    or al, al
    jz .usage
    mov r8b, al
    inc rsi
    cmp byte [rsi], ' '
    je .have_op
    cmp byte [rsi], 0
    jne .usage
.have_op:
    call parse_dec_arg
    mov rcx, rax

    cmp r8b, '+'
    je .do_add
    cmp r8b, '-'
    je .do_sub
    cmp r8b, '*'
    je .do_mul
    cmp r8b, '/'
    je .do_div
    cmp r8b, '%'
    je .do_mod
    jmp .usage

.do_add:
    mov rax, rbx
    add rax, rcx
    jmp .print
.do_sub:
    mov rax, rbx
    sub rax, rcx
    jmp .print
.do_mul:
    mov rax, rbx
    imul rax, rcx
    jmp .print
.do_div:
    or rcx, rcx
    jz .divzero
    mov rax, rbx
    cqo
    idiv rcx
    jmp .print
.do_mod:
    or rcx, rcx
    jz .divzero
    mov rax, rbx
    cqo
    idiv rcx
    mov rax, rdx
    jmp .print

.prefix_sqrt:
    call parse_dec_arg
    mov rbx, rax
.do_sqrt:
    cmp rbx, 0
    jl .neg_sqrt
    mov rax, rbx
    call isqrt64
    jmp .print

.print:
    call print_dec64_signed
    mov al, ASCII_CR
    call print_char
    ret

.divzero:
    mov rsi, calc_divzero_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret
.neg_sqrt:
    mov rsi, calc_neg_sqrt_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret
.usage:
    mov rsi, calc_usage_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

; --- Read CMOS RTC register AL, converting from BCD if needed. Returns
; the binary value in AL. ---
rtc_get:
    push rbx
    push rcx
    mov bl, al
    mov al, 0x0B
    out 0x70, al
    in al, 0x71
    mov ch, al
    mov al, bl
    out 0x70, al
    in al, 0x71
    test ch, 4
    jnz .done
    mov cl, al
    and cl, 0x0F
    mov bl, al
    shr bl, 4
    mov al, bl
    mov ah, 0
    push rcx
    mov cl, 10
    mul cl
    pop rcx
    add al, cl
.done:
    pop rcx
    pop rbx
    ret

; --- Print AL (0-99) as a zero-padded two-digit decimal number ---
print_dec2:
    push rax
    push rbx
    push rdx
    movzx eax, al
    mov ebx, 10
    xor edx, edx
    div ebx
    push rdx
    add al, '0'
    call print_char
    pop rdx
    mov al, dl
    add al, '0'
    call print_char
    pop rdx
    pop rbx
    pop rax
    ret


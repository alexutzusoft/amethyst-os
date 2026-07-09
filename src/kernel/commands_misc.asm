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


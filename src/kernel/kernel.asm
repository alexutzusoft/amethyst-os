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
VGA_ATTR      equ 0x0F                            ; white on black
VGA_ATTR_SEL  equ 0xF0                            ; inverted: black on white (selection highlight)

HELP_NAME_WIDTH equ 10

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
PIC1_MASK          equ 0xF8   ; unmask IRQ0 (timer) + IRQ1 (keyboard) + IRQ2 (slave cascade)
PIC2_MASK_ALL      equ 0xEF   ; unmask IRQ12 (PS/2 mouse) on the slave

IRQ0_VECTOR  equ 0x20
IRQ1_VECTOR  equ 0x21
IRQ12_VECTOR equ 0x2C

; --- Only the first 1GB is identity-mapped (see protected_mode_start), and
; there is no page-fault handler - so any pointer read out of an ACPI table
; (which can be garbage, e.g. a revision-0 RSDP's unused extended fields)
; must be bounds-checked before it is ever dereferenced, or a bad value
; triple-faults real hardware. ---
IDENTITY_MAP_LIMIT equ 0x40000000

; --- BIOS memory map captured by stage1.asm's detect_memory (real mode,
; before the switch to protected/long mode - BIOS interrupts aren't
; reachable from here). Keep these equs in sync with stage1.asm's copy. ---
MMAP_COUNT_ADDR   equ 0x5000
MMAP_ENTRIES_ADDR equ 0x5008
MMAP_MAX_ENTRIES  equ 64

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
SC_CTRL     equ 0x1D   ; LCtrl (bare) and RCtrl (0xE0-prefixed) share this base code
SC_LEFT     equ 0x4B   ; only valid 0xE0-prefixed (set-1 arrows are all extended codes)
SC_RIGHT    equ 0x4D
SC_UP       equ 0x48
SC_DOWN     equ 0x50

; --- PS/2 aux (mouse) port, cursor experimental feature ---
PS2_CMD_ENABLE_AUX          equ 0xA8
PS2_CMD_WRITE_AUX           equ 0xD4
MOUSE_CMD_ENABLE_REPORTING  equ 0xF4
MOUSE_CMD_DISABLE_REPORTING equ 0xF5
KBD_IRQ12_ENABLE_BIT        equ 0x02
KBD_STATUS_AUX_DATA         equ 0x20
MOUSE_ALWAYS1_BIT equ 0x08
MOUSE_SIGN_X      equ 0x10
MOUSE_SIGN_Y      equ 0x20
MOUSE_OVERFLOW_X  equ 0x40
MOUSE_OVERFLOW_Y  equ 0x80
MOUSE_BTN_LEFT    equ 0x01
MOUSE_BTN_RIGHT   equ 0x02
MOUSE_SCROLL_THRESHOLD equ 24
MOUSE_CMD_SET_SAMPLE_RATE equ 0xF3
MOUSE_CMD_GET_DEVICE_ID   equ 0xF2

HIST_ROWS equ 200
KBD_EXTENDED_PREFIX equ 0xE0

; --- CRT controller (hardware cursor) ports/registers ---
CRTC_INDEX       equ 0x3D4
CRTC_DATA        equ 0x3D5
CRTC_CURSOR_LOW  equ 0x0F
CRTC_CURSOR_HIGH equ 0x0E
CRTC_CURSOR_START equ 0x0A
CRTC_CURSOR_DISABLE_BIT equ 0x20

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

; --- Build IDT entries (vector 0x20 timer, vector 0x21 keyboard) and load it ---
setup_idt:
    mov rax, timer_isr
    mov rdi, IDT_ADDR + (IRQ0_VECTOR * 16)
    call write_idt_entry

    mov rax, keyboard_isr
    mov rdi, IDT_ADDR + (IRQ1_VECTOR * 16)
    call write_idt_entry

    mov rax, mouse_isr
    mov rdi, IDT_ADDR + (IRQ12_VECTOR * 16)
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

; --- Enable the 8042 aux (mouse) port and its IRQ12 line. Data reporting
; is left off (the mouse default) until the "cursor on" command sends
; MOUSE_CMD_ENABLE_REPORTING, so nothing streams unless opted into. ---
enable_mouse_port:
    call kbd_wait_input
    mov al, PS2_CMD_ENABLE_AUX
    out KBD_CMD_PORT, al

    call kbd_wait_input
    mov al, KBD_CMD_READ_CFG
    out KBD_CMD_PORT, al
    call kbd_wait_output
    in al, KBD_DATA_PORT
    or al, KBD_IRQ12_ENABLE_BIT
    mov bl, al

    call kbd_wait_input
    mov al, KBD_CMD_WRITE_CFG
    out KBD_CMD_PORT, al
    call kbd_wait_input
    mov al, bl
    out KBD_DATA_PORT, al
    ret

; --- Send a command byte (in AL) to the mouse via the 0xD4 aux-port prefix ---
mouse_write_cmd:
    push rax
    mov ah, al                  ; stash the command byte before kbd_wait_input clobbers al
    call kbd_wait_input
    mov al, PS2_CMD_WRITE_AUX
    out KBD_CMD_PORT, al
    call kbd_wait_input
    mov al, ah
    out KBD_DATA_PORT, al
    pop rax
    ret

; --- Send AL to the mouse and drain its single-byte ACK (0xFA) response.
; Only safe to call before `sti` (or with IRQ12 masked) - otherwise the ACK
; byte races the interrupt handler's own packet framing. ---
mouse_send_and_ack:
    call mouse_write_cmd
    call kbd_wait_output
    in al, KBD_DATA_PORT
    ret

; --- IntelliMouse wheel detection: the "magic knock" (sample rate set to
; 200, 100, then 80) tells a wheel mouse to switch to 4-byte packets; a
; plain mouse just ignores it. Reading back the device ID afterward (3 =
; wheel mouse) confirms whether it took. Called once at boot before `sti`. ---
mouse_detect_wheel:
    push rax

    mov al, MOUSE_CMD_SET_SAMPLE_RATE
    call mouse_send_and_ack
    mov al, 200
    call mouse_send_and_ack
    mov al, MOUSE_CMD_SET_SAMPLE_RATE
    call mouse_send_and_ack
    mov al, 100
    call mouse_send_and_ack
    mov al, MOUSE_CMD_SET_SAMPLE_RATE
    call mouse_send_and_ack
    mov al, 80
    call mouse_send_and_ack

    mov al, MOUSE_CMD_GET_DEVICE_ID
    call mouse_send_and_ack
    call kbd_wait_output
    in al, KBD_DATA_PORT
    cmp al, 3
    jne .no_wheel
    mov byte [mouse_has_wheel], 1
    mov byte [mouse_packet_size], 4
.no_wheel:

    pop rax
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

    cmp bl, KBD_EXTENDED_PREFIX
    jne .not_prefix
    mov byte [extended_pending], 1
    jmp .eoi
.not_prefix:

    mov al, bl
    and al, KBD_SCANCODE_MASK       ; base scancode, ignoring make/break
    cmp byte [extended_pending], 0
    jne .extended_key

    cmp al, SC_LSHIFT
    je .shift_key
    cmp al, SC_RSHIFT
    je .shift_key
    cmp al, SC_CAPSLOCK
    je .capslock_key
    cmp al, SC_CTRL
    je .ctrl_key

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

    push rax
    call snap_scroll_to_live
    pop rax

    cmp al, ASCII_CR
    je .handle_enter
    cmp al, ASCII_BS
    je .handle_backspace

    cmp byte [sel_active], 0
    je .no_sel_replace
    call delete_selection
.no_sel_replace:

    movzx rcx, byte [cmd_len]
    cmp rcx, CMD_BUFFER_SIZE - 1
    jae .eoi
    call insert_char_at_cursor
    call redraw_input_line
    jmp .eoi

.handle_backspace:
    cmp byte [sel_active], 0
    jne .backspace_has_sel
    cmp byte [cmd_cursor], 0
    je .eoi
    call delete_char_before_cursor
    jmp .backspace_redraw
.backspace_has_sel:
    call delete_selection
.backspace_redraw:
    call redraw_input_line
    jmp .eoi

.extended_key:
    mov byte [extended_pending], 0
    cmp al, SC_LEFT
    je .arrow_left
    cmp al, SC_RIGHT
    je .arrow_right
    cmp al, SC_UP
    je .arrow_up
    cmp al, SC_DOWN
    je .arrow_down
    cmp al, SC_CTRL             ; RCtrl: 0xE0 0x1D
    je .ctrl_key
    jmp .eoi

.arrow_up:
    test bl, KBD_BREAK_BIT
    jnz .eoi
    call scroll_view_up
    jmp .eoi

.arrow_down:
    test bl, KBD_BREAK_BIT
    jnz .eoi
    call scroll_view_down
    jmp .eoi

.arrow_left:
    test bl, KBD_BREAK_BIT
    jnz .eoi
    call snap_scroll_to_live
    mov dl, -1
    call move_cursor_arrow
    jmp .eoi

.arrow_right:
    test bl, KBD_BREAK_BIT
    jnz .eoi
    call snap_scroll_to_live
    mov dl, 1
    call move_cursor_arrow
    jmp .eoi

.ctrl_key:
    test bl, KBD_BREAK_BIT
    jz .ctrl_make
    mov byte [ctrl_state], 0
    jmp .eoi
.ctrl_make:
    mov byte [ctrl_state], 1
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
    mov byte [cmd_cursor], 0
    mov byte [sel_active], 0
    mov byte [cmd_render_len], 0
    mov rsi, prompt
    call print_string
    mov rax, [cursor_pos]
    mov [line_start_pos], rax

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

; --- Insert AL at cmd_buffer[cmd_cursor], shifting the tail right by one byte,
; then advance cmd_len and cmd_cursor. Caller has already verified cmd_len is
; below CMD_BUFFER_SIZE - 1 and resolved any active selection. Clobbers
; rax/rcx/rsi/rdi (all caller-saved by keyboard_isr already). ---
insert_char_at_cursor:
    push rbx
    mov bl, al                     ; save char across the shift loop
    movzx rcx, byte [cmd_len]
    movzx rdi, byte [cmd_cursor]
    ; shift cmd_buffer[cmd_cursor..cmd_len] right by one, from the end backward
    cmp rcx, rdi
    je .no_shift
    lea rsi, [cmd_buffer + rcx]     ; rsi -> one past the last char
.shift_loop:
    mov al, [rsi - 1]
    mov [rsi], al
    dec rsi
    dec rcx
    cmp rcx, rdi
    jne .shift_loop
.no_shift:
    mov [cmd_buffer + rdi], bl
    inc byte [cmd_len]
    inc byte [cmd_cursor]
    pop rbx
    ret

; --- Delete the character immediately before cmd_cursor, shifting the tail
; left by one byte. Caller ensures cmd_cursor > 0. ---
delete_char_before_cursor:
    movzx rcx, byte [cmd_cursor]
    movzx rdx, byte [cmd_len]
    dec rcx                        ; index of the char being removed
    mov rsi, rcx
.shift_loop:
    cmp rsi, rdx
    jae .done
    mov al, [cmd_buffer + rsi + 1]
    mov [cmd_buffer + rsi], al
    inc rsi
    jmp .shift_loop
.done:
    dec byte [cmd_len]
    dec byte [cmd_cursor]
    ret

; --- Remove the range [min(sel_anchor,cmd_cursor), max(...)) from cmd_buffer,
; shifting the tail left, then clear the selection and place cmd_cursor at
; the start of the removed range. ---
delete_selection:
    push rax
    push rcx
    push rdx
    push rsi

    movzx rax, byte [sel_anchor]
    movzx rcx, byte [cmd_cursor]
    cmp rax, rcx
    jbe .have_range
    xchg rax, rcx
.have_range:
    ; rax = range start, rcx = range end (exclusive)
    movzx rdx, byte [cmd_len]
    mov rsi, rax
.shift_loop:
    cmp rsi, rdx
    jae .done_shift
    mov r8, rsi
    add r8, rcx
    sub r8, rax                    ; r8 = source index = rsi + (end - start)
    cmp r8, rdx
    jae .pad_zero
    mov r9b, [cmd_buffer + r8]
    jmp .store
.pad_zero:
    xor r9b, r9b
.store:
    mov [cmd_buffer + rsi], r9b
    inc rsi
    jmp .shift_loop
.done_shift:
    sub rdx, rcx
    add rdx, rax                    ; new length = old_len - (end - start)
    mov [cmd_len], dl
    mov [cmd_cursor], al
    mov byte [sel_active], 0

    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; --- Move cmd_cursor by one key-press worth in the direction in DL (+1/-1),
; honoring ctrl_state (whitespace-delimited word jump) and shift_state
; (extend/start/clear selection), then redraw. ---
move_cursor_arrow:
    push rax
    push rcx
    push rdx
    push rsi

    movsx rdx, dl                   ; sign-extend direction to full width
    movzx rax, byte [cmd_cursor]
    movzx rcx, byte [cmd_len]

    cmp byte [ctrl_state], 0
    jne .word_jump
    add rax, rdx
    jmp .clamp

.word_jump:
    cmp rdx, 0
    jl .word_left
    ; skip current run of non-spaces, then following run of spaces
.word_right_skip_word:
    cmp rax, rcx
    jae .clamp
    cmp byte [cmd_buffer + rax], ' '
    je .word_right_skip_spaces
    inc rax
    jmp .word_right_skip_word
.word_right_skip_spaces:
    cmp rax, rcx
    jae .clamp
    cmp byte [cmd_buffer + rax], ' '
    jne .clamp
    inc rax
    jmp .word_right_skip_spaces

.word_left:
    cmp rax, 0
    je .clamp
    dec rax
.word_left_skip_spaces:
    cmp rax, 0
    je .clamp
    cmp byte [cmd_buffer + rax], ' '
    jne .word_left_skip_word
    dec rax
    jmp .word_left_skip_spaces
.word_left_skip_word:
    cmp rax, 0
    je .clamp
    cmp byte [cmd_buffer + rax - 1], ' '
    je .clamp
    dec rax
    jmp .word_left_skip_word

.clamp:
    cmp rax, 0
    jge .clamp_high
    xor rax, rax
.clamp_high:
    cmp rax, rcx
    jle .have_new_cursor
    mov rax, rcx
.have_new_cursor:
    ; rax = new cursor index

    cmp byte [shift_state], 0
    jne .shift_held
    mov byte [sel_active], 0
    jmp .apply

.shift_held:
    cmp byte [sel_active], 0
    jne .apply
    mov byte [sel_active], 1
    movzx rsi, byte [cmd_cursor]
    mov [sel_anchor], sil

.apply:
    mov [cmd_cursor], al
    call redraw_input_line

    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; --- Repaint cmd_buffer[0..cmd_len] at line_start_pos, one VGA cell per
; character, using VGA_ATTR_SEL for any index within the active selection.
; Pads any leftover cells from a previous longer render with spaces, then
; places the hardware cursor at cmd_cursor. ---
redraw_input_line:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    movzx rcx, byte [cmd_len]
    movzx rdx, byte [cmd_render_len]
    cmp rcx, rdx
    jbe .have_pad_len
    mov rdx, rcx
.have_pad_len:
    ; rdx = max(cmd_len, previous cmd_render_len) = number of cells to touch

    cmp byte [sel_active], 0
    je .no_selection
    movzx rax, byte [sel_anchor]
    movzx rbx, byte [cmd_cursor]
    cmp rax, rbx
    jbe .sel_ready
    xchg rax, rbx
.sel_ready:
    jmp .have_sel
.no_selection:
    xor rax, rax
    xor rbx, rbx
.have_sel:
    ; rax = sel start, rbx = sel end (exclusive); equal when no selection

    xor rcx, rcx
.loop:
    cmp rcx, rdx
    jae .done
    mov rdi, [line_start_pos]
    lea rdi, [rdi + rcx * 2]
    add rdi, VGA_MEM

    movzx r8, byte [cmd_len]
    cmp rcx, r8
    jae .blank_cell
    mov r9b, [cmd_buffer + rcx]
    jmp .have_char
.blank_cell:
    mov r9b, ' '
.have_char:
    mov [rdi], r9b

    mov r10b, [text_attr]
    cmp byte [sel_active], 0
    je .store_attr
    cmp rcx, rax
    jb .store_attr
    cmp rcx, rbx
    jae .store_attr
    mov r10b, VGA_ATTR_SEL
.store_attr:
    mov [rdi + 1], r10b

    inc rcx
    jmp .loop
.done:
    movzx rax, byte [cmd_len]
    mov [cmd_render_len], al

    mov rax, [line_start_pos]
    movzx rbx, byte [cmd_cursor]
    lea rax, [rax + rbx * 2]
    mov [cursor_pos], rax
    call update_cursor

    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

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
cmd_sysinfo:
    call skip_spaces
    mov al, [rsi]
    or al, al
    jz .general

    mov rdi, si_cpu_str
    call sysinfo_arg_match
    jc .do_cpu
    mov rdi, si_ram_str
    call sysinfo_arg_match
    jc .do_ram
    mov rdi, si_gpu_str
    call sysinfo_arg_match
    jc .do_gpu
    mov rdi, si_general_str
    call sysinfo_arg_match
    jc .general

    mov rsi, sysinfo_usage_msg
    call print_string
    ret

.do_cpu:
    call sysinfo_cpu
    ret
.do_ram:
    call sysinfo_ram
    ret
.do_gpu:
    call sysinfo_gpu
    ret
.general:
    call sysinfo_cpu
    mov al, ASCII_CR
    call print_char
    call sysinfo_ram
    mov al, ASCII_CR
    call print_char
    call sysinfo_gpu
    ret

; --- RSI = input string, RDI = candidate nul-terminated name. CF=1 and both
; pointers unchanged if they match exactly, CF=0 otherwise. ---
sysinfo_arg_match:
    push rsi
    push rdi
.loop:
    mov al, [rsi]
    mov bl, [rdi]
    or bl, bl
    jz .cand_end
    cmp al, bl
    jne .no_match
    inc rsi
    inc rdi
    jmp .loop
.cand_end:
    or al, al
    jnz .no_match
    pop rdi
    pop rsi
    stc
    ret
.no_match:
    pop rdi
    pop rsi
    clc
    ret

; --- "sysinfo cpu" section: vendor string, brand string (if the CPU
; supports the extended CPUID leaves), decoded family/model/stepping, and
; the logical CPU count (from the MADT's enabled Local APIC entries). ---
sysinfo_cpu:
    mov rsi, sysinfo_cpu_hdr
    call print_string
    mov al, ASCII_CR
    call print_char

    xor eax, eax
    push rbx
    cpuid
    mov [cpuid_vendor], ebx
    mov [cpuid_vendor + 4], edx
    mov [cpuid_vendor + 8], ecx
    mov byte [cpuid_vendor + 12], 0
    pop rbx
    mov rsi, sysinfo_vendor_msg
    call print_string
    mov rsi, cpuid_vendor
    call print_string
    mov al, ASCII_CR
    call print_char

    mov rsi, sysinfo_brand_msg
    call print_string
    mov eax, 0x80000000
    push rbx
    cpuid
    pop rbx
    cmp eax, 0x80000004
    jb .no_brand

    lea rdi, [cpu_brand]
    mov eax, 0x80000002
    push rbx
    cpuid
    mov [rdi], eax
    mov [rdi + 4], ebx
    mov [rdi + 8], ecx
    mov [rdi + 12], edx
    pop rbx
    add rdi, 16
    mov eax, 0x80000003
    push rbx
    cpuid
    mov [rdi], eax
    mov [rdi + 4], ebx
    mov [rdi + 8], ecx
    mov [rdi + 12], edx
    pop rbx
    add rdi, 16
    mov eax, 0x80000004
    push rbx
    cpuid
    mov [rdi], eax
    mov [rdi + 4], ebx
    mov [rdi + 8], ecx
    mov [rdi + 12], edx
    pop rbx
    mov byte [rdi + 16], 0

    mov rsi, cpu_brand
    call print_string
    mov al, ASCII_CR
    call print_char
    jmp .brand_done
.no_brand:
    mov rsi, sysinfo_unknown_msg
    call print_string
    mov al, ASCII_CR
    call print_char
.brand_done:

    mov eax, 1
    push rbx
    cpuid
    mov r8d, eax                 ; family/model/stepping bitfields
    pop rbx

    mov ecx, r8d
    shr ecx, 8
    and ecx, 0x0F                 ; base family
    mov edx, r8d
    shr edx, 20
    and edx, 0xFF                  ; extended family
    cmp ecx, 0x0F
    jne .fam_done
    add ecx, edx                   ; family == 0xF: true family = base + extended
.fam_done:
    mov rsi, sysinfo_family_msg
    call print_string
    mov eax, ecx
    call print_dec64

    mov ecx, r8d
    shr ecx, 4
    and ecx, 0x0F                  ; base model
    mov edx, r8d
    shr edx, 16
    and edx, 0x0F                   ; extended model
    shl edx, 4
    add ecx, edx                    ; true model = (extended << 4) + base
    mov rsi, sysinfo_model_msg
    call print_string
    mov eax, ecx
    call print_dec64

    mov ecx, r8d
    and ecx, 0x0F                   ; stepping
    mov rsi, sysinfo_stepping_msg
    call print_string
    mov eax, ecx
    call print_dec64
    mov al, ASCII_CR
    call print_char

    mov rsi, sysinfo_cores_msg
    call print_string
    call count_logical_cpus
    or eax, eax
    jz .cores_unknown
    call print_dec64
    ret
.cores_unknown:
    mov rsi, sysinfo_cores_unknown_msg
    call print_string
    ret

; --- Count enabled Local APIC entries (type 0) in the ACPI MADT, i.e. the
; number of logical CPUs. Returns the count in EAX, 0 if the MADT can't be
; found (no RSDP, or missing from both the XSDT and RSDT). ---
count_logical_cpus:
    call find_rsdp
    or rax, rax
    jz .none
    mov r10, rax

    mov rbx, [r10 + 24]
    or rbx, rbx
    jz .try_rsdt
    mov edx, 'XSDT'
    call verify_table
    or rax, rax
    jz .try_rsdt
    mov edx, 'APIC'
    call find_table_xsdt
    or rax, rax
    jnz .have_madt

.try_rsdt:
    mov eax, [r10 + 16]
    or eax, eax
    jz .none
    mov rbx, rax
    mov edx, 'RSDT'
    call verify_table
    or rax, rax
    jz .none
    mov edx, 'APIC'
    call find_table
    or rax, rax
    jz .none

.have_madt:
    mov rbx, rax
    mov ecx, [rbx + 4]            ; MADT length
    lea rsi, [rbx + 44]           ; first entry, past the fixed MADT header
    lea r9, [rbx + rcx]
    xor r15d, r15d
.walk:
    cmp rsi, r9
    jae .done
    movzx r8d, byte [rsi]          ; entry type
    movzx r11d, byte [rsi + 1]     ; entry length
    or r11d, r11d
    jz .done                        ; malformed (zero-length) entry - stop rather than loop forever
    cmp r8d, 0                      ; type 0 = Processor Local APIC
    jne .next_entry
    test byte [rsi + 4], 1          ; Flags bit 0 = Enabled
    jz .next_entry
    inc r15d
.next_entry:
    add rsi, r11
    jmp .walk
.done:
    mov eax, r15d
    ret
.none:
    xor eax, eax
    ret

; --- "sysinfo ram" section: sums the "usable" (type 1) regions of the E820
; map stage1.asm captured before the switch to protected mode - long mode
; can no longer reach BIOS INT 15h to query this directly. ---
sysinfo_ram:
    mov rsi, sysinfo_ram_hdr
    call print_string
    mov al, ASCII_CR
    call print_char

    mov ecx, [MMAP_COUNT_ADDR]
    or ecx, ecx
    jnz .have_map
    mov rsi, sysinfo_ram_unavailable_msg
    call print_string
    ret

.have_map:
    xor r8, r8                     ; running total of usable bytes
    mov rsi, MMAP_ENTRIES_ADDR
.sum_loop:
    or rcx, rcx
    jz .sum_done
    mov eax, [rsi + 16]             ; region type
    cmp eax, 1                       ; 1 = usable RAM
    jne .skip_entry
    mov rax, [rsi + 8]               ; region length (64-bit)
    add r8, rax
.skip_entry:
    add rsi, 24
    dec rcx
    jmp .sum_loop
.sum_done:
    mov rsi, sysinfo_ram_total_msg
    call print_string
    mov rax, r8
    xor rdx, rdx
    mov rbx, 1024 * 1024
    div rbx
    call print_dec64
    mov rsi, sysinfo_mb_msg
    call print_string
    mov al, ASCII_CR
    call print_char

    mov rsi, sysinfo_ram_regions_msg
    call print_string
    mov eax, [MMAP_COUNT_ADDR]
    call print_dec64
    ret

; --- EAX = config address (0x80000000 | bus<<16 | dev<<11 | func<<8 | offset,
; offset 4-byte aligned). Returns the 32-bit config dword read in EAX. ---
pci_cfg_read32:
    push rdx
    mov dx, 0x0CF8
    out dx, eax
    mov dx, 0x0CFC
    in eax, dx
    pop rdx
    ret

; --- "sysinfo gpu" section: brute-force scans PCI config space (all 256
; busses - already numbered by firmware before the OS starts, so this finds
; devices behind bridges too, without needing to walk bridges by hand) for
; class 0x03 (display controller) functions. No VBE/framebuffer probing:
; just identifies what's on the bus. ---
sysinfo_gpu:
    mov rsi, sysinfo_gpu_hdr
    call print_string
    mov al, ASCII_CR
    call print_char

    xor r12d, r12d                  ; found counter
    xor ebx, ebx                    ; bus
.bus_loop:
    cmp ebx, 256
    jae .after_scan
    xor r13d, r13d                  ; device
.dev_loop:
    cmp r13d, 32
    jae .next_bus
    xor r14d, r14d                  ; function
.func_loop:
    cmp r14d, 8
    jae .next_dev

    mov eax, ebx
    shl eax, 16
    mov ecx, r13d
    shl ecx, 11
    or eax, ecx
    mov ecx, r14d
    shl ecx, 8
    or eax, ecx
    or eax, 0x80000000               ; offset 0: vendor/device ID
    call pci_cfg_read32
    cmp eax, 0xFFFFFFFF
    je .next_func                     ; no device in this slot
    mov r15d, eax                     ; save vendor:device ID

    mov eax, ebx
    shl eax, 16
    mov ecx, r13d
    shl ecx, 11
    or eax, ecx
    mov ecx, r14d
    shl ecx, 8
    or eax, ecx
    or eax, 0x80000008                ; offset 8: rev/prog-if/subclass/class
    call pci_cfg_read32
    shr eax, 24
    cmp al, 0x03                       ; class 0x03 = display controller
    jne .next_func

    inc r12d
    mov rsi, sysinfo_gpu_found_msg
    call print_string
    mov rsi, sysinfo_gpu_bus_msg
    call print_string
    mov eax, ebx
    call print_hex8
    mov rsi, sysinfo_gpu_dev_msg
    call print_string
    mov eax, r13d
    call print_hex8
    mov rsi, sysinfo_gpu_func_msg
    call print_string
    mov eax, r14d
    call print_hex8
    mov rsi, sysinfo_gpu_id_msg
    call print_string
    mov eax, r15d
    shr eax, 8
    call print_hex8
    mov eax, r15d
    call print_hex8
    mov al, ':'
    call print_char
    mov eax, r15d
    shr eax, 24
    call print_hex8
    mov eax, r15d
    shr eax, 16
    call print_hex8
    mov al, ASCII_CR
    call print_char

.next_func:
    inc r14d
    jmp .func_loop
.next_dev:
    inc r13d
    jmp .dev_loop
.next_bus:
    inc ebx
    jmp .bus_loop
.after_scan:
    or r12d, r12d
    jnz .ret
    mov rsi, sysinfo_gpu_none_msg
    call print_string
.ret:
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

; rbx = start addr, r8 = length, edx = 4-byte signature; returns match addr in
; rax or 0. Validates the table's own checksum (over its declared Length) so
; only a real, intact table is accepted - used as a brute-force fallback when
; a table can't be reached via the RSDT/XSDT (e.g. a stale/zeroed root
; pointer), mirroring how the RSDP itself is located. ---
scan_for_table:
.step:
    cmp r8, 8
    jb .none
    cmp dword [rbx], edx
    jne .next
    mov ecx, [rbx + 4]            ; declared table Length
    cmp ecx, 8
    jb .next
    cmp rcx, r8                   ; must fit within the remaining scan window
    ja .next
    push rsi
    push rcx
    mov rsi, rbx
    xor al, al
.sum:
    add al, [rsi]
    inc rsi
    loop .sum
    test al, al
    pop rcx
    pop rsi
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

; rbx = table addr, edx = expected 4-byte signature. Validates the signature
; and the table's own checksum (over its declared Length) before the caller
; trusts it as a real RSDT/XSDT - some firmware leaves stale/zeroed table
; pointers around, or the RSDP's revision byte can disagree with which root
; tables are actually valid. Returns 1 in rax on success, 0 on failure. ---
verify_table:
    cmp rbx, IDENTITY_MAP_LIMIT
    jae .fail
    cmp dword [rbx], edx
    jne .fail
    push rsi
    push rcx
    mov ecx, [rbx + 4]
    cmp ecx, 8
    jb .fail_pop
    mov rsi, rbx
    xor al, al
.sum:
    add al, [rsi]
    inc rsi
    loop .sum
    test al, al
    jnz .fail_pop
    pop rcx
    pop rsi
    mov rax, 1
    ret
.fail_pop:
    pop rcx
    pop rsi
.fail:
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
    cmp rax, IDENTITY_MAP_LIMIT   ; entry pointer may be garbage - don't deref blindly
    jae .skip
    cmp dword [rax], edx
    je .found
.skip:
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

; --- Walk an XSDT's 8-byte table pointers for a 4-byte signature.
; RBX = XSDT address, EDX = signature (e.g. 'FACP'). Returns table
; address in RAX, or 0 if not found. ---
find_table_xsdt:
    push rcx
    push rsi
    push rdx
    mov eax, [rbx + 4]
    sub eax, 36
    xor edx, edx
    mov ecx, 8
    div ecx
    mov ecx, eax
    pop rdx
    lea rsi, [rbx + 36]
.loop:
    or rcx, rcx
    jz .none
    mov rax, [rsi]
    cmp rax, IDENTITY_MAP_LIMIT   ; entry pointer may be garbage - don't deref blindly
    jae .skip
    cmp dword [rax], edx
    je .found
.skip:
    add rsi, 8
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

; --- PM1a/PM1b control register accessors. Transparently use port I/O or
; direct memory access depending on pm1a_mmio/pm1b_mmio (set when an
; extended/GAS FADT register overrides the legacy I/O port). ---
pm1a_read:                      ; returns value in AX
    cmp byte [pm1a_mmio], 0
    jne .mmio
    mov edx, [pm1a_cnt]
    in ax, dx
    ret
.mmio:
    mov r11, [pm1a_cnt]
    movzx eax, word [r11]
    ret

pm1a_write:                     ; AX = value to write
    cmp byte [pm1a_mmio], 0
    jne .mmio
    mov edx, [pm1a_cnt]
    out dx, ax
    ret
.mmio:
    mov r11, [pm1a_cnt]
    mov [r11], ax
    ret

pm1b_write:                     ; AX = value to write
    cmp byte [pm1b_mmio], 0
    jne .mmio
    mov edx, [pm1b_cnt]
    out dx, ax
    ret
.mmio:
    mov r11, [pm1b_cnt]
    mov [r11], ax
    ret

; --- CPUID.1:ECX bit 31 is reserved on real silicon and set to 1 by every
; hypervisor (QEMU, Bochs, VirtualBox, KVM, Hyper-V, ...). Used to gate the
; emulator-only magic shutdown ports so they never fire on real hardware.
; Returns 1 in rax if running under a hypervisor, 0 otherwise. ---
is_hypervisor:
    push rbx
    mov eax, 1
    cpuid
    pop rbx
    bt ecx, 31
    jc .yes
    xor rax, rax
    ret
.yes:
    mov rax, 1
    ret

; --- "shutdown" handler: real ACPI S5 power-off via RSDP -> XSDT/RSDT -> FADT ->
; DSDT _S5 scan (the standard minimal hobby-OS ACPI shutdown path - no full
; AML interpreter). Prefers the 64-bit XSDT (ACPI 2.0+) when the RSDP
; advertises one, since real hardware may have a stale/absent RSDT while the
; current FADT is only reachable via the XSDT; falls back to the legacy
; 32-bit RSDT otherwise. Falls back to the common emulator magic shutdown
; ports, and finally to a plain halt, if every real ACPI path fails. ---
cmd_shutdown:
    call find_rsdp
    or rax, rax
    jz .fallback_ports
    mov r10, rax                 ; r10 = RSDP address (kept across both table lookups)

    ; Some real firmware builds the full ACPI 2.0+ RSDP (with a valid XSDT
    ; pointer at offset 24) but leaves the Revision byte at 0 anyway, since
    ; only the first 20 bytes are covered by the legacy checksum. So try the
    ; XSDT whenever it verifies as real, regardless of the revision byte.
    ; verify_table bounds-checks and checksums it before it's ever
    ; dereferenced, since a revision-0 RSDP's extended fields can be garbage.
    mov rbx, [r10 + 24]           ; XsdtAddress (qword)
    or rbx, rbx
    jz .try_rsdt
    mov edx, 'XSDT'
    call verify_table
    or rax, rax
    jz .try_rsdt
    mov edx, 'FACP'
    call find_table_xsdt
    or rax, rax
    jz .try_rsdt
    mov rbx, rax                 ; rbx = FADT address (found via XSDT)
    jmp .have_fadt

.try_rsdt:
    mov eax, [r10 + 16]         ; RSDT address
    or eax, eax
    jz .try_scan
    mov rbx, rax
    mov edx, 'RSDT'
    call verify_table
    or rax, rax
    jz .try_scan

    mov edx, 'FACP'
    call find_table
    or rax, rax
    jz .try_scan
    mov rbx, rax                 ; rbx = FADT address (found via RSDT)
    jmp .have_fadt

.try_scan:
    ; Root table traversal failed (missing/stale pointer, or FADT genuinely
    ; unlisted) - brute-force scan the same regions find_rsdp uses, exactly
    ; like the RSDP itself is located.
    mov edx, 'FACP'
    movzx rbx, word [0x40E]
    shl rbx, 4
    mov r8, 0x400
    call scan_for_table
    or rax, rax
    jnz .scan_found
    mov edx, 'FACP'
    mov rbx, 0xE0000
    mov r8, 0x20000
    call scan_for_table
    or rax, rax
    jz .fallback_ports
.scan_found:
    mov rbx, rax                  ; rbx = FADT address (found via brute scan)

.have_fadt:
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

    mov byte [pm1a_mmio], 0
    mov byte [pm1b_mmio], 0
    mov ecx, [rbx + 4]           ; FADT Length

    cmp ecx, 160                  ; reaches X_PM1a_CNT_BLK (offset 148) + 12
    jb .no_ext_a
    movzx eax, byte [rbx + 148]   ; X_PM1a_CNT_BLK.AddressSpaceId
    cmp al, 1
    je .ext_a_ok
    cmp al, 0
    jne .no_ext_a
.ext_a_ok:
    mov rdx, [rbx + 152]          ; X_PM1a_CNT_BLK.Address
    or rdx, rdx
    jz .no_ext_a
    mov [pm1a_cnt], rdx
    xor al, 1
    mov [pm1a_mmio], al
.no_ext_a:

    cmp ecx, 172                  ; reaches X_PM1b_CNT_BLK (offset 160) + 12
    jb .no_ext_b
    movzx eax, byte [rbx + 160]   ; X_PM1b_CNT_BLK.AddressSpaceId
    cmp al, 1
    je .ext_b_ok
    cmp al, 0
    jne .no_ext_b
.ext_b_ok:
    mov rdx, [rbx + 164]          ; X_PM1b_CNT_BLK.Address
    or rdx, rdx
    jz .no_ext_b
    mov [pm1b_cnt], rdx
    xor al, 1
    mov [pm1b_mmio], al
.no_ext_b:

    call pm1a_read
    test al, 1
    jnz .acpi_enabled
    mov edx, [smi_cmd]
    or edx, edx
    jz .fallback_ports
    mov al, [acpi_enable_val]
    out dx, al
    mov rcx, 1000000
.wait_enable:
    call pm1a_read
    test al, 1
    jnz .acpi_enabled
    loop .wait_enable
    jmp .fallback_ports
.acpi_enabled:

    mov rbx, [dsdt_addr]
    or rbx, rbx
    jz .fallback_ports
    cmp rbx, IDENTITY_MAP_LIMIT
    jae .fallback_ports
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

    cmp qword [slp_typa], 7
    ja .fallback_ports
    cmp qword [slp_typb], 7
    ja .fallback_ports

    mov rax, [slp_typa]
    shl rax, 10
    or rax, 1 << 13
    call pm1a_write

    mov rax, [pm1b_cnt]
    or rax, rax
    jz .after_b
    mov rax, [slp_typb]
    shl rax, 10
    or rax, 1 << 13
    call pm1b_write
.after_b:
.fallback_ports:
    ; These ports/values are magic shutdown signals QEMU/Bochs/VirtualBox
    ; watch for - they mean nothing to real hardware. But real chipsets can
    ; and do map their actual ACPI PM1a_CNT block at nearby I/O addresses,
    ; and 0x2000 sets the real SLP_EN bit - so blindly writing these outside
    ; an emulator risks triggering a genuine (and on some machines, wrongly
    ; mapped to "reset" rather than "off") ACPI sleep transition. Only try
    ; them when a hypervisor is actually present.
    call is_hypervisor
    or rax, rax
    jz .print_fail
    mov dx, 0x604
    mov ax, 0x2000
    out dx, ax
    mov dx, 0xB004
    mov ax, 0x2000
    out dx, ax
    mov dx, 0x4004
    mov ax, 0x3400
    out dx, ax

.print_fail:
    mov rsi, shutdown_fail_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    cli
.hang:
    hlt
    jmp .hang

; --- "acpi" handler: read-only diagnostic that walks the same discovery path
; as cmd_shutdown (RSDP -> XSDT/RSDT -> FADT -> PM1a/b registers -> DSDT ->
; _S5) and prints what it finds at each step. Never writes SMI_CMD or
; PM1_CNT, never changes power state - purely for figuring out where a real
; machine's shutdown path diverges from what QEMU does. ---
cmd_acpi:
    mov rsi, acpi_rsdp_msg
    call print_string
    call find_rsdp
    or rax, rax
    jnz .have_rsdp
    mov rsi, acpi_notfound_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret
.have_rsdp:
    call print_hex64
    mov al, ASCII_CR
    call print_char
    mov r10, rax                 ; r10 = RSDP address

    mov rsi, acpi_rev_msg
    call print_string
    movzx rax, byte [r10 + 15]
    call print_dec64
    mov al, ASCII_CR
    call print_char

    mov rsi, acpi_fadt_msg
    call print_string
    mov rbx, [r10 + 24]
    or rbx, rbx
    jz .try_rsdt
    mov edx, 'XSDT'
    call verify_table
    or rax, rax
    jz .try_rsdt
    mov edx, 'FACP'
    call find_table_xsdt
    or rax, rax
    jz .try_rsdt
    mov rbx, rax
    mov rsi, acpi_via_xsdt_msg
    call print_string
    jmp .have_fadt

.try_rsdt:
    mov eax, [r10 + 16]
    or eax, eax
    jz .try_scan
    mov rbx, rax
    mov edx, 'RSDT'
    call verify_table
    or rax, rax
    jz .try_scan

    mov edx, 'FACP'
    call find_table
    or rax, rax
    jz .try_scan
    mov rbx, rax
    mov rsi, acpi_via_rsdt_msg
    call print_string
    jmp .have_fadt

.try_scan:
    mov edx, 'FACP'
    movzx rbx, word [0x40E]
    shl rbx, 4
    mov r8, 0x400
    call scan_for_table
    or rax, rax
    jnz .scan_found
    mov edx, 'FACP'
    mov rbx, 0xE0000
    mov r8, 0x20000
    call scan_for_table
    or rax, rax
    jz .no_fadt
.scan_found:
    mov rbx, rax
    mov rsi, acpi_via_scan_msg
    call print_string
    jmp .have_fadt

.no_fadt:
    mov rsi, acpi_notfound_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

.have_fadt:
    mov rax, rbx
    call print_hex64
    mov al, ASCII_CR
    call print_char

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

    mov byte [pm1a_mmio], 0
    mov byte [pm1b_mmio], 0
    mov ecx, [rbx + 4]

    cmp ecx, 160
    jb .no_ext_a
    movzx eax, byte [rbx + 148]
    cmp al, 1
    je .ext_a_ok
    cmp al, 0
    jne .no_ext_a
.ext_a_ok:
    mov rdx, [rbx + 152]
    or rdx, rdx
    jz .no_ext_a
    mov [pm1a_cnt], rdx
    xor al, 1
    mov [pm1a_mmio], al
.no_ext_a:

    cmp ecx, 172
    jb .no_ext_b
    movzx eax, byte [rbx + 160]
    cmp al, 1
    je .ext_b_ok
    cmp al, 0
    jne .no_ext_b
.ext_b_ok:
    mov rdx, [rbx + 164]
    or rdx, rdx
    jz .no_ext_b
    mov [pm1b_cnt], rdx
    xor al, 1
    mov [pm1b_mmio], al
.no_ext_b:

    mov rsi, acpi_pm1a_msg
    call print_string
    mov rax, [pm1a_cnt]
    call print_hex64
    mov rsi, acpi_space_msg
    call print_string
    cmp byte [pm1a_mmio], 0
    jne .pm1a_mem
    mov rsi, acpi_io_msg
    call print_string
    jmp .pm1a_space_done
.pm1a_mem:
    mov rsi, acpi_mem_msg
    call print_string
.pm1a_space_done:
    mov al, ASCII_CR
    call print_char

    mov rsi, acpi_pm1b_msg
    call print_string
    mov rax, [pm1b_cnt]
    or rax, rax
    jz .pm1b_none
    call print_hex64
    mov rsi, acpi_space_msg
    call print_string
    cmp byte [pm1b_mmio], 0
    jne .pm1b_mem
    mov rsi, acpi_io_msg
    call print_string
    jmp .pm1b_space_done
.pm1b_mem:
    mov rsi, acpi_mem_msg
    call print_string
.pm1b_space_done:
    jmp .pm1b_line_done
.pm1b_none:
    mov rsi, acpi_none_msg
    call print_string
.pm1b_line_done:
    mov al, ASCII_CR
    call print_char

    mov rsi, acpi_enabled_msg
    call print_string
    call pm1a_read
    test al, 1
    jz .not_enabled
    mov rsi, acpi_yes_msg
    call print_string
    jmp .enabled_done
.not_enabled:
    mov rsi, acpi_no_msg
    call print_string
.enabled_done:
    mov al, ASCII_CR
    call print_char

    mov rsi, acpi_dsdt_msg
    call print_string
    mov rax, [dsdt_addr]
    or rax, rax
    jz .no_dsdt
    cmp rax, IDENTITY_MAP_LIMIT
    jae .no_dsdt
    call print_hex64
    mov al, ASCII_CR
    call print_char
    jmp .have_dsdt

.no_dsdt:
    mov rsi, acpi_notfound_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

.have_dsdt:
    mov rsi, acpi_s5_msg
    call print_string
    mov rbx, [dsdt_addr]
    call find_s5
    or rax, rax
    jnz .have_s5
    mov rsi, acpi_notfound_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

.have_s5:
    mov rsi, acpi_found_msg
    call print_string
    mov al, ASCII_CR
    call print_char

    mov rsi, rax
    cmp byte [rsi], 0x12
    jne .bad_s5
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

    mov rsi, acpi_typa_msg
    call print_string
    mov rax, [slp_typa]
    call print_dec64
    mov rsi, acpi_typb_msg
    call print_string
    mov rax, [slp_typb]
    call print_dec64

    cmp qword [slp_typa], 7
    ja .invalid_s5
    cmp qword [slp_typb], 7
    ja .invalid_s5
    mov rsi, acpi_valid_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

.invalid_s5:
    mov rsi, acpi_invalid_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

.bad_s5:
    mov rsi, acpi_badpkg_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

; --- "date" handler: prints the RTC date as DD/MM/YYYY ---
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
    dq acpi_cmd, acpi_cmd_end - acpi_cmd, cmd_acpi
    dq color_cmd, color_cmd_end - color_cmd, cmd_color
    dq sysinfo_cmd, sysinfo_cmd_end - sysinfo_cmd, cmd_sysinfo
    dq date_cmd, date_cmd_end - date_cmd, cmd_date
    dq time_cmd, time_cmd_end - time_cmd, cmd_time
    dq cursor_cmd, cursor_cmd_end - cursor_cmd, cmd_cursor_toggle
    dq 0

command_descriptions:
    dq desc_echo,     desc_echo_end - desc_echo
    dq desc_run,      desc_run_end - desc_run
    dq desc_clear,    desc_clear_end - desc_clear
    dq desc_help,     desc_help_end - desc_help
    dq desc_reboot,   desc_reboot_end - desc_reboot
    dq desc_halt,     desc_halt_end - desc_halt
    dq desc_mem,      desc_mem_end - desc_mem
    dq desc_peek,     desc_peek_end - desc_peek
    dq desc_poke,     desc_poke_end - desc_poke
    dq desc_cpuid,    desc_cpuid_end - desc_cpuid
    dq desc_uptime,   desc_uptime_end - desc_uptime
    dq desc_shutdown, desc_shutdown_end - desc_shutdown
    dq desc_acpi,     desc_acpi_end - desc_acpi
    dq desc_color,    desc_color_end - desc_color
    dq desc_sysinfo,  desc_sysinfo_end - desc_sysinfo
    dq desc_date,     desc_date_end - desc_date
    dq desc_time,     desc_time_end - desc_time
    dq desc_cursor,   desc_cursor_end - desc_cursor

desc_echo db "print the given text"
desc_echo_end:
desc_run db "assemble and execute raw hex machine code: run <hex bytes>"
desc_run_end:
desc_clear db "clear the screen"
desc_clear_end:
desc_help db "list available commands"
desc_help_end:
desc_reboot db "reboot the machine"
desc_reboot_end:
desc_halt db "halt the CPU"
desc_halt_end:
desc_mem db "hexdump memory: mem <addr> <len>"
desc_mem_end:
desc_peek db "read a byte from memory: peek <addr>"
desc_peek_end:
desc_poke db "write a byte to memory: poke <addr> <value>"
desc_poke_end:
desc_cpuid db "run CPUID: cpuid [leaf]"
desc_cpuid_end:
desc_uptime db "show system uptime"
desc_uptime_end:
desc_shutdown db "power off the machine"
desc_shutdown_end:
desc_acpi db "probe and display ACPI power-management tables"
desc_acpi_end:
desc_color db "set text color: color <red|green|blue|yellow|white|HH>"
desc_color_end:
desc_sysinfo db "show hardware info: sysinfo [cpu|ram|gpu|general]"
desc_sysinfo_end:
desc_date db "show the current date"
desc_date_end:
desc_time db "show the current time"
desc_time_end:
desc_cursor db "experimental: toggle the PS/2 mouse cell cursor: cursor <on|off>"
desc_cursor_end:

help_sep db " - ", 0
color_usage_msg db "Usage: color <red|green|blue|yellow|white|HH>", 0
sysinfo_usage_msg db "Usage: sysinfo <cpu|ram|gpu|general>", 0
cursor_usage_msg db "Usage: cursor <on|off>", 0
cursor_on_msg db "Cursor on (experimental).", 0
cursor_off_msg db "Cursor off.", 0

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

; --- Hide the hardware text-mode cursor (used while scrolled into history) ---
hide_cursor:
    push rax
    push rdx

    mov dx, CRTC_INDEX
    mov al, CRTC_CURSOR_START
    out dx, al
    mov dx, CRTC_DATA
    in al, dx
    mov [cursor_start_shape], al

    mov dx, CRTC_INDEX
    mov al, CRTC_CURSOR_START
    out dx, al
    mov dx, CRTC_DATA
    mov al, CRTC_CURSOR_DISABLE_BIT
    out dx, al

    pop rdx
    pop rax
    ret

; --- Show the hardware text-mode cursor and place it back at cursor_pos ---
show_cursor:
    push rax
    push rdx

    mov dx, CRTC_INDEX
    mov al, CRTC_CURSOR_START
    out dx, al
    mov dx, CRTC_DATA
    mov al, [cursor_start_shape]
    out dx, al

    pop rdx
    pop rax
    call update_cursor
    ret

; --- Print one character in AL to the VGA buffer, tracking cursor_pos ---
print_char:
    push rax
    call snap_scroll_to_live
    pop rax

    cmp al, ASCII_CR
    je .newline
    cmp al, ASCII_BS
    je .backspace

    mov rdi, [cursor_pos]
    add rdi, VGA_MEM
    mov [rdi], al
    mov dl, [text_attr]
    mov [rdi + 1], dl
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
    mov dl, [text_attr]
    mov [rdi + 1], dl
    jmp .ret

.wrap_check:
    cmp qword [cursor_pos], VGA_SIZE
    jl .ret
    call scroll_screen
    mov qword [cursor_pos], VGA_LAST_ROW  ; back to the start of the (now-cleared) last row
.ret:
    call update_cursor
    ret

; --- Scroll the VGA text buffer up one row, clearing the new bottom row.
; Saves the row about to be discarded into the history ring buffer. ---
scroll_screen:
    push rsi
    push rdi
    push rcx

    call cursor_erase_highlight    ; don't bake the highlight into history

    ; save row 0 (about to scroll off) into history[hist_write % HIST_ROWS]
    movzx rax, word [hist_write]
    xor rdx, rdx
    mov rcx, HIST_ROWS
    div rcx                    ; rdx = hist_write mod HIST_ROWS
    mov rax, rdx
    mov rcx, VGA_ROW_BYTES
    mul rcx
    lea rdi, [history_buffer + rax]
    mov rsi, VGA_MEM
    push rcx
    mov rcx, VGA_ROW_BYTES
    rep movsb
    pop rcx
    inc word [hist_write]
    cmp word [hist_count], HIST_ROWS
    jae .hist_count_capped
    inc word [hist_count]
.hist_count_capped:

    mov rsi, VGA_MEM + VGA_ROW_BYTES
    mov rdi, VGA_MEM
    mov rcx, VGA_LAST_ROW      ; (VGA_ROWS-1) rows worth of bytes, safe to copy forward
    rep movsb

    mov rdi, VGA_MEM + VGA_LAST_ROW
    mov rcx, VGA_COLS
    mov dl, [text_attr]
.clear_loop2:
    mov byte [rdi], ' '
    mov [rdi + 1], dl
    add rdi, 2
    loop .clear_loop2

    call cursor_refresh_if_enabled

    pop rcx
    pop rdi
    pop rsi
    ret

; --- Copy history row (hist_write - scroll_offset - rowIndexFromTop) into
; VGA row `vga_row` (0-based), or blank it if that far back has no data. ---
render_history_row:
    ; in: rax = rows-back-from-live-top (0 = most recent scrolled-off row), rbx = vga_row
    push rcx
    push rdx
    push rsi
    push rdi

    movzx rcx, word [hist_count]
    cmp rax, rcx
    jae .blank_row

    movzx rcx, word [hist_write]
    sub rcx, 1
    sub rcx, rax                ; rcx = absolute history index (may underflow mod HIST_ROWS)
    xor rdx, rdx
    push rax
    mov rax, rcx
    mov rcx, HIST_ROWS
    idiv rcx
    mov rcx, rdx
    pop rax
    cmp rcx, 0
    jge .have_index
    add rcx, HIST_ROWS
.have_index:
    mov rax, rcx
    mov rcx, VGA_ROW_BYTES
    mul rcx
    lea rsi, [history_buffer + rax]
    mov rax, rbx
    mov rcx, VGA_ROW_BYTES
    mul rcx
    lea rdi, [VGA_MEM + rax]
    mov rcx, VGA_ROW_BYTES
    rep movsb
    jmp .done

.blank_row:
    mov rax, rbx
    mov rcx, VGA_ROW_BYTES
    mul rcx
    lea rdi, [VGA_MEM + rax]
    mov rcx, VGA_COLS
    mov dl, VGA_ATTR
.blank_loop:
    mov byte [rdi], ' '
    mov [rdi + 1], dl
    add rdi, 2
    loop .blank_loop

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; --- Rebuild the full VGA_MEM screen for the current scroll_offset: rows
; above the live buffer come from history_buffer (older toward the top),
; the rest are copied from live_shadow (the true, unscrolled live screen). ---
repaint_scrolled_view:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi

    xor rbx, rbx
.row_loop:
    cmp rbx, VGA_ROWS
    jae .row_done
    movzx rax, word [scroll_offset]
    cmp rbx, rax
    jae .live_row
    ; history row: rows_back = scroll_offset - rbx - 1 (0 = most recent)
    sub rax, rbx
    dec rax
    call render_history_row
    jmp .row_next
.live_row:
    ; copy the corresponding row from live_shadow (row = rbx - scroll_offset)
    mov rax, rbx
    movzx rcx, word [scroll_offset]
    sub rax, rcx
    mov rcx, VGA_ROW_BYTES
    mul rcx
    lea rsi, [live_shadow + rax]
    mov rax, rbx
    mov rcx, VGA_ROW_BYTES
    mul rcx
    lea rdi, [VGA_MEM + rax]
    mov rcx, VGA_ROW_BYTES
    rep movsb
.row_next:
    inc rbx
    jmp .row_loop
.row_done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; --- Scroll the view one row further into history (toward older output). ---
scroll_view_up:
    push rax

    movzx rax, word [scroll_offset]
    cmp ax, [hist_count]
    jae .done
    cmp word [scroll_offset], 0
    jne .not_first
    call cursor_erase_highlight    ; don't bake the highlight into live_shadow
    call save_live_shadow
    call hide_cursor
.not_first:
    inc word [scroll_offset]
    call repaint_scrolled_view
    call cursor_refresh_if_enabled

.done:
    pop rax
    ret

; --- Scroll the view one row toward the live output; snaps to live at 0. ---
scroll_view_down:
    cmp word [scroll_offset], 0
    je .done
    dec word [scroll_offset]
    cmp word [scroll_offset], 0
    jne .repaint
    call restore_live_shadow
    call show_cursor
    call cursor_refresh_if_enabled
    jmp .done
.repaint:
    call repaint_scrolled_view
    call cursor_refresh_if_enabled
.done:
    ret

; --- Snapshot the live VGA screen into live_shadow before it gets
; overwritten by history rows. ---
save_live_shadow:
    push rsi
    push rdi
    push rcx
    mov rsi, VGA_MEM
    mov rdi, live_shadow
    mov rcx, VGA_SIZE
    rep movsb
    pop rcx
    pop rdi
    pop rsi
    ret

; --- Restore the live VGA screen from live_shadow. ---
restore_live_shadow:
    push rsi
    push rdi
    push rcx
    mov rsi, live_shadow
    mov rdi, VGA_MEM
    mov rcx, VGA_SIZE
    rep movsb
    pop rcx
    pop rdi
    pop rsi
    ret

; --- If the view is scrolled into history, snap back to live before any
; input mutates the live buffer. ---
snap_scroll_to_live:
    cmp word [scroll_offset], 0
    je .done
    mov word [scroll_offset], 0
    call restore_live_shadow
    call show_cursor
    call cursor_refresh_if_enabled
.done:
    ret

; --- Re-draw the mouse cursor highlight over freshly repainted content, if
; the experimental cursor is currently enabled. ---
cursor_refresh_if_enabled:
    cmp byte [cursor_enabled], 0
    je .done
    call cursor_draw_highlight
.done:
    ret

; --- Experimental mouse-driven cell cursor: a highlighted cell (VGA_ATTR_SEL)
; at (mouse_x, mouse_y), moved by IRQ12 PS/2 packets while `cursor on`. ---

; --- Highlight the cell at (mouse_x, mouse_y), saving its current attribute
; so it can be restored later. No-op if a cell is already highlighted (call
; cursor_erase_highlight first if moving it). ---
cursor_draw_highlight:
    push rax
    push rcx
    push rdx
    push rdi

    movzx rax, byte [mouse_y]
    mov rcx, VGA_ROW_BYTES
    mul rcx
    movzx rcx, byte [mouse_x]
    shl rcx, 1
    add rax, rcx
    lea rdi, [VGA_MEM + rax]

    mov al, [rdi + 1]
    mov [cursor_cell_saved_attr], al
    mov byte [rdi + 1], VGA_ATTR_SEL
    mov byte [cursor_cell_valid], 1

    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; --- Restore the attribute under the highlighted cell, if any. ---
cursor_erase_highlight:
    cmp byte [cursor_cell_valid], 0
    je .done
    push rax
    push rcx
    push rdx
    push rdi

    movzx rax, byte [mouse_y]
    mov rcx, VGA_ROW_BYTES
    mul rcx
    movzx rcx, byte [mouse_x]
    shl rcx, 1
    add rax, rcx
    lea rdi, [VGA_MEM + rax]

    mov al, [cursor_cell_saved_attr]
    mov [rdi + 1], al
    mov byte [cursor_cell_valid], 0

    pop rdi
    pop rdx
    pop rcx
    pop rax
.done:
    ret

; --- IRQ12 handler: accumulate a 3-byte PS/2 mouse packet, then either move
; the highlighted cursor cell (button state without the right button held)
; or, while the right button is held, use vertical movement to drive
; scroll_view_up/scroll_view_down (no scroll wheel on a plain PS/2 mouse). ---
mouse_isr:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    in al, KBD_DATA_PORT
    movzx rbx, byte [mouse_packet_idx]
    cmp bl, 0
    jne .not_first_byte
    test al, MOUSE_ALWAYS1_BIT
    jz .eoi                        ; resync: drop a stray byte, don't advance
.not_first_byte:
    mov [mouse_packet + rbx], al
    inc bl
    mov [mouse_packet_idx], bl
    movzx rcx, byte [mouse_packet_size]
    cmp rbx, rcx
    jb .eoi

    mov byte [mouse_packet_idx], 0
    cmp byte [cursor_enabled], 0
    je .eoi

    mov bl, [mouse_packet]          ; byte0: buttons + sign/overflow bits
    test bl, MOUSE_OVERFLOW_X
    jnz .eoi
    test bl, MOUSE_OVERFLOW_Y
    jnz .eoi

    ; --- scroll wheel (IntelliMouse 4th byte): signed, +down/-up, independent
    ; of button state ---
    cmp byte [mouse_has_wheel], 0
    je .no_wheel
    movsx rax, byte [mouse_packet + 3]
    or rax, rax
    jz .no_wheel
    jg .wheel_down
    call scroll_view_up
    jmp .no_wheel
.wheel_down:
    call scroll_view_down
.no_wheel:
    mov bl, [mouse_packet]          ; reload: scroll_view_* may have clobbered rbx

    ; --- left-click edge: place the input caret under the cursor cell ---
    test bl, MOUSE_BTN_LEFT
    jz .no_left_edge
    test byte [mouse_prev_buttons], MOUSE_BTN_LEFT
    jnz .no_left_edge
    push rbx
    call mouse_try_place_caret
    pop rbx
.no_left_edge:
    mov [mouse_prev_buttons], bl

    movzx rax, byte [mouse_packet + 1]   ; dx, 9-bit two's complement
    test bl, MOUSE_SIGN_X
    jz .dx_ready
    sub rax, 256
.dx_ready:
    movzx rdx, byte [mouse_packet + 2]   ; dy, positive = moved up
    test bl, MOUSE_SIGN_Y
    jz .dy_ready
    sub rdx, 256
.dy_ready:

    test bl, MOUSE_BTN_RIGHT
    jnz .scroll_drag

    mov word [mouse_scroll_accum], 0
    call cursor_erase_highlight     ; erase at the OLD position before it moves

    mov rcx, rax
    sar rcx, 2                     ; scale pixel-ish deltas down to cell steps
    movzx rax, byte [mouse_x]
    add rax, rcx
    cmp rax, 0
    jge .x_not_neg
    xor rax, rax
.x_not_neg:
    cmp rax, VGA_COLS - 1
    jle .x_not_over
    mov rax, VGA_COLS - 1
.x_not_over:
    mov [mouse_x], al

    mov rcx, rdx
    sar rcx, 2
    movzx rax, byte [mouse_y]
    sub rax, rcx                   ; dy positive (up) moves row toward 0
    cmp rax, 0
    jge .y_not_neg
    xor rax, rax
.y_not_neg:
    cmp rax, VGA_ROWS - 1
    jle .y_not_over
    mov rax, VGA_ROWS - 1
.y_not_over:
    mov [mouse_y], al

    call cursor_draw_highlight
    jmp .eoi

.scroll_drag:
    movsx rcx, word [mouse_scroll_accum]
    add rcx, rdx
    cmp rcx, MOUSE_SCROLL_THRESHOLD
    jl .check_neg
    call scroll_view_up
    sub rcx, MOUSE_SCROLL_THRESHOLD
    jmp .store_accum
.check_neg:
    cmp rcx, -MOUSE_SCROLL_THRESHOLD
    jg .store_accum
    call scroll_view_down
    add rcx, MOUSE_SCROLL_THRESHOLD
.store_accum:
    mov [mouse_scroll_accum], cx

.eoi:
    mov al, PIC_EOI
    out PIC2_CMD, al                ; EOI slave first, then master (cascaded IRQ)
    out PIC1_CMD, al
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    iretq

; place the input-line text-edit caret at the mouse-highlighted cell,
; if (and only if) that cell is on the current prompt's row
mouse_try_place_caret:
    push rax
    push rcx
    push rdx

    cmp word [scroll_offset], 0
    jne .done

    mov rax, [line_start_pos]
    shr rax, 1                     ; byte offset -> character cell index

    movzx rcx, byte [mouse_y]
    imul rcx, VGA_COLS
    movzx rdx, byte [mouse_x]
    add rcx, rdx
    sub rcx, rax

    cmp rcx, 0
    jl .done
    movzx rdx, byte [cmd_len]
    cmp rcx, rdx
    jg .done

    mov [cmd_cursor], cl
    mov byte [sel_active], 0
    call redraw_input_line

.done:
    pop rdx
    pop rcx
    pop rax
    ret

; --- "cursor" handler: toggle the experimental mouse-driven cell cursor ---
cmd_cursor_toggle:
    call skip_spaces
    cmp byte [rsi], 'o'
    jne .usage
    cmp byte [rsi + 1], 'n'
    jne .maybe_off
    cmp byte [rsi + 2], 0
    jne .usage

    call cursor_erase_highlight
    mov byte [mouse_x], VGA_COLS / 2
    mov byte [mouse_y], VGA_ROWS / 2
    mov byte [cursor_enabled], 1
    mov al, MOUSE_CMD_ENABLE_REPORTING
    call mouse_write_cmd
    call cursor_draw_highlight
    mov rsi, cursor_on_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

.maybe_off:
    cmp byte [rsi + 1], 'f'
    jne .usage
    cmp byte [rsi + 2], 'f'
    jne .usage
    cmp byte [rsi + 3], 0
    jne .usage

    mov byte [cursor_enabled], 0
    mov al, MOUSE_CMD_DISABLE_REPORTING
    call mouse_write_cmd
    call cursor_erase_highlight
    mov rsi, cursor_off_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

.usage:
    mov rsi, cursor_usage_msg
    call print_string
    mov al, ASCII_CR
    call print_char
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
acpi_cmd db "acpi"
acpi_cmd_end:
color_cmd db "color"
color_cmd_end:
sysinfo_cmd db "sysinfo"
sysinfo_cmd_end:
date_cmd db "date"
date_cmd_end:
time_cmd db "time"
time_cmd_end:
cursor_cmd db "cursor"
cursor_cmd_end:
unknown_msg db "Unknown command: ", 0
run_bad_hex_msg db "Invalid hex byte", 0
run_too_long_msg db "Too many bytes for exec_buffer", 0
reboot_msg db "Rebooting...", 0
halt_msg db "Halted.", 0
shutdown_fail_msg db "Shutdown failed - it's now safe to turn off your computer.", 0
uptime_suffix db " s", 0
rsdp_sig db "RSD PTR "

acpi_rsdp_msg db "RSDP: ", 0
acpi_rev_msg db "ACPI revision: ", 0
acpi_fadt_msg db "FADT: ", 0
acpi_via_xsdt_msg db "(via XSDT) ", 0
acpi_via_rsdt_msg db "(via RSDT) ", 0
acpi_via_scan_msg db "(via scan) ", 0
acpi_pm1a_msg db "PM1a_CNT: ", 0
acpi_pm1b_msg db "PM1b_CNT: ", 0
acpi_space_msg db " ", 0
acpi_io_msg db "(io)", 0
acpi_mem_msg db "(mmio)", 0
acpi_none_msg db "none", 0
acpi_enabled_msg db "ACPI already enabled: ", 0
acpi_yes_msg db "yes", 0
acpi_no_msg db "no", 0
acpi_dsdt_msg db "DSDT: ", 0
acpi_s5_msg db "_S5: ", 0
acpi_found_msg db "found ", 0
acpi_notfound_msg db "not found", 0
acpi_typa_msg db "SLP_TYPa=", 0
acpi_typb_msg db " SLP_TYPb=", 0
acpi_valid_msg db " (valid)", 0
acpi_invalid_msg db " (INVALID)", 0
acpi_badpkg_msg db "_S5 package decode failed (unexpected AML structure)", 0

si_cpu_str db "cpu", 0
si_ram_str db "ram", 0
si_gpu_str db "gpu", 0
si_general_str db "general", 0

sysinfo_cpu_hdr db "-- CPU --", 0
sysinfo_vendor_msg db "Vendor: ", 0
sysinfo_brand_msg db "Model: ", 0
sysinfo_family_msg db "Family: ", 0
sysinfo_model_msg db " Model: ", 0
sysinfo_stepping_msg db " Stepping: ", 0
sysinfo_cores_msg db "Logical CPUs: ", 0
sysinfo_cores_unknown_msg db "unknown (no MADT)", 0
sysinfo_unknown_msg db "unknown", 0

sysinfo_ram_hdr db "-- RAM --", 0
sysinfo_ram_unavailable_msg db "not available (BIOS E820 unsupported)", 0
sysinfo_ram_total_msg db "Usable RAM: ", 0
sysinfo_mb_msg db " MB", 0
sysinfo_ram_regions_msg db "Memory map regions: ", 0

sysinfo_gpu_hdr db "-- GPU --", 0
sysinfo_gpu_found_msg db "PCI ", 0
sysinfo_gpu_bus_msg db " bus ", 0
sysinfo_gpu_dev_msg db " dev ", 0
sysinfo_gpu_func_msg db " func ", 0
sysinfo_gpu_id_msg db " id ", 0
sysinfo_gpu_none_msg db "no display controller found on the PCI bus", 0

; Preset color name table: {name_ptr, name_len, attr_byte}, 17 bytes each,
; ends with a zero name_ptr. Attr byte = white background (0x7) foreground,
; matching VGA_ATTR's black-background scheme (0x0_).
color_names:
    dq color_red,    color_red_end - color_red,    0x04
    dq color_green,  color_green_end - color_green, 0x02
    dq color_blue,   color_blue_end - color_blue,   0x01
    dq color_yellow, color_yellow_end - color_yellow, 0x0E
    dq color_white,  color_white_end - color_white, 0x0F
    dq 0

color_red db "red"
color_red_end:
color_green db "green"
color_green_end:
color_blue db "blue"
color_blue_end:
color_yellow db "yellow"
color_yellow_end:
color_white db "white"
color_white_end:

null_idt_descriptor:
    dw 0
    dq 0

cursor_pos dq 0
text_attr db VGA_ATTR
cmd_len db 0
cmd_buffer times CMD_BUFFER_SIZE db 0
timer_ticks dq 0
cpuid_vendor times 13 db 0
cpu_brand times 49 db 0
dec_buffer times 21 db 0
pm1a_cnt dq 0
pm1b_cnt dq 0
pm1a_mmio db 0
pm1b_mmio db 0
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
ctrl_state db 0
extended_pending db 0
cmd_cursor db 0
sel_active db 0
sel_anchor db 0
cmd_render_len db 0
line_start_pos dq 0
scroll_offset dw 0
cursor_start_shape db 0
hist_write dw 0
hist_count dw 0
history_buffer times HIST_ROWS * VGA_ROW_BYTES db 0
live_shadow times VGA_SIZE db 0

; Experimental mouse cursor state (see `cursor` command / mouse_isr)
cursor_enabled db 0
mouse_x db 0
mouse_y db 0
mouse_packet times 4 db 0
mouse_packet_idx db 0
mouse_packet_size db 3
mouse_has_wheel db 0
mouse_prev_buttons db 0
mouse_scroll_accum dw 0
cursor_cell_valid db 0
cursor_cell_saved_attr db 0

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

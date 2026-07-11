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
    cmp byte [shift_state], 0
    jne .arrow_up_scroll
    call snap_scroll_to_live
    call history_recall_prev
    jmp .eoi
.arrow_up_scroll:
    call scroll_view_up
    jmp .eoi

.arrow_down:
    test bl, KBD_BREAK_BIT
    jnz .eoi
    cmp byte [shift_state], 0
    jne .arrow_down_scroll
    call snap_scroll_to_live
    call history_recall_next
    jmp .eoi
.arrow_down_scroll:
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
    call history_push
    call process_command
    mov byte [cmd_len], 0
    mov byte [cmd_cursor], 0
    mov byte [sel_active], 0
    mov byte [cmd_render_len], 0
    mov word [cmd_history_pos], 0
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

; --- Append cmd_buffer (length cmd_len) to the command history ring buffer.
; Called on Enter, before cmd_buffer is cleared. Skips empty lines. ---
history_push:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi

    cmp byte [cmd_len], 0
    je .done

    movzx rax, word [cmd_history_write]
    mov rcx, CMD_BUFFER_SIZE
    mul rcx
    lea rdi, [cmd_history + rax]
    mov rsi, cmd_buffer
    movzx rcx, byte [cmd_len]
    rep movsb

    movzx rax, word [cmd_history_write]
    movzx rdx, byte [cmd_len]
    mov [cmd_history_len + rax], dl

    inc word [cmd_history_write]
    cmp word [cmd_history_write], CMD_HISTORY_ENTRIES
    jne .no_wrap
    mov word [cmd_history_write], 0
.no_wrap:
    cmp word [cmd_history_count], CMD_HISTORY_ENTRIES
    jae .done
    inc word [cmd_history_count]

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; --- Recall the previous (older) history entry into cmd_buffer, saving the
; in-progress line first if this is the first Up press. ---
history_recall_prev:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi

    movzx rax, word [cmd_history_count]
    cmp [cmd_history_pos], ax
    jae .done

    cmp word [cmd_history_pos], 0
    jne .no_save
    movzx rcx, byte [cmd_len]
    mov rsi, cmd_buffer
    mov rdi, cmd_history_saved
    rep movsb
    mov al, [cmd_len]
    mov [cmd_history_saved_len], al
.no_save:
    inc word [cmd_history_pos]
    call history_load_current

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; --- Recall the next (newer) history entry into cmd_buffer, or restore the
; saved in-progress line once back at the live position. ---
history_recall_next:
    cmp word [cmd_history_pos], 0
    je .done
    dec word [cmd_history_pos]
    call history_load_current
.done:
    ret

; --- Load cmd_buffer from cmd_history_pos (0 = the saved in-progress line,
; N>0 = the Nth most recent history entry), reset cursor/selection, redraw. ---
history_load_current:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    cmp word [cmd_history_pos], 0
    jne .from_history
    mov rsi, cmd_history_saved
    movzx rcx, byte [cmd_history_saved_len]
    jmp .have_source

.from_history:
    movzx rax, word [cmd_history_write]
    movzx rbx, word [cmd_history_pos]
    sub rax, rbx
    add rax, CMD_HISTORY_ENTRIES
    xor rdx, rdx
    mov rcx, CMD_HISTORY_ENTRIES
    div rcx                      ; rdx = history slot index
    mov rax, rdx
    movzx rcx, byte [cmd_history_len + rax]
    mov rdx, CMD_BUFFER_SIZE
    mul rdx                      ; rax = slot index * CMD_BUFFER_SIZE
    lea rsi, [cmd_history + rax]

.have_source:
    mov rdi, cmd_buffer
    push rcx
    rep movsb
    pop rcx
    mov [cmd_len], cl
    mov [cmd_cursor], cl
    mov byte [sel_active], 0
    call redraw_input_line

    pop rdi
    pop rsi
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

    ; A fresh command starts cancellable: clear any stale break state so a
    ; Ctrl+C from a previous command can't abort this one instantly.
    mov byte [break_pending], 0
    mov byte [poll_ctrl_state], 0

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
    ; If the handler bailed out on a Ctrl+C, echo "^C" so the abort is visible.
    cmp byte [break_pending], 0
    je .newline_only
    mov byte [break_pending], 0
    mov rsi, break_msg
    call print_string
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

; --- Poll the 8042 for a Ctrl+C chord while a command is running.
; Command handlers execute inside keyboard_isr with interrupts disabled and
; no EOI sent yet, so the normal IRQ1 path never fires mid-command; any loop
; that can block must call this to stay cancellable. Tracks Ctrl make/break
; locally (the ISR's ctrl_state is not updated here) and sets break_pending
; on Ctrl+C. Drains and discards every other byte, including mouse aux data.
; Preserves all registers. ---
check_break:
    push rax
.drain:
    in al, KBD_CMD_PORT             ; 0x64 status register
    test al, KBD_STATUS_OUTPUT_FULL
    jz .done                        ; output buffer empty - nothing to read
    test al, KBD_STATUS_AUX_DATA
    jnz .discard                    ; mouse byte - read and throw away
    in al, KBD_DATA_PORT
    cmp al, SC_CTRL                 ; 0x1D: Ctrl make (LCtrl, or RCtrl after 0xE0)
    je .ctrl_down
    cmp al, SC_CTRL | KBD_BREAK_BIT ; 0x9D: Ctrl break
    je .ctrl_up
    cmp al, SC_C                    ; 0x2E: 'c' make
    jne .drain
    cmp byte [poll_ctrl_state], 0
    je .drain
    mov byte [break_pending], 1
    jmp .drain
.ctrl_down:
    mov byte [poll_ctrl_state], 1
    jmp .drain
.ctrl_up:
    mov byte [poll_ctrl_state], 0
    jmp .drain
.discard:
    in al, KBD_DATA_PORT
    jmp .drain
.done:
    pop rax
    ret

; --- "echo" handler: rsi -> nul-terminated argument string ---

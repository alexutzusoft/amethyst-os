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

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


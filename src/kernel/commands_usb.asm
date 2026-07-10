; --- PCI config space access (legacy 0xCF8/0xCFC mechanism). ---
; bus/dev/func are passed in r12b/r13b/r14b rather than dh/dl - print_char
; clobbers dl (text_attr) on every character and zeroes all of rdx on a
; newline (cursor-position division), so any loop counter kept in dx does
; not survive a call to print_string/print_char.
; Builds the CONFIG_ADDRESS dword from r12b=bus, r13b=dev, r14b=func, cl=offset.
pci_config_addr:                ; r12b=bus, r13b=dev, r14b=func, cl=offset -> eax
    xor eax, eax
    mov al, r12b
    shl eax, 8
    movzx ebx, r13b
    and ebx, 0x1F
    shl ebx, 3
    or eax, ebx
    movzx ebx, r14b
    and ebx, 0x07
    or eax, ebx
    shl eax, 8
    movzx ebx, cl
    and ebx, 0xFC
    or eax, ebx
    or eax, 0x80000000
    ret

; r12b=bus, r13b=dev, r14b=func, cl=offset(dword-aligned) -> eax = config dword
pci_read32:
    push rbx
    push rdx
    push rcx
    call pci_config_addr
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    pop rcx
    pop rdx
    pop rbx
    ret

; r12b=bus, r13b=dev, r14b=func, cl=offset(dword-aligned), eax=value to write
pci_write32:
    push rax
    push rbx
    push rdx
    push rcx
    push rax                     ; stash value on the stack (pci_config_addr trashes eax/ebx)
    call pci_config_addr
    mov dx, 0xCF8
    out dx, eax
    pop rax
    mov dx, 0xCFC
    out dx, eax
    pop rcx
    pop rdx
    pop rbx
    pop rax
    ret

; --- Run one control transfer (SETUP/IN/STATUS) against device address 0,
; endpoint 0, to fetch the 18-byte device descriptor via the async QH/qTD
; structures at USB_QH_ADDR etc. r15 = EHCI operational register base.
; Returns carry clear + descriptor bytes at USB_DATA_BUFFER on success,
; carry set on timeout/error. Clobbers rax-rdx, rsi, rdi. ---
ehci_get_device_descriptor:
    ; --- setup packet: GET_DESCRIPTOR(Device), wLength=18 ---
    mov rdi, USB_SETUP_PACKET
    mov byte [rdi + 0], 0x80     ; bmRequestType: device-to-host, standard, device
    mov byte [rdi + 1], 0x06     ; bRequest: GET_DESCRIPTOR
    mov word [rdi + 2], 0x0100   ; wValue: type=DEVICE(1), index=0
    mov word [rdi + 4], 0x0000   ; wIndex
    mov word [rdi + 6], 18       ; wLength
    mov qword [rdi + 8], 0

    ; --- qTD_status: OUT, 0 bytes, DATA1, terminate ---
    mov rdi, USB_QTD_STATUS
    mov dword [rdi + 0], 1                 ; NextQtd: T=1
    mov dword [rdi + 4], 1                 ; AltNext: T=1
    mov dword [rdi + 8], (3 << 10) | (1 << 31) | (0 << 8) | (1 << 7)  ; CERR=3,DT=1,PID=OUT,Active
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; --- qTD_in: IN, 18 bytes into USB_DATA_BUFFER, DATA1 ---
    mov rdi, USB_QTD_IN
    mov eax, USB_QTD_STATUS
    mov dword [rdi + 0], eax               ; NextQtd -> qTD_status
    mov dword [rdi + 4], 1                 ; AltNext: T=1
    mov dword [rdi + 8], (3 << 10) | (1 << 31) | (18 << 16) | (1 << 8) | (1 << 7) ; CERR=3,DT=1,len=18,PID=IN,Active
    mov eax, USB_DATA_BUFFER
    mov dword [rdi + 12], eax              ; BufferPtr0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; --- qTD_setup: SETUP, 8 bytes from USB_SETUP_PACKET, DATA0 ---
    mov rdi, USB_QTD_SETUP
    mov eax, USB_QTD_IN
    mov dword [rdi + 0], eax               ; NextQtd -> qTD_in
    mov dword [rdi + 4], 1                 ; AltNext: T=1
    mov dword [rdi + 8], (3 << 10) | (8 << 16) | (2 << 8) | (1 << 7)  ; CERR=3,DT=0,len=8,PID=SETUP,Active
    mov eax, USB_SETUP_PACKET
    mov dword [rdi + 12], eax
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; --- QH: device 0, endpoint 0, high-speed control, head of reclaim list ---
    mov rdi, USB_QH_ADDR
    mov eax, USB_QH_ADDR
    and eax, 0xFFFFFFE0
    or eax, 0x02                           ; Typ=QH, T=0
    mov dword [rdi + 0], eax               ; HorizLink -> self
    mov dword [rdi + 4], 0x40E000          ; EPS=high-speed, DTC=1, H=1, MaxPacket=64
    mov dword [rdi + 8], 0x40000000        ; Mult=1
    mov dword [rdi + 12], 0                ; CurrentQtd
    mov eax, USB_QTD_SETUP
    mov dword [rdi + 16], eax              ; overlay NextQtd -> qTD_setup
    mov dword [rdi + 20], 1                ; overlay AltNext: T=1
    mov dword [rdi + 24], 0                ; overlay Token
    mov dword [rdi + 28], 0
    mov dword [rdi + 32], 0
    mov dword [rdi + 36], 0
    mov dword [rdi + 40], 0
    mov dword [rdi + 44], 0

    ; point ASYNCLISTADDR at our QH and enable the async schedule
    mov eax, USB_QH_ADDR
    mov dword [r15 + 0x18], eax
    mov eax, [r15 + 0x00]                  ; USBCMD
    or eax, 1 << 5                          ; ASE
    mov [r15 + 0x00], eax

    mov rcx, 20000000
.wait_ass:
    mov eax, [r15 + 0x04]                  ; USBSTS
    test eax, 1 << 15                       ; ASS
    jnz .ass_up
    loop .wait_ass
    jmp .timeout
.ass_up:

    mov rcx, 40000000
.wait_xfer:
    mov eax, [USB_QTD_STATUS + 8]          ; Token
    test eax, 1 << 6                        ; Halted -> error
    jnz .xfer_error
    test eax, 1 << 7                        ; Active
    jz .xfer_done
    loop .wait_xfer
    jmp .timeout

.xfer_done:
    call ehci_disable_async
    clc
    ret

.xfer_error:
.timeout:
    call ehci_disable_async
    stc
    ret

; r15 = EHCI operational register base. Clears USBCMD.ASE and waits for
; USBSTS.ASS to drop, so the next probed device starts from a clean async
; schedule instead of racing the previous QH.
ehci_disable_async:
    push rax
    push rcx
    mov eax, [r15 + 0x00]
    and eax, ~(1 << 5)
    mov [r15 + 0x00], eax
    mov rcx, 20000000
.wait:
    mov eax, [r15 + 0x04]
    test eax, 1 << 15
    jz .done
    loop .wait
.done:
    pop rcx
    pop rax
    ret

; --- Reset and probe one EHCI controller for connected high-speed devices.
; r15 = EHCI operational register base (already computed by the caller).
; ebx = N_PORTS. Preserves r9/r12/r13/r14 (outer PCI scan state). ---
ehci_probe_controller:
    push r9
    push r12
    push r13
    push r14
    push rbx
    push rbp

    ; halt, then reset
    mov eax, [r15 + 0x00]
    and eax, ~1
    mov [r15 + 0x00], eax
    mov rcx, 20000000
.wait_halt:
    mov eax, [r15 + 0x04]
    test eax, 1 << 12
    jnz .halted
    loop .wait_halt
    jmp .probe_done
.halted:
    mov eax, [r15 + 0x00]
    or eax, 1 << 1                          ; HCRESET
    mov [r15 + 0x00], eax
    mov rcx, 20000000
.wait_reset:
    mov eax, [r15 + 0x00]
    test eax, 1 << 1
    jz .reset_done
    loop .wait_reset
    jmp .probe_done
.reset_done:

    mov dword [r15 + 0x40], 1              ; CONFIGFLAG: route ports to EHCI
    mov eax, [r15 + 0x00]
    or eax, 1                               ; RS: run
    mov [r15 + 0x00], eax

    xor ebp, ebp                            ; ebp = port index
.port_loop:
    cmp ebp, ebx
    jae .probe_done

    lea rax, [r15 + 0x44]
    mov rdi, rax
    lea rdi, [rdi + rbp*4]                  ; PORTSC(n)

    mov eax, [rdi]
    test eax, 1                             ; CCS: device connected?
    jz .next_port

    ; port reset: set PR, clear PE, preserve nothing but write-1-to-clear bits as 0
    and eax, ~((1 << 1) | (1 << 3))         ; don't clobber CSC/PEC by echoing them back
    and eax, ~(1 << 2)                      ; PE is RO-from-SW except clearing
    or eax, 1 << 8                          ; PR
    mov [rdi], eax
    mov rcx, 5000000
.reset_hold:
    loop .reset_hold

    mov eax, [rdi]
    and eax, ~((1 << 1) | (1 << 3) | (1 << 8))
    mov [rdi], eax
    mov rcx, 20000000
.wait_pr_clear:
    mov eax, [rdi]
    test eax, 1 << 8
    jz .pr_cleared
    loop .wait_pr_clear
    jmp .next_port
.pr_cleared:

    mov eax, [rdi]
    test eax, 1 << 2                        ; PE: enabled as high-speed?
    jz .next_port                           ; not high-speed - left to companion controller

    call ehci_get_device_descriptor
    jc .next_port

    mov rsi, usb_dev_found_msg
    call print_string
    movzx rax, byte [USB_DATA_BUFFER + 4]
    call print_hex8
    mov rsi, usb_vendor_msg
    call print_string
    movzx rax, word [USB_DATA_BUFFER + 8]
    call print_hex_word
    mov rsi, usb_device_msg
    call print_string
    movzx rax, word [USB_DATA_BUFFER + 10]
    call print_hex_word
    mov al, ASCII_CR
    call print_char

.next_port:
    inc ebp
    jmp .port_loop

.probe_done:
    pop rbp
    pop rbx
    pop r14
    pop r13
    pop r12
    pop r9
    ret

; --- Poll the xHCI event ring for the next event TRB (r13 = runtime register
; base, interrupter 0). Returns rsi -> 16-byte TRB and CF=0 on success, or
; CF=1 on timeout. Advances xhci_evt_index/xhci_evt_cycle and updates ERDP. ---
; dl = expected TRB type (32=Transfer Event, 33=Command Completion Event).
; Skips (and retires) any non-matching events - e.g. stray Port Status
; Change Events - instead of returning them to the caller.
xhci_wait_event:
    push rcx
    push rax
    push rbx
    movzx ebx, dl
    mov ecx, 20000000
.spin:
    mov eax, [xhci_evt_index]
    mov esi, XHCI_EVENT_RING
    mov edx, eax
    shl edx, 4
    add esi, edx
    mov eax, [rsi + 12]
    and eax, 1
    movzx edx, byte [xhci_evt_cycle]
    cmp eax, edx
    jne .retry
    mov eax, [xhci_evt_index]
    inc eax
    cmp eax, 16
    jb .no_wrap
    xor eax, eax
    xor byte [xhci_evt_cycle], 1
.no_wrap:
    mov [xhci_evt_index], eax
    mov edx, eax
    shl edx, 4
    add edx, XHCI_EVENT_RING
    mov [r13 + 0x38], edx
    mov dword [r13 + 0x3C], 0
    mov eax, [rsi + 12]
    shr eax, 10
    and eax, 0x3F
    cmp eax, ebx
    jne .spin
    pop rbx
    pop rax
    pop rcx
    clc
    ret
.retry:
    loop .spin
    pop rbx
    pop rax
    pop rcx
    stc
    ret

; --- Reset and probe one xHCI controller for connected devices, fetching
; each device descriptor via a real Enable Slot / Address Device / control
; transfer sequence (reusing one slot serially across ports). rbp = xHCI
; capability register base (BAR0, already verified identity-mapped and
; <4GB). Preserves r9/r12/r13/r14 (outer PCI scan state). Bails out (no
; devices reported) on 64-byte contexts (CSZ=1) or >64 scratchpad buffers,
; neither of which our static scratch layout supports. ---
xhci_probe_controller:
    push r9
    push r12
    push r13
    push r14

    movzx eax, byte [rbp]
    mov r15, rbp
    add r15, rax                     ; r15 = operational register base

    mov eax, [rbp + 0x10]             ; HCCPARAMS1
    test eax, 1 << 2                   ; CSZ: 64-byte contexts unsupported
    jz .csz_ok
    mov rsi, xhci_dbg_csz_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    jmp .xhci_done
.csz_ok:

    mov eax, [rbp + 4]                ; HCSPARAMS1
    mov r14d, eax
    shr r14d, 24
    and r14d, 0xFF                    ; r14 = MaxPorts

    mov eax, [rbp + 0x14]             ; DBOFF
    and eax, 0xFFFFFFFC
    mov r12, rbp
    add r12, rax                      ; r12 = doorbell array base

    mov eax, [rbp + 0x18]             ; RTSOFF
    and eax, 0xFFFFFFE0
    mov r13, rbp
    add r13, rax                      ; r13 = runtime register base

    ; --- halt, then reset ---
    mov eax, [r15 + 0]
    test eax, 1
    jz .stopped
    and eax, ~1
    mov [r15 + 0], eax
    mov ecx, 20000000
.wait_hch:
    mov eax, [r15 + 4]
    test eax, 1
    jnz .stopped
    loop .wait_hch
    jmp .xhci_reset_fail
.stopped:
    mov eax, [r15 + 0]
    or eax, 1 << 1                     ; HCRST
    mov [r15 + 0], eax
    mov ecx, 20000000
.wait_rst:
    mov eax, [r15 + 0]
    test eax, 1 << 1
    jz .rst_done
    loop .wait_rst
    jmp .xhci_reset_fail
.rst_done:
    mov ecx, 20000000
.wait_cnr:
    mov eax, [r15 + 4]
    test eax, 1 << 11
    jz .cnr_done
    loop .wait_cnr
    jmp .xhci_reset_fail
.cnr_done:

    ; --- scratchpad buffers (many virtual xHCI controllers need none) ---
    mov eax, [rbp + 8]                ; HCSPARAMS2
    mov ebx, eax
    shr ebx, 27
    and ebx, 0x1F
    mov ecx, eax
    shr ecx, 21
    and ecx, 0x1F
    shl ebx, 5
    or ebx, ecx                       ; ebx = MaxScratchpadBufs
    cmp ebx, 64
    ja .xhci_scratch_fail
    test ebx, ebx
    jz .no_scratch

    xor edx, edx
.scratch_fill:
    cmp edx, ebx
    jae .scratch_fill_done
    mov eax, XHCI_SCRATCH_PAGES
    mov ecx, edx
    shl ecx, 12
    add eax, ecx
    mov ecx, edx
    shl ecx, 3
    mov edi, XHCI_SCRATCH_ARRAY
    add edi, ecx
    mov [edi], eax
    mov dword [edi + 4], 0
    inc edx
    jmp .scratch_fill
.scratch_fill_done:
    mov dword [XHCI_DCBAA], XHCI_SCRATCH_ARRAY
    mov dword [XHCI_DCBAA + 4], 0
    jmp .dcbaa_rest
.no_scratch:
    mov dword [XHCI_DCBAA], 0
    mov dword [XHCI_DCBAA + 4], 0
.dcbaa_rest:
    mov edi, XHCI_DCBAA + 8
    mov ecx, 128
    xor eax, eax
    rep stosd

    mov eax, XHCI_DCBAA
    mov [r15 + 0x30], eax
    mov dword [r15 + 0x34], 0

    ; --- command ring ---
    mov edi, XHCI_CMD_RING
    mov ecx, 64 * 4
    xor eax, eax
    rep stosd
    mov dword [xhci_cmd_index], 0
    mov eax, XHCI_CMD_RING
    or eax, 1                          ; RCS
    mov [r15 + 0x18], eax
    mov dword [r15 + 0x1C], 0

    ; --- event ring (interrupter 0), polled rather than IRQ-driven ---
    mov edi, XHCI_EVENT_RING
    mov ecx, 16 * 4
    xor eax, eax
    rep stosd
    mov dword [xhci_evt_index], 0
    mov byte [xhci_evt_cycle], 1

    mov edi, XHCI_ERST
    mov eax, XHCI_EVENT_RING
    mov [edi], eax
    mov dword [edi + 4], 0
    mov dword [edi + 8], 16
    mov dword [edi + 12], 0

    mov dword [r13 + 0x28], 1          ; ERSTSZ
    mov eax, XHCI_EVENT_RING
    mov [r13 + 0x38], eax              ; ERDP
    mov dword [r13 + 0x3C], 0
    mov eax, XHCI_ERST
    mov [r13 + 0x30], eax              ; ERSTBA
    mov dword [r13 + 0x34], 0

    mov eax, [rbp + 4]                 ; HCSPARAMS1
    and eax, 0xFF
    mov [r15 + 0x38], eax              ; CONFIG.MaxSlotsEn

    mov eax, [r15 + 0]
    or eax, 1                          ; RS
    mov [r15 + 0], eax
    mov ecx, 20000000
.wait_run:
    mov eax, [r15 + 4]
    test eax, 1
    jz .run_ok
    loop .wait_run
    jmp .xhci_reset_fail
.run_ok:

    xor ebp, ebp                       ; ebp = port index (cap_base no longer needed)
.port_loop:
    cmp ebp, r14d
    jae .xhci_done

    lea rdi, [r15 + 0x400]
    mov eax, ebp
    shl eax, 4
    add rdi, rax                       ; rdi -> PORTSC(port)

    mov eax, [rdi]
    test eax, 1                        ; CCS
    jz .port_next

    mov edx, eax
    shr edx, 10
    and edx, 0xF                       ; edx = speed

    test eax, 1 << 1                    ; already enabled (typical for SuperSpeed)?
    jnz .port_ready

    mov ebx, eax
    and ebx, 0xFF01FFFD                 ; clear PED + RW1C change bits
    or ebx, 1 << 4                       ; PR
    mov [rdi], ebx
    mov ecx, 20000000
.wait_prc:
    mov eax, [rdi]
    test eax, 1 << 21                    ; PRC
    jnz .prc_set
    loop .wait_prc
    jmp .port_next
.prc_set:
    mov ebx, eax
    and ebx, 0xFF01FFFD
    mov [rdi], ebx
    mov eax, [rdi]
    test eax, 1 << 1                     ; PED
    jz .port_next
    mov edx, eax
    shr edx, 10
    and edx, 0xF
.port_ready:
    mov [xhci_speed], edx
    cmp edx, 3
    je .mps64
    cmp edx, 4
    jae .mps512
    mov dword [xhci_mps], 8
    jmp .mps_done
.mps64:
    mov dword [xhci_mps], 64
    jmp .mps_done
.mps512:
    mov dword [xhci_mps], 512
.mps_done:

    ; --- Enable Slot ---
    mov eax, [xhci_cmd_index]
    cmp eax, 62
    jae .port_next
    mov edi, eax
    shl edi, 4
    add edi, XHCI_CMD_RING
    mov dword [edi + 0], 0
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], (9 << 10) | 1   ; ENABLE_SLOT, Cycle=1
    inc dword [xhci_cmd_index]
    mov dword [r12], 0

    mov dl, 33                          ; Command Completion Event
    call xhci_wait_event
    jnc .es_event_ok
    mov rsi, xhci_dbg_timeout_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    jmp .port_next
.es_event_ok:
    mov r11, rsi                        ; save TRB pointer
    mov eax, [r11 + 8]
    shr eax, 24
    cmp eax, 1                          ; Success
    jne .port_next
    mov eax, [r11 + 12]
    shr eax, 24
    mov r10d, eax                       ; r10 = slot id

    ; --- build input context: slot + EP0 ---
    mov edi, XHCI_INPUT_CTX
    mov ecx, 24
    xor eax, eax
    rep stosd
    mov edi, XHCI_OUTPUT_CTX
    mov ecx, 16
    xor eax, eax
    rep stosd

    mov dword [XHCI_INPUT_CTX + 4], 0x3    ; A0 | A1

    mov eax, [xhci_speed]
    shl eax, 20
    or eax, 1 << 27                          ; context entries = 1
    mov [XHCI_INPUT_CTX + 0x20], eax
    mov eax, ebp
    inc eax
    shl eax, 16                              ; root hub port number
    mov [XHCI_INPUT_CTX + 0x24], eax
    mov dword [XHCI_INPUT_CTX + 0x28], 0
    mov dword [XHCI_INPUT_CTX + 0x2C], 0

    mov eax, 4 << 3                          ; EP Type = Control
    or eax, 3 << 1                            ; CErr = 3
    mov ecx, [xhci_mps]
    shl ecx, 16
    or eax, ecx
    mov [XHCI_INPUT_CTX + 0x44], eax
    mov eax, XHCI_XFER_RING
    and eax, 0xFFFFFFF0
    or eax, 1                                 ; DCS
    mov [XHCI_INPUT_CTX + 0x48], eax
    mov dword [XHCI_INPUT_CTX + 0x4C], 0
    mov dword [XHCI_INPUT_CTX + 0x50], 8      ; average TRB length
    mov byte [xhci_xfer_cycle], 1
    mov dword [XHCI_INPUT_CTX + 0x54], 0
    mov dword [XHCI_INPUT_CTX + 0x58], 0
    mov dword [XHCI_INPUT_CTX + 0x5C], 0

    mov eax, r10d
    shl eax, 3
    mov edi, XHCI_DCBAA
    add edi, eax
    mov eax, XHCI_OUTPUT_CTX
    mov [edi], eax
    mov dword [edi + 4], 0

    ; --- Address Device ---
    mov eax, [xhci_cmd_index]
    cmp eax, 62
    jae .disable_slot
    mov edi, eax
    shl edi, 4
    add edi, XHCI_CMD_RING
    mov eax, XHCI_INPUT_CTX
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov eax, r10d
    shl eax, 24
    or eax, (11 << 10) | 1              ; ADDRESS_DEVICE, Cycle=1
    mov [edi + 12], eax
    inc dword [xhci_cmd_index]
    mov dword [r12], 0

    mov dl, 33                           ; Command Completion Event
    call xhci_wait_event
    jnc .ad_event_ok
    mov rsi, xhci_dbg_timeout_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    jmp .disable_slot
.ad_event_ok:
    mov r11, rsi
    mov eax, [r11 + 8]
    shr eax, 24
    cmp eax, 1
    jne .disable_slot

    ; --- GET_DESCRIPTOR(Device) control transfer ---
    movzx r9d, byte [xhci_xfer_cycle]
    mov edi, XHCI_XFER_RING
    mov byte [edi + 0], 0x80
    mov byte [edi + 1], 0x06
    mov word [edi + 2], 0x0100
    mov word [edi + 4], 0x0000
    mov word [edi + 6], 18
    mov dword [edi + 8], 8
    mov dword [edi + 12], (2 << 10) | (3 << 16) | (1 << 6)       ; SETUP_STAGE, TRT=IN, IDT
    or dword [edi + 12], r9d

    add edi, 16
    mov eax, XHCI_DATA_BUFFER
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    mov dword [edi + 8], 18
    mov dword [edi + 12], (3 << 10) | (1 << 16)                  ; DATA_STAGE, DIR=IN
    or dword [edi + 12], r9d

    add edi, 16
    mov dword [edi + 0], 0
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], (4 << 10) | (1 << 5)                   ; STATUS_STAGE, IOC, DIR=OUT
    or dword [edi + 12], r9d

    add edi, 16
    mov eax, XHCI_XFER_RING
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    mov dword [edi + 12], (6 << 10) | (1 << 1)                   ; LINK, TC=1
    or dword [edi + 12], r9d
    xor byte [xhci_xfer_cycle], 1

    mov eax, r10d
    shl eax, 2
    mov rdi, r12
    add edi, eax
    mov dword [edi], 1                  ; ring EP0 doorbell (DCI 1)

    mov dl, 32                           ; Transfer Event
    call xhci_wait_event
    jnc .tf_event_ok
    mov rsi, xhci_dbg_timeout_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    jmp .disable_slot
.tf_event_ok:
    mov r11, rsi
    mov eax, [r11 + 8]
    shr eax, 24
    cmp eax, 1
    jne .disable_slot

    mov rsi, usb_dev_found_msg
    call print_string
    movzx rax, byte [XHCI_DATA_BUFFER + 4]
    call print_hex8
    mov rsi, usb_vendor_msg
    call print_string
    movzx rax, word [XHCI_DATA_BUFFER + 8]
    call print_hex_word
    mov rsi, usb_device_msg
    call print_string
    movzx rax, word [XHCI_DATA_BUFFER + 10]
    call print_hex_word
    mov al, ASCII_CR
    call print_char

    ; --- GET_DESCRIPTOR(String, iProduct), langid 0x0409 (English/US) ---
    movzx eax, byte [XHCI_DATA_BUFFER + 15]   ; iProduct index
    test eax, eax
    jz .disable_slot
    mov ah, al
    mov al, 0

    movzx r9d, byte [xhci_xfer_cycle]
    mov edi, XHCI_XFER_RING
    mov byte [edi + 0], 0x80
    mov byte [edi + 1], 0x06
    mov al, ah
    mov ah, 3
    mov [edi + 2], ax
    mov word [edi + 4], 0x0409
    mov word [edi + 6], 255
    mov dword [edi + 8], 8
    mov dword [edi + 12], (2 << 10) | (3 << 16) | (1 << 6)       ; SETUP_STAGE, TRT=IN, IDT
    or dword [edi + 12], r9d

    add edi, 16
    mov eax, XHCI_DATA_BUFFER
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    mov dword [edi + 8], 255
    mov dword [edi + 12], (3 << 10) | (1 << 16)                  ; DATA_STAGE, DIR=IN
    or dword [edi + 12], r9d

    add edi, 16
    mov dword [edi + 0], 0
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], (4 << 10) | (1 << 5)                   ; STATUS_STAGE, IOC, DIR=OUT
    or dword [edi + 12], r9d

    add edi, 16
    mov eax, XHCI_XFER_RING
    mov [edi + 0], eax
    mov dword [edi + 4], 0
    mov dword [edi + 12], (6 << 10) | (1 << 1)                   ; LINK, TC=1
    or dword [edi + 12], r9d
    xor byte [xhci_xfer_cycle], 1

    mov eax, r10d
    shl eax, 2
    mov rdi, r12
    add edi, eax
    mov dword [edi], 1                  ; ring EP0 doorbell (DCI 1)

    mov dl, 32                           ; Transfer Event
    call xhci_wait_event
    jnc .name_event_ok
    mov rsi, xhci_dbg_timeout_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    jmp .disable_slot
.name_event_ok:
    mov r11, rsi                         ; save TRB pointer
    mov eax, [r11 + 8]
    shr eax, 24
    cmp eax, 1
    jne .disable_slot

    movzx ebx, byte [XHCI_DATA_BUFFER]   ; bLength
    cmp ebx, 2
    jbe .disable_slot
    sub ebx, 2
    shr ebx, 1                           ; rbx = char count
    mov r9, XHCI_DATA_BUFFER + 2

    mov rsi, usb_name_msg
    call print_string
.name_loop:
    mov al, [r9]
    call print_char
    add r9, 2
    dec ebx
    jnz .name_loop
    mov al, ASCII_CR
    call print_char

.disable_slot:
    mov eax, [xhci_cmd_index]
    cmp eax, 62
    jae .port_next
    mov edi, eax
    shl edi, 4
    add edi, XHCI_CMD_RING
    mov dword [edi + 0], 0
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov eax, r10d
    shl eax, 24
    or eax, (10 << 10) | 1              ; DISABLE_SLOT, Cycle=1
    mov [edi + 12], eax
    inc dword [xhci_cmd_index]
    mov dword [r12], 0
    call xhci_wait_event

.port_next:
    inc ebp
    jmp .port_loop

.xhci_reset_fail:
    mov rsi, xhci_dbg_reset_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    jmp .xhci_done
.xhci_scratch_fail:
    mov rsi, xhci_dbg_scratch_msg
    call print_string
    mov al, ASCII_CR
    call print_char
.xhci_done:
    pop r14
    pop r13
    pop r12
    pop r9
    ret

; --- "usb" handler: brute-force scan all 256 buses x 32 devices x 8 funcs
; for PCI class 0x0C subclass 0x03 (Serial Bus / USB controller), printing
; bus:dev.func, prog-if (controller type), vendor:device IDs. ---
cmd_usb:
    push r12
    push r13
    push r14

    mov rsi, usb_header_msg
    call print_string
    mov al, ASCII_CR
    call print_char

    xor r9, r9                   ; r9 = found count
    xor r12, r12                 ; r12b = bus
.bus_loop:
    xor r13, r13                 ; r13b = dev
.dev_loop:
    xor r14, r14                 ; r14b = func
.func_loop:
    mov cl, 0x00
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .next_func
    mov r10d, eax                ; r10d = vendor:device dword

    mov cl, 0x08
    call pci_read32
    mov r11d, eax                ; r11d = rev/prog-if/subclass/class

    mov eax, r11d
    shr eax, 24
    cmp al, 0x0C                 ; class = Serial Bus Controller
    jne .next_func
    mov eax, r11d
    shr eax, 16
    and al, 0xFF
    cmp al, 0x03                 ; subclass = USB
    jne .next_func

    inc r9
    mov rsi, usb_bus_msg
    call print_string
    movzx rax, r12b
    call print_dec64
    mov rsi, usb_dev_msg
    call print_string
    movzx rax, r13b
    call print_dec64
    mov rsi, usb_func_msg
    call print_string
    movzx rax, r14b
    call print_dec64

    mov rsi, usb_vendor_msg
    call print_string
    movzx rax, r10w
    call print_hex_word
    mov rsi, usb_device_msg
    call print_string
    mov eax, r10d
    shr eax, 16
    call print_hex_word

    mov rsi, usb_type_msg
    call print_string
    mov eax, r11d
    shr eax, 8
    and al, 0xFF                 ; prog-if
    cmp al, 0x00
    je .type_uhci
    cmp al, 0x10
    je .type_ohci
    cmp al, 0x20
    je .type_ehci
    cmp al, 0x30
    je .type_xhci
    mov rsi, usb_type_unknown_msg
    call print_string
    jmp .type_done
.type_uhci:
    mov rsi, usb_type_uhci_msg
    call print_string
    jmp .type_done
.type_ohci:
    mov rsi, usb_type_ohci_msg
    call print_string
    jmp .type_done
.type_ehci:
    mov rsi, usb_type_ehci_msg
    call print_string
    mov al, ASCII_CR
    call print_char

    ; BAR0 -> MMIO base, only trust it if it lands in an identity-mapped
    ; window (low 1GB or the 3-4GB PCI hole - see MMIO_HIGH_BASE).
    mov cl, 0x10
    call pci_read32
    and eax, 0xFFFFFFF0
    cmp eax, IDENTITY_MAP_LIMIT
    jb .ehci_mmio_ok
    cmp eax, MMIO_HIGH_BASE
    jb .type_done
    cmp eax, MMIO_HIGH_LIMIT - 1
    ja .type_done
.ehci_mmio_ok:
    mov r15d, eax                ; r15 = capability register base

    ; enable Memory Space + Bus Master in PCI COMMAND
    mov cl, 0x04
    call pci_read32
    or eax, 0x06
    mov cl, 0x04
    call pci_write32

    movzx eax, byte [r15]        ; CAPLENGTH
    mov ebx, [r15 + 0x04]        ; HCSPARAMS
    and ebx, 0x0F                ; N_PORTS
    add r15, rax                 ; r15 = operational register base
    call ehci_probe_controller
    jmp .type_done
.type_xhci:
    mov rsi, usb_type_xhci_msg
    call print_string
    mov al, ASCII_CR
    call print_char

    mov cl, 0x10
    call pci_read32
    mov ebx, eax
    and ebx, 0x6                 ; BAR0 memory type bits
    and eax, 0xFFFFFFF0
    cmp ebx, 0x4                  ; 64-bit BAR
    jne .xhci_bar_ok
    mov cl, 0x14
    call pci_read32
    test eax, eax
    jnz .type_done                ; BAR above 4GB - unsupported, skip
.xhci_bar_ok:
    mov cl, 0x10
    call pci_read32
    and eax, 0xFFFFFFF0
    cmp eax, IDENTITY_MAP_LIMIT
    jb .xhci_mmio_ok
    cmp eax, MMIO_HIGH_BASE
    jb .type_done
    cmp eax, MMIO_HIGH_LIMIT - 1
    ja .type_done
.xhci_mmio_ok:
    mov ebp, eax                  ; rbp = capability register base

    mov cl, 0x04
    call pci_read32
    or eax, 0x06
    mov cl, 0x04
    call pci_write32

    call xhci_probe_controller
    jmp .type_done
.type_done:
    mov al, ASCII_CR
    call print_char

.next_func:
    inc r14b
    cmp r14b, 8
    jb .func_loop
    inc r13b
    cmp r13b, 32
    jb .dev_loop
    inc r12b
    or r12b, r12b
    jnz .bus_loop

    or r9, r9
    jnz .done
    mov rsi, usb_none_msg
    call print_string
    mov al, ASCII_CR
    call print_char
.done:
    pop r14
    pop r13
    pop r12
    ret

; --- Print AX as 4 zero-padded hex digits ---
print_hex_word:
    push rax
    push rbx
    push rcx
    mov rbx, rax
    mov rcx, 4
.loop:
    rol bx, 4
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

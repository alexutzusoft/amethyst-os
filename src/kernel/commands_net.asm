; ==============================================================================
; AmethystOS e1000 & DHCP Driver and shell integration
; ==============================================================================

net_init:
    push r12
    push r13
    push r14
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov byte [net_have_nic], 0
    mov byte [net_link_up], 0
    mov byte [net_dhcp_state], DHCP_NONE
    mov qword [net_mmio_base], 0

    ; Scan PCI bus for Intel e1000
    xor r12d, r12d                  ; r12b = bus
.bus_loop:
    xor r13d, r13d                  ; r13b = dev
.dev_loop:
    xor r14d, r14d                  ; r14b = func
.func_loop:
    mov cl, 0x00
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .next_func
    
    ; check Vendor ID = 0x8086
    cmp ax, 0x8086
    jne .next_func

    ; check Device ID
    shr eax, 16
    ; classic e1000 family:
    ; 0x100E (82540EM, QEMU default)
    ; 0x100F (82545EM)
    ; 0x1004 (82540)
    ; 0x1019 (82541)
    ; 0x101E (82547)
    cmp ax, 0x100E
    je .found_nic
    cmp ax, 0x100F
    je .found_nic
    cmp ax, 0x1004
    je .found_nic
    cmp ax, 0x1019
    je .found_nic
    cmp ax, 0x101E
    je .found_nic
    jmp .next_func

.found_nic:
    ; Read BAR0 at 0x10
    mov cl, 0x10
    call pci_read32
    ; check type (bit 0 = 0 for memory mapping)
    test al, 0x01
    jnz .next_func
    
    and eax, 0xFFFFFFF0
    cmp eax, IDENTITY_MAP_LIMIT
    jb .mmio_ok
    cmp eax, MMIO_HIGH_BASE
    jb .next_func
    cmp eax, MMIO_HIGH_LIMIT - 1
    ja .next_func
.mmio_ok:
    ; Save MMIO base
    mov [net_mmio_base], rax
    
    ; Save PCI address
    mov [net_pci_bus], r12b
    mov [net_pci_dev], r13b
    mov [net_pci_func], r14b

    ; Print debug message
    mov rsi, net_init_msg
    call print_string


    ; Enable Memory Space + Bus Master
    mov cl, 0x04
    call pci_read32
    or eax, 0x06
    mov cl, 0x04
    call pci_write32

    mov byte [net_have_nic], 1

    ; Bring up e1000
    call e1000_init
    
    ; If link is up, run DHCP
    mov al, [net_link_up]
    or al, al
    jz .scan_done
    call dhcp_run

.scan_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop r14
    pop r13
    pop r12
    ret

.next_func:
    inc r14b
    cmp r14b, 8
    jb .func_loop
.next_dev:
    inc r13b
    cmp r13b, 32
    jb .dev_loop
.next_bus:
    inc r12b
    or r12b, r12b
    jnz .bus_loop
    jmp .scan_done


; --- e1000 Bring-up ---
e1000_init:
    push rdi
    push rax
    push rbx
    push rcx
    push rdx
    push rsi

    mov rdi, [net_mmio_base]

    ; 1. Reset NIC skipped to prevent hardware/emulation reset hangs on VMware
    ; mov eax, [rdi + E1000_CTRL]
    ; or eax, E1000_CTRL_RST
    ; mov [rdi + E1000_CTRL], eax

    ; Poll until RST self-clears (with timeout)
    ; mov rcx, 20000000
;.reset_poll:
    ; mov eax, [rdi + E1000_CTRL]
    ; test eax, E1000_CTRL_RST
    ; jz .reset_ok
    ; loop .reset_poll
    ; Reset failed/timed out, but let's try to proceed anyway.
.reset_ok:
    ; Small delay to let the chip stabilize
    mov rcx, 50000
.stabilize_loop:
    pause
    loop .stabilize_loop

    ; 2. Mask all interrupts: E1000_IMC = 0xFFFFFFFF
    mov dword [rdi + E1000_IMC], 0xFFFFFFFF

    ; 3. Zero MTA (128 entries of 4 bytes)
    mov ecx, 128
    mov edx, E1000_MTA
.zero_mta:
    mov dword [rdi + rdx], 0
    add edx, 4
    loop .zero_mta

    ; 4. Read MAC from E1000_RAL0/E1000_RAH0
    mov eax, [rdi + E1000_RAL0]
    mov edx, [rdi + E1000_RAH0]
    mov [net_mac_addr], eax
    mov [net_mac_addr + 4], dx   ; writes high 2 bytes of MAC

    ; Verify MAC address is not all zeros
    mov eax, [net_mac_addr]
    movzx edx, word [net_mac_addr + 4]
    or eax, edx
    jnz .mac_valid
    
    ; Graceful fallback: NIC invalid/no MAC
    mov byte [net_have_nic], 0
    jmp .ret

.mac_valid:
    ; 5. Build RX descriptor ring at NET_RX_RING
    ; Zero RX ring first (16 descriptors * 16 bytes = 256 bytes)
    mov rsi, NET_RX_RING
    mov ecx, 256 / 8
.zero_rx_ring:
    mov qword [rsi], 0
    add rsi, 8
    loop .zero_rx_ring

    ; Build RX descriptors pointing to NET_RX_BUFFERS
    mov rsi, NET_RX_RING
    mov rax, NET_RX_BUFFERS
    mov ecx, 16
.build_rx:
    mov [rsi], rax
    ; status at rsi+12 is 0
    add rsi, 16
    add rax, 2048
    loop .build_rx

    ; Program RX registers
    mov dword [rdi + E1000_RDBAL], NET_RX_RING
    mov dword [rdi + E1000_RDBAH], 0
    mov dword [rdi + E1000_RDLEN], 256
    mov dword [rdi + E1000_RDH], 0
    mov dword [rdi + E1000_RDT], 15
    mov dword [net_rx_tail], 15

    ; Enable RX: EN | BAM | SECRC (BSIZE=0 = 2048B)
    mov dword [rdi + E1000_RCTL], E1000_RCTL_EN | E1000_RCTL_BAM | E1000_RCTL_SECRC

    ; 6. Build TX descriptor ring at NET_TX_RING
    ; Zero TX ring (256 bytes)
    mov rsi, NET_TX_RING
    mov ecx, 256 / 8
.zero_tx_ring:
    mov qword [rsi], 0
    add rsi, 8
    loop .zero_tx_ring

    ; Program TX registers
    mov dword [rdi + E1000_TDBAL], NET_TX_RING
    mov dword [rdi + E1000_TDBAH], 0
    mov dword [rdi + E1000_TDLEN], 256
    mov dword [rdi + E1000_TDH], 0
    mov dword [rdi + E1000_TDT], 0
    mov dword [net_tx_tail], 0

    ; Program TIPG (timing constant 0x0060200A)
    mov dword [rdi + E1000_TIPG], 0x0060200A

    ; Enable TX: EN | PSP | CT(0x0F) | COLD(0x40)
    mov dword [rdi + E1000_TCTL], E1000_TCTL_EN | E1000_TCTL_PSP | (0x0F << 4) | (0x40 << 12)

    ; 7. Force Link Up: E1000_CTRL |= SLU | ASDE | FD (explicitly clearing RST and LRST)
    mov eax, [rdi + E1000_CTRL]
    and eax, ~E1000_CTRL_RST    ; clear RST (bit 26)
    and eax, ~0x08              ; clear LRST (bit 3)
    or eax, E1000_CTRL_SLU | E1000_CTRL_ASDE | E1000_CTRL_FD
    mov [rdi + E1000_CTRL], eax

    ; 8. Poll for link up (E1000_STATUS.LU)
    mov rcx, 1500000
.link_poll:
    mov eax, [rdi + E1000_STATUS]
    test eax, E1000_STATUS_LU
    jnz .link_up
    loop .link_poll
    ; Link down
    mov byte [net_link_up], 0
    jmp .ret

.link_up:
    mov byte [net_link_up], 1

.ret:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    pop rdi
    ret


; --- Packet Send Primitive ---
net_send_packet:               ; rsi = frame buffer, ecx = length
    push rdi
    push rbx
    push rax
    push rcx
    push rdx

    mov rdi, [net_mmio_base]
    mov edx, [net_tx_tail]

    ; get descriptor address
    mov rbx, rdx
    shl rbx, 4
    add rbx, NET_TX_RING

    ; fill descriptor
    mov [rbx], rsi
    mov [rbx + 8], cx
    mov byte [rbx + 10], 0
    mov byte [rbx + 11], 0x0B  ; CMD = EOP|IFCS|RS
    mov byte [rbx + 12], 0     ; Status
    mov byte [rbx + 13], 0     ; CSS
    mov word [rbx + 14], 0     ; Special

    ; advance TDT
    inc edx
    and edx, 15
    mov [net_tx_tail], edx
    mov [rdi + E1000_TDT], edx

    ; poll status DD bit
    mov rcx, 1000000
.poll:
    mov al, [rbx + 12]
    test al, 0x01
    jnz .done
    loop .poll
.done:
    pop rdx
    pop rcx
    pop rax
    pop rbx
    pop rdi
    ret


; --- Packet Receive Primitive (Non-blocking) ---
net_poll_receive:              ; -> CF=0 (rsi=buffer, ecx=len) or CF=1 (no packet)
    push rbx
    push rax
    push rdx
    push rdi

    mov edx, [net_rx_tail]
    inc edx
    and edx, 15

    ; get descriptor address
    mov rbx, rdx
    shl rbx, 4
    add rbx, NET_RX_RING

    ; check DD bit
    mov al, [rbx + 12]
    test al, 0x01
    jz .no_packet

    ; read packet info
    mov rsi, [rbx]
    movzx ecx, word [rbx + 8]

    ; clear status byte
    mov byte [rbx + 12], 0

    ; advance RDT
    mov [net_rx_tail], edx
    mov rdi, [net_mmio_base]
    mov [rdi + E1000_RDT], edx

    clc
    jmp .ret
.no_packet:
    stc
.ret:
    pop rdi
    pop rdx
    pop rax
    pop rbx
    ret


; --- Header construction builders ---
build_eth_header:              ; rdi = buffer, rsi = dst MAC (6B), rdx = src MAC (6B)
    push rsi
    push rcx
    
    ; copy dst MAC
    mov ecx, 6
    rep movsb
    ; copy src MAC
    mov rsi, rdx
    mov ecx, 6
    rep movsb
    ; write EtherType 0x0800 (network byte order: 0x00, 0x08)
    mov word [rdi], 0x0008
    add rdi, 2

    pop rcx
    pop rsi
    ret


build_ip_header:               ; rdi = buffer, cl = protocol, edx = src IP, ebx = dst IP, r8w = payload length
    push rbp
    push rsi
    push rcx
    push rdx
    push rbx
    push rax

    ; 1. Version & IHL
    mov byte [rdi + 0], 0x45
    ; 2. DSCP/ECN
    mov byte [rdi + 1], 0x00
    ; 3. Total Length
    mov ax, r8w
    add ax, 20
    xchg al, ah                ; big endian swap
    mov [rdi + 2], ax
    ; 4. Identification
    mov word [rdi + 4], 0x0000
    ; 5. Flags & Fragment Offset
    mov word [rdi + 6], 0x0000
    ; 6. TTL
    mov byte [rdi + 8], 64
    ; 7. Protocol
    mov [rdi + 9], cl
    ; 8. Header Checksum (fill with 0 for now)
    mov word [rdi + 10], 0
    ; 9. Source IP
    mov [rdi + 12], edx
    ; 10. Destination IP
    mov [rdi + 16], ebx

    ; 11. Compute Checksum
    xor eax, eax
    mov ecx, 10
    mov rsi, rdi
.chk_loop:
    movzx ebp, word [rsi]
    add eax, ebp
    add rsi, 2
    loop .chk_loop

.fold:
    test eax, 0xFFFF0000
    jz .fold_done
    mov edx, eax
    shr edx, 16
    and eax, 0xFFFF
    add eax, edx
    jmp .fold
.fold_done:
    not ax
    mov [rdi + 10], ax         ; store checksum in network byte order

    add rdi, 20                ; advance rdi past IP header

    pop rax
    pop rbx
    pop rdx
    pop rcx
    pop rsi
    pop rbp
    ret


build_udp_header:              ; rdi = buffer, dx = src port, bx = dst port, cx = payload length
    push rax
    push rcx

    ; 1. Source Port
    mov [rdi + 0], dx
    ; 2. Destination Port
    mov [rdi + 2], bx
    ; 3. Length
    mov ax, cx
    add ax, 8
    xchg al, ah                ; big endian swap
    mov [rdi + 4], ax
    ; 4. Checksum (0 = disabled)
    mov word [rdi + 6], 0

    add rdi, 8                 ; advance rdi past UDP header

    pop rcx
    pop rax
    ret


; --- DHCP Client ---
dhcp_run:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp

    ; derive xid
    rdtsc
    xor eax, dword [timer_ticks]
    mov [dhcp_xid], eax

    ; --- Step 1: Send DHCPDISCOVER ---
    ; Zero DHCP area (300 bytes)
    mov rdi, NET_TX_BUFFER + 42
    xor eax, eax
    mov ecx, 300 / 4
    rep stosd

    ; Construct DHCP Payload
    mov rdi, NET_TX_BUFFER + 42
    mov byte [rdi + 0], 1       ; op
    mov byte [rdi + 1], 1       ; htype
    mov byte [rdi + 2], 6       ; hlen
    mov eax, [dhcp_xid]
    mov [rdi + 4], eax
    mov word [rdi + 10], 0x0080 ; flags = Broadcast

    ; chaddr
    mov eax, [net_mac_addr]
    mov [rdi + 28], eax
    movzx edx, word [net_mac_addr + 4]
    mov [rdi + 32], dx

    ; magic cookie
    mov dword [rdi + 236], 0x63538263

    ; options
    mov byte [rdi + 240], 53    ; Option 53
    mov byte [rdi + 241], 1
    mov byte [rdi + 242], 1     ; DISCOVER
    
    mov byte [rdi + 243], 55    ; Option 55
    mov byte [rdi + 244], 4
    mov byte [rdi + 245], 1
    mov byte [rdi + 246], 3
    mov byte [rdi + 247], 6
    mov byte [rdi + 248], 51
    
    mov byte [rdi + 249], 255   ; Option 255

    ; Wrap with headers
    mov rdi, NET_TX_BUFFER
    mov rsi, broadcast_mac
    mov rdx, net_mac_addr
    call build_eth_header      ; to +14

    mov cl, 17                  ; UDP
    xor edx, edx                ; src IP = 0
    mov ebx, 0xFFFFFFFF         ; dst IP = 255.255.255.255
    mov r8w, 308                ; length = 308
    call build_ip_header       ; to +34

    mov dx, 0x4400              ; src port 68
    mov bx, 0x4300              ; dst port 67
    mov cx, 300                 ; DHCP payload length
    call build_udp_header      ; to +42

    ; Send DISCOVER
    mov rsi, NET_TX_BUFFER
    mov ecx, 342
    call net_send_packet

    ; --- Step 2: Poll for DHCPOFFER ---
    mov rbp, 5000000
.poll_offer:
    dec rbp
    jz .failed
    call net_poll_receive
    jc .poll_offer_delay

    ; Parse
    call parse_dhcp_offer
    jc .poll_offer_delay
    jmp .got_offer

.poll_offer_delay:
    pause
    jmp .poll_offer

.got_offer:
    ; --- Step 3: Send DHCPREQUEST ---
    ; Zero DHCP area (300 bytes)
    mov rdi, NET_TX_BUFFER + 42
    xor eax, eax
    mov ecx, 300 / 4
    rep stosd

    ; Construct DHCP REQUEST payload
    mov rdi, NET_TX_BUFFER + 42
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 1
    mov byte [rdi + 2], 6
    mov eax, [dhcp_xid]
    mov [rdi + 4], eax
    mov word [rdi + 10], 0x0080

    ; chaddr
    mov eax, [net_mac_addr]
    mov [rdi + 28], eax
    movzx edx, word [net_mac_addr + 4]
    mov [rdi + 32], dx

    ; magic cookie
    mov dword [rdi + 236], 0x63538263

    ; options
    mov byte [rdi + 240], 53
    mov byte [rdi + 241], 1
    mov byte [rdi + 242], 3     ; REQUEST
    
    mov byte [rdi + 243], 50    ; Requested IP
    mov byte [rdi + 244], 4
    mov eax, [dhcp_offered_ip]
    mov [rdi + 245], eax
    
    mov byte [rdi + 249], 54    ; Server ID
    mov byte [rdi + 250], 4
    mov eax, [dhcp_server_id]
    mov [rdi + 251], eax
    
    mov byte [rdi + 255], 255

    ; Wrap with headers
    mov rdi, NET_TX_BUFFER
    mov rsi, broadcast_mac
    mov rdx, net_mac_addr
    call build_eth_header

    mov cl, 17
    xor edx, edx
    mov ebx, 0xFFFFFFFF
    mov r8w, 308
    call build_ip_header

    mov dx, 0x4400
    mov bx, 0x4300
    mov cx, 300
    call build_udp_header

    ; Send REQUEST
    mov rsi, NET_TX_BUFFER
    mov ecx, 342
    call net_send_packet

    ; --- Step 4: Poll for DHCPACK ---
    mov rbp, 5000000
.poll_ack:
    dec rbp
    jz .failed
    call net_poll_receive
    jc .poll_ack_delay

    ; Parse
    call parse_dhcp_ack
    jc .poll_ack_delay
    jmp .got_ack

.poll_ack_delay:
    pause
    jmp .poll_ack

.got_ack:
    mov byte [net_dhcp_state], DHCP_BOUND
    jmp .ret

.failed:
    mov byte [net_dhcp_state], DHCP_FAILED

.ret:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret


; --- DHCP Parsing Helpers ---
parse_dhcp_offer:
    push rax
    mov al, 2                  ; DHCPOFFER
    call parse_dhcp_packet
    jc .ret
    
    mov eax, [dhcp_parsed_yiaddr]
    mov [dhcp_offered_ip], eax
    mov eax, [dhcp_parsed_server_id]
    mov [dhcp_server_id], eax
    clc
.ret:
    pop rax
    ret

parse_dhcp_ack:
    push rax
    mov al, 5                  ; DHCPACK
    call parse_dhcp_packet
    jc .ret
    
    mov eax, [dhcp_parsed_yiaddr]
    mov [net_ip], eax
    mov eax, [dhcp_parsed_mask]
    mov [net_mask], eax
    mov eax, [dhcp_parsed_gateway]
    mov [net_gateway], eax
    mov eax, [dhcp_parsed_dns]
    mov [net_dns], eax
    mov eax, [dhcp_parsed_lease]
    mov [net_lease], eax
    clc
.ret:
    pop rax
    ret

parse_dhcp_packet:             ; rsi = packet, ecx = len, al = expected msg type -> CF=0 (success) or CF=1
    push rbp
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    cmp ecx, 342
    jb .fail

    cmp byte [rsi + 12], 0x08
    jne .fail
    cmp byte [rsi + 13], 0x00
    jne .fail

    cmp byte [rsi + 23], 0x11
    jne .fail

    cmp byte [rsi + 36], 0x00
    jne .fail
    cmp byte [rsi + 37], 0x44
    jne .fail

    cmp byte [rsi + 42], 2      ; BOOTREPLY
    jne .fail

    mov edx, [dhcp_xid]
    cmp [rsi + 46], edx
    jne .fail

    cmp dword [rsi + 278], 0x63538263
    jne .fail

    mov dl, al
    
    movzx r9d, byte [rsi + 38]
    shl r9d, 8
    mov r9b, [rsi + 39]
    
    lea r8, [rsi + 34 + r9]
    lea rdi, [rsi + 282]
    
    xor eax, eax
    mov byte [dhcp_msg_type_found], 0

.opt_loop:
    cmp rdi, r8
    jae .opt_done
    
    mov al, [rdi]
    cmp al, 255
    je .opt_done
    cmp al, 0
    jne .not_pad
    inc rdi
    jmp .opt_loop

.not_pad:
    lea rbx, [rdi + 2]
    cmp rbx, r8
    ja .fail
    
    movzx ecx, byte [rdi + 1]
    lea rbx, [rdi + 2 + rcx]
    cmp rbx, r8
    ja .fail

    cmp al, 53
    jne .check_opt1
    cmp ecx, 1
    jne .bad_opt
    mov bl, [rdi + 2]
    mov [dhcp_msg_type_found], bl
    jmp .next_opt

.check_opt1:
    cmp al, 1
    jne .check_opt3
    cmp ecx, 4
    jne .bad_opt
    mov ebx, [rdi + 2]
    mov [dhcp_parsed_mask], ebx
    jmp .next_opt

.check_opt3:
    cmp al, 3
    jne .check_opt6
    cmp ecx, 4
    jb .bad_opt
    mov ebx, [rdi + 2]
    mov [dhcp_parsed_gateway], ebx
    jmp .next_opt

.check_opt6:
    cmp al, 6
    jne .check_opt51
    cmp ecx, 4
    jb .bad_opt
    mov ebx, [rdi + 2]
    mov [dhcp_parsed_dns], ebx
    jmp .next_opt

.check_opt51:
    cmp al, 51
    jne .check_opt54
    cmp ecx, 4
    jne .bad_opt
    mov ebx, [rdi + 2]
    ; swap big-endian lease to local format
    xchg bh, bl
    rol ebx, 16
    xchg bh, bl
    mov [dhcp_parsed_lease], ebx
    jmp .next_opt

.check_opt54:
    cmp al, 54
    jne .next_opt
    cmp ecx, 4
    jne .bad_opt
    mov ebx, [rdi + 2]
    mov [dhcp_parsed_server_id], ebx

.next_opt:
    add rdi, 2
    add rdi, rcx
    jmp .opt_loop

.bad_opt:
.fail:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    stc
    ret

.opt_done:
    mov al, [dhcp_msg_type_found]
    cmp al, dl
    jne .fail

    mov eax, [rsi + 58]         ; yiaddr
    mov [dhcp_parsed_yiaddr], eax

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rbp
    clc
    ret


; --- Printing Helpers ---
print_hex32:
    push rax
    push rbx
    mov ebx, eax

    mov eax, ebx
    shr eax, 24
    call print_hex8
    mov eax, ebx
    shr eax, 16
    call print_hex8
    mov eax, ebx
    shr eax, 8
    call print_hex8
    mov eax, ebx
    call print_hex8

    pop rbx
    pop rax
    ret

print_mac_addr:                ; rsi = ptr to 6 bytes MAC
    push rax
    push rcx
    push rsi
    mov ecx, 6
.loop:
    movzx eax, byte [rsi]
    call print_hex8
    inc rsi
    dec ecx
    jz .done
    mov al, ':'
    call print_char
    jmp .loop
.done:
    pop rsi
    pop rcx
    pop rax
    ret


print_ip_addr:                 ; eax = IPv4 address (little endian dword loaded from memory, representing big-endian byte order)
    push rax
    push rbx
    mov ebx, eax

    ; Octet 1
    movzx rax, bl
    call print_dec64
    mov al, '.'
    call print_char

    ; Octet 2
    mov eax, ebx
    shr eax, 8
    movzx rax, al
    call print_dec64
    mov al, '.'
    call print_char

    ; Octet 3
    mov eax, ebx
    shr eax, 16
    movzx rax, al
    call print_dec64
    mov al, '.'
    call print_char

    ; Octet 4
    mov eax, ebx
    shr eax, 24
    movzx rax, al
    call print_dec64

    pop rbx
    pop rax
    ret


; --- Command Handler ---
cmd_net:
    ; print Network:
    mov rsi, net_hdr_str
    call print_string
    mov al, ASCII_CR
    call print_char

    ; check if have nic
    mov al, [net_have_nic]
    or al, al
    jnz .have_nic
    
    mov rsi, net_no_nic_str
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

.have_nic:
    mov rdi, [net_mmio_base]
    mov eax, [rdi + E1000_STATUS]
    mov ebx, eax                ; save STATUS

    test eax, E1000_STATUS_LU
    jz .set_down
    mov byte [net_link_up], 1
    jmp .set_done
.set_down:
    mov byte [net_link_up], 0
.set_done:

    mov rsi, net_nic_prefix
    call print_string
    
    ; print bus:dev.func
    movzx rax, byte [net_pci_bus]
    call print_dec64
    mov al, ':'
    call print_char
    movzx rax, byte [net_pci_dev]
    call print_dec64
    mov al, '.'
    call print_char
    movzx rax, byte [net_pci_func]
    call print_dec64
    mov al, ASCII_CR
    call print_char

    ; Print register diagnostics
    mov rsi, net_status_prefix
    call print_string
    mov eax, ebx
    call print_hex32
    mov al, ASCII_CR
    call print_char

    mov rsi, net_ctrl_prefix
    call print_string
    mov eax, [rdi + E1000_CTRL]
    call print_hex32
    mov al, ASCII_CR
    call print_char

    ; Print MAC
    mov rsi, net_mac_prefix
    call print_string
    mov rsi, net_mac_addr
    call print_mac_addr
    mov al, ASCII_CR
    call print_char

    ; Print Link
    mov rsi, net_link_prefix
    call print_string
    mov al, [net_link_up]
    or al, al
    jz .link_down
    mov rsi, net_up_str
    call print_string
    jmp .link_done
.link_down:
    mov rsi, net_down_str
    call print_string
.link_done:
    mov al, ASCII_CR
    call print_char

    ; Print DHCP status
    mov rsi, net_dhcp_prefix
    call print_string
    mov al, [net_dhcp_state]
    cmp al, DHCP_BOUND
    je .dhcp_bound
    cmp al, DHCP_FAILED
    je .dhcp_failed
    mov rsi, net_none_str
    call print_string
    jmp .dhcp_done
.dhcp_bound:
    mov rsi, net_bound_str
    call print_string
    jmp .dhcp_done
.dhcp_failed:
    mov rsi, net_failed_str
    call print_string
.dhcp_done:
    mov al, ASCII_CR
    call print_char

    ; If not bound, exit
    mov al, [net_dhcp_state]
    cmp al, DHCP_BOUND
    jne .ret

    ; Print IP
    mov rsi, net_ip_prefix
    call print_string
    mov eax, [net_ip]
    call print_ip_addr
    mov al, ASCII_CR
    call print_char

    ; Print Subnet
    mov rsi, net_subnet_prefix
    call print_string
    mov eax, [net_mask]
    call print_ip_addr
    mov al, ASCII_CR
    call print_char

    ; Print Gateway
    mov rsi, net_gateway_prefix
    call print_string
    mov eax, [net_gateway]
    call print_ip_addr
    mov al, ASCII_CR
    call print_char

    ; Print DNS
    mov rsi, net_dns_prefix
    call print_string
    mov eax, [net_dns]
    call print_ip_addr
    mov al, ASCII_CR
    call print_char

    ; Print Lease
    mov rsi, net_lease_prefix
    call print_string
    mov eax, [net_lease]
    call print_dec64
    mov rsi, net_seconds_suffix
    call print_string
    mov al, ASCII_CR
    call print_char

.ret:
    ret


; --- String Constants ---
net_hdr_str db "Network:", 0
net_no_nic_str db "  No e1000 NIC found.", 0
net_nic_prefix db "  NIC: e1000 (Intel 82540EM-class) at ", 0
net_mac_prefix db "  MAC: ", 0
net_link_prefix db "  Link: ", 0
net_up_str db "up", 0
net_down_str db "down", 0
net_dhcp_prefix db "  DHCP: ", 0
net_none_str db "none", 0
net_bound_str db "bound", 0
net_failed_str db "failed", 0
net_ip_prefix db "  IP: ", 0
net_subnet_prefix db "  Subnet: ", 0
net_gateway_prefix db "  Gateway: ", 0
net_dns_prefix db "  DNS: ", 0
net_lease_prefix db "  Lease: ", 0
net_seconds_suffix db "s", 0
net_status_prefix db "  STATUS: 0x", 0
net_ctrl_prefix db "  CTRL: 0x", 0
net_init_msg db "[net] Found e1000, initializing...", ASCII_CR, 0

; --- "ls"/"dir" handlers: read-only FAT12/16/32 root-directory listing of
; the first USB mass-storage device found on an xHCI controller. Bulk-only
; transport (CBW/CSW) with SCSI READ(10), one 512-byte sector at a time.
; Register conventions match commands_usb.asm's xHCI code: r10d = slot id,
; r12 = doorbell array base, r13 = runtime register base, r15 = operational
; register base, ebp = port index. All listing loop state lives in memory
; variables - print_char/print_string clobber rax/rbx/rdx/rdi. ---

; --- One control transfer on EP0 of slot r10d. rax = the 8-byte setup
; packet (bmRequestType..wLength, in USB wire order as a little-endian
; qword). If wLength > 0, the data stage targets XHCI_DATA_BUFFER, with
; direction taken from bmRequestType bit 7. CF set on timeout/failure. ---
fs_ctrl_xfer:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r11
    mov rbx, rax                     ; rbx = setup packet
    mov r8, rbx
    shr r8, 48                       ; r8w = wLength
    movzx r9d, byte [xhci_xfer_cycle]
    mov edi, XHCI_XFER_RING
    mov [rdi], rbx                   ; setup packet = TRB parameter (IDT)
    mov dword [rdi + 8], 8
    xor ecx, ecx                     ; TRT: 0 = no data stage
    test r8w, r8w
    jz .trt_done
    mov ecx, 2                       ; TRT: 2 = OUT data stage
    test bl, 0x80
    jz .trt_done
    mov ecx, 3                       ; TRT: 3 = IN data stage
.trt_done:
    shl ecx, 16
    or ecx, (2 << 10) | (1 << 6)     ; SETUP_STAGE, IDT
    or ecx, r9d
    mov [rdi + 12], ecx
    add edi, 16
    test r8w, r8w
    jz .no_data
    mov dword [rdi + 0], XHCI_DATA_BUFFER
    mov dword [rdi + 4], 0
    movzx ecx, r8w
    mov [rdi + 8], ecx
    mov ecx, (3 << 10)               ; DATA_STAGE
    test bl, 0x80
    jz .data_dir_done
    or ecx, 1 << 16                  ; DIR=IN
.data_dir_done:
    or ecx, r9d
    mov [rdi + 12], ecx
    add edi, 16
.no_data:
    mov dword [rdi + 0], 0
    mov dword [rdi + 4], 0
    mov dword [rdi + 8], 0
    mov ecx, (4 << 10) | (1 << 5) | (1 << 16)   ; STATUS_STAGE, IOC, DIR=IN
    test r8w, r8w
    jz .stat_done
    test bl, 0x80
    jz .stat_done
    and ecx, ~(1 << 16)              ; data stage was IN -> status OUT
.stat_done:
    or ecx, r9d
    mov [rdi + 12], ecx
    add edi, 16
    mov dword [rdi + 0], XHCI_XFER_RING
    mov dword [rdi + 4], 0
    mov dword [rdi + 8], 0
    mov ecx, (6 << 10) | (1 << 1)    ; LINK, TC=1
    or ecx, r9d
    mov [rdi + 12], ecx
    xor byte [xhci_xfer_cycle], 1
    mov eax, r10d
    shl eax, 2
    mov rdi, r12
    add edi, eax
    mov dword [edi], 1               ; ring EP0 doorbell (DCI 1)
    mov dl, 32                       ; Transfer Event
    call xhci_wait_event
    jc .fail
    mov eax, [rsi + 8]
    shr eax, 24
    cmp eax, 1                       ; Success
    je .ok
    cmp eax, 13                      ; Short Packet (fine: wLength was a max)
    je .ok
.fail:
    stc
    jmp .out
.ok:
    clc
.out:
    pop r11
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; --- One bulk transfer on the configured mass-storage endpoints of slot
; r10d: a single Normal TRB + Link TRB rebuilt at the ring start each call,
; toggling the producer cycle (same trick as the EP0 control ring).
; edi = buffer, ecx = byte count. CF set on timeout/failure. ---
fs_bulk_in:
    push r8
    push r9
    movzx r8d, byte [bulk_in_dci]
    movzx r9d, byte [bulk_in_cycle]
    xor byte [bulk_in_cycle], 1
    mov esi, FS_BULK_IN_RING
    jmp fs_bulk_go
fs_bulk_out:
    push r8
    push r9
    movzx r8d, byte [bulk_out_dci]
    movzx r9d, byte [bulk_out_cycle]
    xor byte [bulk_out_cycle], 1
    mov esi, FS_BULK_OUT_RING
fs_bulk_go:
    mov [rsi + 0], edi
    mov dword [rsi + 4], 0
    mov [rsi + 8], ecx
    mov eax, (1 << 10) | (1 << 5)    ; NORMAL, IOC
    or eax, r9d
    mov [rsi + 12], eax
    mov [rsi + 16], esi              ; LINK back to ring start
    mov dword [rsi + 20], 0
    mov dword [rsi + 24], 0
    ; The link TRB takes the INVERTED cycle bit: the controller parks its
    ; dequeue pointer on this link after each transfer, so it must only
    ; become valid once the next call has rewritten the ring. Giving it the
    ; current cycle would leave a lazily-fetching controller (QEMU's xHCI)
    ; parked on a link whose cycle it no longer accepts, hanging the ring.
    mov eax, (6 << 10) | (1 << 1)    ; LINK, TC=1
    or eax, r9d
    xor eax, 1
    mov [rsi + 28], eax
    mov eax, r10d
    shl eax, 2
    mov rdi, r12
    add edi, eax
    mov [edi], r8d                   ; ring doorbell with the endpoint's DCI
    mov dl, 32                       ; Transfer Event
    call xhci_wait_event
    jc .fail
    mov eax, [rsi + 8]
    shr eax, 24
    cmp eax, 1                       ; Success
    je .ok
    cmp eax, 13                      ; Short Packet
    je .ok
.fail:
    pop r9
    pop r8
    stc
    ret
.ok:
    pop r9
    pop r8
    clc
    ret

; --- Run one SCSI command over bulk-only transport. Caller pre-fills the
; CDB at FS_CBW+15.., dataTransferLength at FS_CBW+8, flags at FS_CBW+12
; and CDB length at FS_CBW+14; edi = data-in buffer (dtl > 0 is IN-only
; here - every command ls needs reads from the device). CF on any bulk
; failure, bad CSW signature, or non-zero CSW status. ---
fs_scsi_cmd:
    push rbx
    mov ebx, edi                     ; save data buffer
    mov eax, [bot_tag]
    inc dword [bot_tag]
    mov dword [FS_CBW + 0], 0x43425355   ; 'USBC'
    mov [FS_CBW + 4], eax
    mov byte [FS_CBW + 13], 0        ; LUN 0
    mov edi, FS_CBW
    mov ecx, 31
    call fs_bulk_out
    jc .fail
    mov ecx, [FS_CBW + 8]
    test ecx, ecx
    jz .csw
    mov edi, ebx
    call fs_bulk_in
    jc .fail
.csw:
    mov edi, FS_CSW
    mov ecx, 13
    call fs_bulk_in
    jc .fail
    cmp dword [FS_CSW], 0x53425355   ; 'USBS'
    jne .fail
    cmp byte [FS_CSW + 12], 0        ; bCSWStatus: 0 = passed
    jne .fail
    pop rbx
    clc
    ret
.fail:
    pop rbx
    stc
    ret

; --- SCSI READ(10): one 512-byte sector. eax = absolute LBA, edi = buffer. ---
fs_read_sector:
    push rcx
    mov dword [FS_CBW + 8], 512
    mov byte [FS_CBW + 12], 0x80     ; device-to-host
    mov byte [FS_CBW + 14], 10
    mov byte [FS_CBW + 15], 0x28     ; READ(10)
    mov byte [FS_CBW + 16], 0
    bswap eax
    mov [FS_CBW + 17], eax           ; LBA, big-endian
    mov dword [FS_CBW + 21], 0x00010000  ; group 0, count 0x0001 BE, control 0
    mov dword [FS_CBW + 25], 0
    mov word [FS_CBW + 29], 0
    call fs_scsi_cmd
    pop rcx
    ret

; --- Run one SCSI command with an OUT (host-to-device) data phase. Same CBW
; field conventions as fs_scsi_cmd; edi = data-out buffer. ---
fs_scsi_cmd_out:
    push rbx
    mov ebx, edi
    mov eax, [bot_tag]
    inc dword [bot_tag]
    mov dword [FS_CBW + 0], 0x43425355   ; 'USBC'
    mov [FS_CBW + 4], eax
    mov byte [FS_CBW + 13], 0
    mov edi, FS_CBW
    mov ecx, 31
    call fs_bulk_out
    jc .fail
    mov ecx, [FS_CBW + 8]
    test ecx, ecx
    jz .csw
    mov edi, ebx
    call fs_bulk_out
    jc .fail
.csw:
    mov edi, FS_CSW
    mov ecx, 13
    call fs_bulk_in
    jc .fail
    cmp dword [FS_CSW], 0x53425355
    jne .fail
    cmp byte [FS_CSW + 12], 0
    jne .fail
    pop rbx
    clc
    ret
.fail:
    pop rbx
    stc
    ret

; --- SCSI WRITE(10): one 512-byte sector. eax = absolute LBA, edi = buffer. ---
fs_write_sector:
    push rcx
    mov dword [FS_CBW + 8], 512
    mov byte [FS_CBW + 12], 0        ; host-to-device
    mov byte [FS_CBW + 14], 10
    mov byte [FS_CBW + 15], 0x2A     ; WRITE(10)
    mov byte [FS_CBW + 16], 0
    bswap eax
    mov [FS_CBW + 17], eax           ; LBA, big-endian
    mov dword [FS_CBW + 21], 0x00010000  ; group 0, count 0x0001 BE, control 0
    mov dword [FS_CBW + 25], 0
    mov word [FS_CBW + 29], 0
    call fs_scsi_cmd_out
    pop rcx
    ret

; --- SCSI TEST UNIT READY (no data). CF = not ready. ---
fs_test_ready:
    mov dword [FS_CBW + 8], 0
    mov byte [FS_CBW + 12], 0
    mov byte [FS_CBW + 14], 6
    mov dword [FS_CBW + 15], 0
    mov dword [FS_CBW + 19], 0
    mov dword [FS_CBW + 23], 0
    mov dword [FS_CBW + 27], 0
    xor edi, edi
    jmp fs_scsi_cmd

; --- SCSI REQUEST SENSE (18 bytes in, discarded): clears the unit-attention
; condition many sticks report right after configuration, so the next TEST
; UNIT READY can succeed. ---
fs_req_sense:
    mov dword [FS_CBW + 8], 18
    mov byte [FS_CBW + 12], 0x80
    mov byte [FS_CBW + 14], 6
    mov dword [FS_CBW + 15], 0x00000003
    mov dword [FS_CBW + 19], 0x00000012  ; allocation length 18
    mov dword [FS_CBW + 23], 0
    mov dword [FS_CBW + 27], 0
    mov edi, XHCI_DATA_BUFFER
    jmp fs_scsi_cmd

; --- Parse the configuration descriptor at XHCI_DATA_BUFFER: find a
; mass-storage bulk-only interface (class 08, protocol 50) and its bulk
; IN/OUT endpoints. Stores fs_config_val, bulk_in/out_dci and _mps.
; CF set if this is not a usable mass-storage device. ---
fs_parse_config:
    push rbx
    mov byte [bulk_in_dci], 0
    mov byte [bulk_out_dci], 0
    mov esi, XHCI_DATA_BUFFER
    movzx ecx, word [rsi + 2]        ; wTotalLength
    cmp ecx, 255
    jbe .len_ok
    mov ecx, 255                     ; only fetched this much
.len_ok:
    mov al, [rsi + 5]                ; bConfigurationValue
    mov [fs_config_val], al
    xor ebx, ebx                     ; bl = inside mass-storage interface
    xor edx, edx                     ; edx = walk offset
.walk:
    movzx eax, byte [rsi + rdx]      ; bLength
    test eax, eax
    jz .walk_done
    mov al, [rsi + rdx + 1]          ; bDescriptorType
    cmp al, 4                        ; INTERFACE
    jne .not_iface
    xor ebx, ebx
    cmp byte [rsi + rdx + 5], 0x08   ; bInterfaceClass: mass storage
    jne .next
    cmp byte [rsi + rdx + 7], 0x50   ; bInterfaceProtocol: bulk-only
    jne .next
    mov bl, 1
    jmp .next
.not_iface:
    cmp al, 5                        ; ENDPOINT
    jne .next
    test bl, bl
    jz .next
    mov al, [rsi + rdx + 3]
    and al, 3
    cmp al, 2                        ; bulk?
    jne .next
    movzx r8d, byte [rsi + rdx + 2]  ; bEndpointAddress
    mov r9d, r8d
    and r9d, 0x0F
    shl r9d, 1                       ; DCI = epnum*2 (+1 for IN)
    test r8b, 0x80
    jz .ep_out
    or r9d, 1
    mov [bulk_in_dci], r9b
    mov ax, [rsi + rdx + 4]
    mov [bulk_in_mps], ax
    jmp .next
.ep_out:
    mov [bulk_out_dci], r9b
    mov ax, [rsi + rdx + 4]
    mov [bulk_out_mps], ax
.next:
    movzx eax, byte [rsi + rdx]
    add edx, eax
    cmp edx, ecx
    jb .walk
.walk_done:
    cmp byte [bulk_in_dci], 0
    je .no
    cmp byte [bulk_out_dci], 0
    je .no
    pop rbx
    clc
    ret
.no:
    pop rbx
    stc
    ret

; --- Configure Endpoint command: add the two bulk endpoints to slot r10d's
; device context and initialize their transfer rings. CF on failure. ---
fs_configure_endpoints:
    mov edi, XHCI_INPUT_CTX
    mov ecx, 264                     ; input control + slot + 31 EP contexts
    xor eax, eax
    rep stosd
    movzx ecx, byte [bulk_in_dci]
    mov ebx, 1
    shl ebx, cl
    movzx ecx, byte [bulk_out_dci]
    mov eax, 1
    shl eax, cl
    or ebx, eax
    or ebx, 1                        ; A0: slot context
    mov [XHCI_INPUT_CTX + 4], ebx
    movzx eax, byte [bulk_in_dci]
    movzx ecx, byte [bulk_out_dci]
    cmp eax, ecx
    jae .have_max
    mov eax, ecx
.have_max:
    shl eax, 27                      ; context entries = max DCI
    mov ecx, [xhci_speed]
    shl ecx, 20
    or eax, ecx
    mov [XHCI_INPUT_CTX + 0x20], eax
    mov eax, ebp
    inc eax
    shl eax, 16                      ; root hub port number
    mov [XHCI_INPUT_CTX + 0x24], eax
    ; bulk IN endpoint context
    movzx eax, byte [bulk_in_dci]
    shl eax, 5
    lea edi, [eax + XHCI_INPUT_CTX + 0x20]
    movzx ecx, word [bulk_in_mps]
    shl ecx, 16
    or ecx, (6 << 3) | (3 << 1)      ; EP type Bulk IN, CErr=3
    mov [rdi + 4], ecx
    mov dword [rdi + 8], FS_BULK_IN_RING | 1   ; TR dequeue, DCS=1
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 512        ; average TRB length
    ; bulk OUT endpoint context
    movzx eax, byte [bulk_out_dci]
    shl eax, 5
    lea edi, [eax + XHCI_INPUT_CTX + 0x20]
    movzx ecx, word [bulk_out_mps]
    shl ecx, 16
    or ecx, (2 << 3) | (3 << 1)      ; EP type Bulk OUT, CErr=3
    mov [rdi + 4], ecx
    mov dword [rdi + 8], FS_BULK_OUT_RING | 1
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 512
    ; fresh rings + producer cycles
    mov edi, FS_BULK_OUT_RING
    mov ecx, 2048                    ; both contiguous 4KB rings
    xor eax, eax
    rep stosd
    mov byte [bulk_in_cycle], 1
    mov byte [bulk_out_cycle], 1
    mov dword [bot_tag], 1
    ; issue the command
    mov eax, [xhci_cmd_index]
    cmp eax, 62
    jae .fail
    mov edi, eax
    shl edi, 4
    add edi, XHCI_CMD_RING
    mov dword [edi + 0], XHCI_INPUT_CTX
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov eax, r10d
    shl eax, 24
    or eax, (12 << 10) | 1           ; CONFIGURE_ENDPOINT, Cycle=1
    mov [edi + 12], eax
    inc dword [xhci_cmd_index]
    mov dword [r12], 0
    mov dl, 33                       ; Command Completion Event
    call xhci_wait_event
    jc .fail
    mov eax, [rsi + 8]
    shr eax, 24
    cmp eax, 1
    jne .fail
    clc
    ret
.fail:
    stc
    ret

; --- Disable slot r10d (same cleanup the usb command's probe does). ---
fs_disable_slot:
    mov eax, [xhci_cmd_index]
    cmp eax, 62
    jae .done
    mov edi, eax
    shl edi, 4
    add edi, XHCI_CMD_RING
    mov dword [edi + 0], 0
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov eax, r10d
    shl eax, 24
    or eax, (10 << 10) | 1           ; DISABLE_SLOT, Cycle=1
    mov [edi + 12], eax
    inc dword [xhci_cmd_index]
    mov dword [r12], 0
    mov dl, 33
    call xhci_wait_event
.done:
    ret

; --- Locate and parse the FAT volume: read LBA 0, accept it directly as a
; FAT boot sector ("superfloppy") or walk the MBR partition table to the
; first partition whose start sector parses as one. Fills the fs_* volume
; variables. CF set if no FAT filesystem was found (or a read failed). ---
fs_mount:
    push rbx
    mov dword [fs_part_lba], 0
    mov byte [fs_is_exfat], 0
    mov byte [fs_is_ntfs], 0
    mov byte [fs_is_fat16], 0
    mov dword [fs_fat_cached], 0xFFFFFFFF
    xor eax, eax
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    cmp word [FS_SECTOR_BUF + 510], 0xAA55
    jne .fail
    call fs_is_vbr
    jnc .parse
    mov ebx, FS_SECTOR_BUF + 446
    mov ecx, 4
.part_loop:
    cmp byte [rbx + 4], 0xEE         ; GPT protective partition
    je .gpt
    cmp byte [rbx + 4], 0            ; partition type
    je .part_next
    mov eax, [rbx + 8]               ; start LBA
    test eax, eax
    jz .part_next
    mov [fs_part_lba], eax
    push rcx
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    pop rcx
    jc .fail
    cmp word [FS_SECTOR_BUF + 510], 0xAA55
    jne .part_next
    call fs_is_vbr
    jnc .parse
.part_next:
    add ebx, 16
    loop .part_loop
    jmp .fail
; --- GPT: read the header at LBA 1, then walk partition entries (4 per
; 512-byte sector) held in FS_FAT_BUF so the VBR read can use FS_SECTOR_BUF.
; Scans up to 32 entries; accepts the first that parses as a VBR. ---
.gpt:
    mov eax, 1
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    mov rax, 0x5452415020494645       ; "EFI PART"
    cmp [FS_SECTOR_BUF + 0], rax
    jne .fail
    mov eax, [FS_SECTOR_BUF + 72]     ; PartitionEntryLBA (low dword)
    mov [fs_gpt_ent_lba], eax
    mov dword [fs_gpt_left], 32
.gpt_sec:
    cmp dword [fs_gpt_left], 0
    je .fail
    mov eax, [fs_gpt_ent_lba]
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jc .fail
    xor edx, edx                      ; edx = entry index within sector
.gpt_ent:
    cmp edx, 4
    jae .gpt_next_sec
    mov eax, edx
    shl eax, 7                        ; 128-byte entries
    lea rbx, [FS_FAT_BUF + rax]
    mov eax, [rbx + 0]                ; type GUID first dword
    or eax, [rbx + 4]
    or eax, [rbx + 8]
    or eax, [rbx + 12]
    jz .gpt_ent_next                  ; all-zero GUID -> unused
    mov eax, [rbx + 32]               ; StartingLBA (low dword)
    mov [fs_part_lba], eax
    push rdx
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    pop rdx
    jc .fail
    cmp word [FS_SECTOR_BUF + 510], 0xAA55
    jne .gpt_ent_next
    call fs_is_vbr
    jnc .parse
.gpt_ent_next:
    inc edx
    jmp .gpt_ent
.gpt_next_sec:
    inc dword [fs_gpt_ent_lba]
    sub dword [fs_gpt_left], 4
    jmp .gpt_sec
.parse:
    mov rax, 0x202020205346544E          ; "NTFS    "
    cmp [FS_SECTOR_BUF + 3], rax
    je .ntfs
    mov rax, 0x2020205441465845          ; "EXFAT   "
    cmp [FS_SECTOR_BUF + 3], rax
    je .exfat
    cmp word [FS_SECTOR_BUF + 11], 512   ; only 512-byte sectors supported
    jne .fail
    movzx eax, byte [FS_SECTOR_BUF + 13] ; sectors/cluster
    test eax, eax
    jz .fail
    mov [fs_spc], eax
    movzx ebx, word [FS_SECTOR_BUF + 14] ; reserved sectors
    add ebx, [fs_part_lba]
    mov [fs_fat_lba], ebx
    movzx eax, word [FS_SECTOR_BUF + 22] ; FATSz16
    test eax, eax
    jnz .have_fatsz
    mov eax, [FS_SECTOR_BUF + 36]        ; FATSz32
.have_fatsz:
    movzx ecx, byte [FS_SECTOR_BUF + 16] ; number of FATs
    imul eax, ecx
    add ebx, eax
    mov [fs_root_lba], ebx               ; FAT12/16 fixed root region
    movzx eax, word [FS_SECTOR_BUF + 17] ; root entry count
    shl eax, 5
    add eax, 511
    shr eax, 9
    mov [fs_root_secs], eax
    add ebx, eax
    mov [fs_data_lba], ebx               ; first sector of cluster 2
    mov byte [fs_is_fat32], 0
    mov byte [fs_is_fat16], 0
    cmp word [FS_SECTOR_BUF + 17], 0     ; no fixed root -> FAT32
    jne .fat1x
    mov byte [fs_is_fat32], 1
    mov eax, [FS_SECTOR_BUF + 44]        ; root directory cluster
    and eax, 0x0FFFFFFF
    mov [fs_cur_cluster], eax
    jmp .done
.fat1x:
    ; fixed root region: FAT12 or FAT16, distinguished by cluster count
    ; (the classic >= 4085 clusters -> FAT16 rule). FAT12 write isn't
    ; implemented (packed 12-bit entries), so it's left unsupported.
    movzx eax, word [FS_SECTOR_BUF + 19] ; total sectors (16-bit)
    test eax, eax
    jnz .have_tot1x
    mov eax, [FS_SECTOR_BUF + 32]        ; total sectors (32-bit)
.have_tot1x:
    mov ecx, eax
    mov eax, [fs_data_lba]
    sub eax, [fs_part_lba]               ; sectors before the data region
    sub ecx, eax                         ; data sectors
    mov eax, ecx
    xor edx, edx
    div dword [fs_spc]                   ; eax = cluster count
    cmp eax, 4085
    jb .done
    mov byte [fs_is_fat16], 1
.done:
    pop rbx
    clc
    ret
.exfat:
    cmp byte [FS_SECTOR_BUF + 108], 9    ; 512-byte sectors only
    jne .fail
    movzx ecx, byte [FS_SECTOR_BUF + 109]
    mov eax, 1
    shl eax, cl
    mov [fs_spc], eax
    mov eax, [FS_SECTOR_BUF + 80]        ; FAT offset
    add eax, [fs_part_lba]
    mov [fs_fat_lba], eax
    mov eax, [FS_SECTOR_BUF + 88]        ; cluster heap offset
    add eax, [fs_part_lba]
    mov [fs_data_lba], eax
    mov eax, [FS_SECTOR_BUF + 96]        ; root directory first cluster
    mov [fs_cur_cluster], eax
    mov [fs_ex_rootdir_clus], eax
    mov eax, [FS_SECTOR_BUF + 92]        ; cluster count
    mov [fs_ex_cluster_count], eax
    mov byte [fs_is_fat32], 0
    mov byte [fs_is_exfat], 1
    mov byte [fs_ex_active], 0
    jmp .done
.ntfs:
    cmp word [FS_SECTOR_BUF + 11], 512   ; bytes/sector
    jne .fail
    movzx eax, byte [FS_SECTOR_BUF + 13] ; sectors/cluster
    test eax, eax
    jz .fail
    mov [fs_spc], eax
    mov eax, [FS_SECTOR_BUF + 48]        ; MFT start cluster (low dword)
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    mov [fs_mft_lba], eax
    mov eax, [FS_SECTOR_BUF + 56]        ; MFTMirr start cluster (low dword)
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    mov [fs_mftmirr_lba], eax
    ; file record size (byte 64): >0 = clusters, <0 = 2^-n bytes
    movsx eax, byte [FS_SECTOR_BUF + 64]
    test eax, eax
    jns .rec_clusters
    neg eax
    mov ecx, eax
    mov eax, 1
    shl eax, cl                          ; bytes per record
    shr eax, 9                           ; -> sectors
    jmp .rec_have
.rec_clusters:
    imul eax, [fs_spc]
.rec_have:
    test eax, eax
    jnz .rec_ok
    mov eax, 1
.rec_ok:
    cmp eax, 16
    jbe .rec_cap
    mov eax, 16
.rec_cap:
    mov [fs_rec_secs], eax
    ; index block size (byte 68): same encoding
    movsx eax, byte [FS_SECTOR_BUF + 68]
    test eax, eax
    jns .idx_clusters
    neg eax
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    shr eax, 9
    jmp .idx_have
.idx_clusters:
    imul eax, [fs_spc]
.idx_have:
    test eax, eax
    jnz .idx_ok
    mov eax, 1
.idx_ok:
    cmp eax, 16
    jbe .idx_cap
    mov eax, 16
.idx_cap:
    mov [fs_indx_secs], eax
    mov byte [fs_is_fat32], 0
    mov byte [fs_is_exfat], 0
    mov byte [fs_is_ntfs], 1
    jmp .done
.fail:
    pop rbx
    stc
    ret

; --- Does FS_SECTOR_BUF look like a FAT/exFAT boot sector? CF clear if yes. ---
fs_is_vbr:
    cmp byte [FS_SECTOR_BUF], 0xEB
    je .chk
    cmp byte [FS_SECTOR_BUF], 0xE9
    jne .no
.chk:
    mov rax, 0x2020205441465845          ; "EXFAT   "
    cmp [FS_SECTOR_BUF + 3], rax
    je .yes
    mov rax, 0x202020205346544E          ; "NTFS    "
    cmp [FS_SECTOR_BUF + 3], rax
    je .yes
    cmp word [FS_SECTOR_BUF + 11], 512
    jne .no
    cmp byte [FS_SECTOR_BUF + 13], 0
    je .no
.yes:
    clc
    ret
.no:
    stc
    ret

; --- List the root directory of the mounted volume. FAT12/16: walk the
; fixed root region; FAT32/exFAT: follow the root cluster chain through the
; FAT. CF set on read error. ---
fs_list_root:
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
    cmp byte [fs_is_ntfs], 0
    jne fs_ntfs_list
    cmp byte [fs_is_exfat], 0
    jne .fat32
    cmp byte [fs_is_fat32], 0
    jne .fat32
    cmp byte [fs_in_subdir], 0       ; cd'd into a FAT12/16 subdir: cluster chain
    jne .fat32
    mov eax, [fs_root_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_root_secs]
    mov [fs_sec_count], eax
.f16_loop:
    cmp dword [fs_sec_count], 0
    je .done
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    call fs_list_sector
    jc .done                         ; hit the end-of-directory marker
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .f16_loop
.fat32:
.clus_loop:
    mov eax, [fs_cur_cluster]
    cmp eax, 2
    jb .done
    cmp eax, 0x0FFFFFF8              ; end-of-chain
    jae .done
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.f32_sec_loop:
    cmp dword [fs_sec_count], 0
    je .next_clus
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    call fs_list_sector
    jc .done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .f32_sec_loop
.next_clus:
    mov eax, [fs_cur_cluster]
    call fs_next_cluster
    jc .fail
    mov [fs_cur_cluster], eax
    jmp .clus_loop
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Advance a directory/data cluster to the next one in the FAT: eax =
; cluster in, eax = next cluster out. Dual-width (FAT16 2-byte / FAT32 and
; exFAT 4-byte entries); FAT16 EOC is normalized to 0x0FFFFFFF so callers
; can share the FAT32-style bounds checks. Uses FS_FAT_BUF/fs_fat_cached.
; CF set on read error only. ---
fs_next_cluster:
    mov [fs_nc_cur], eax
    cmp byte [fs_is_exfat], 0
    jne .w32
    cmp byte [fs_is_fat16], 0
    jne .w16
.w32:
    mov ecx, eax
    shr ecx, 7                       ; 128 32-bit entries per sector
    add ecx, [fs_fat_lba]
    cmp ecx, [fs_fat_cached]
    je .c32
    mov [fs_fat_cached], ecx
    mov eax, ecx
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .c32
    mov dword [fs_fat_cached], 0xFFFFFFFF
    stc
    ret
.c32:
    mov eax, [fs_nc_cur]
    and eax, 127
    mov eax, [FS_FAT_BUF + rax*4]
    cmp byte [fs_is_exfat], 0
    jne .ok
    and eax, 0x0FFFFFFF
.ok:
    clc
    ret
.w16:
    mov ecx, eax
    shr ecx, 8                       ; 256 16-bit entries per sector
    add ecx, [fs_fat_lba]
    cmp ecx, [fs_fat_cached]
    je .c16
    mov [fs_fat_cached], ecx
    mov eax, ecx
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .c16
    mov dword [fs_fat_cached], 0xFFFFFFFF
    stc
    ret
.c16:
    mov eax, [fs_nc_cur]
    and eax, 255
    movzx eax, word [FS_FAT_BUF + rax*2]
    cmp eax, 0xFFF8
    jb .ok
    mov eax, 0x0FFFFFFF              ; normalize FAT16 EOC
    jmp .ok

; --- Print the 16 directory entries in FS_SECTOR_BUF, skipping deleted
; entries, long-file-name entries and the volume label. CF set when the
; 0x00 end-of-directory marker is hit. ---
fs_list_sector:
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    cmp byte [fs_is_exfat], 0
    jne .exfat
    mov al, [rsi]
    test al, al
    jz .end_marker
    cmp al, 0xE5                     ; deleted
    je .del
    mov al, [rsi + 11]
    cmp al, 0x0F                     ; long-file-name entry
    je .lfn
    test al, 0x08                    ; volume label
    jnz .skip
    call fs_print_entry_lfn
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.lfn:
    call fs_lfn_accumulate
    jmp .skip
.del:
    mov byte [fs_lfn_have], 0        ; deleted entry breaks the LFN chain
    mov dword [fs_lfn_maxlen], 0
    jmp .skip
.exfat:
    mov al, [rsi]
    test al, al
    jz .end_marker
    cmp al, 0x85                     ; file directory entry
    jne .ex_not_file
    mov al, [rsi + 4]                ; file attributes (low byte)
    mov [fs_ex_attr], al
    mov al, [rsi + 1]                ; secondary count
    mov [fs_ex_nrem], al
    mov byte [fs_ex_active], 1
    mov dword [fs_ex_size], 0
    mov dword [fs_name_len], 0
    jmp .skip
.ex_not_file:
    cmp byte [fs_ex_active], 0
    je .skip
    cmp al, 0xC0                     ; stream extension entry
    jne .ex_not_stream
    mov eax, [rsi + 24]              ; data length (low dword)
    mov [fs_ex_size], eax
    jmp .ex_sec_done
.ex_not_stream:
    cmp al, 0xC1                     ; file name entry
    jne .ex_sec_done
    xor ecx, ecx
.ex_name_loop:
    cmp ecx, 15
    jae .ex_sec_done
    mov ax, [rsi + 2 + rcx*2]        ; UTF-16 char
    test ax, ax
    jz .ex_sec_done
    cmp ax, 0x7F
    jbe .ex_ch_ok
    mov al, '?'
.ex_ch_ok:
    push rcx
    call print_char
    pop rcx
    inc dword [fs_name_len]
    inc ecx
    jmp .ex_name_loop
.ex_sec_done:
    dec byte [fs_ex_nrem]
    jnz .skip
    mov byte [fs_ex_active], 0
    call fs_ex_finish_entry
    jmp .skip
.not_end:
    clc
    ret
.end_marker:
    stc
    ret

; --- Pad the exFAT name to the column and print "<DIR>" or the size. ---
fs_ex_finish_entry:
.pad_loop:
    cmp dword [fs_name_len], 14
    jae .pad_done
    mov al, ' '
    call print_char
    inc dword [fs_name_len]
    jmp .pad_loop
.pad_done:
    test byte [fs_ex_attr], 0x10
    jz .file
    mov rsi, fs_dir_tag_msg
    call print_string
    jmp .cr
.file:
    mov eax, [fs_ex_size]
    call print_dec64
.cr:
    mov al, ASCII_CR
    call print_char
    ret

; --- Print one 8.3 directory entry at rsi: "NAME.EXT" padded to a column,
; then "<DIR>" or the file size in bytes. ---
fs_print_entry:
    mov dword [fs_name_len], 0
    xor ecx, ecx
.name_loop:
    cmp ecx, 8
    jae .name_done
    mov al, [rsi + rcx]
    cmp al, ' '
    je .name_done
    call print_char
    inc dword [fs_name_len]
    inc ecx
    jmp .name_loop
.name_done:
    cmp byte [rsi + 8], ' '
    je .ext_done
    mov al, '.'
    call print_char
    inc dword [fs_name_len]
    mov ecx, 8
.ext_loop:
    cmp ecx, 11
    jae .ext_done
    mov al, [rsi + rcx]
    cmp al, ' '
    je .ext_done
    call print_char
    inc dword [fs_name_len]
    inc ecx
    jmp .ext_loop
.ext_done:
.pad_loop:
    cmp dword [fs_name_len], 14
    jae .pad_done
    mov al, ' '
    call print_char
    inc dword [fs_name_len]
    jmp .pad_loop
.pad_done:
    mov al, [rsi + 11]
    test al, 0x10                    ; directory?
    jz .file
    push rsi
    mov rsi, fs_dir_tag_msg
    call print_string
    pop rsi
    jmp .cr
.file:
    mov eax, [rsi + 28]              ; file size
    call print_dec64
.cr:
    mov al, ASCII_CR
    call print_char
    ret

; --- Accumulate one VFAT long-file-name entry (rsi -> 0x0F entry) into
; fs_lfn_buf. Entries arrive in reverse sequence order; each holds 13
; UTF-16 chars placed by its sequence number. Sets fs_lfn_have. Non-ASCII
; folds to '?'. Clobbers eax/ebx/ecx/edx (not rsi). ---
fs_lfn_accumulate:
    movzx eax, byte [rsi]
    and eax, 0x1F                    ; sequence number (1-based)
    test eax, eax
    jz .ret
    cmp eax, 20
    ja .ret
    dec eax
    imul eax, eax, 13
    mov [fs_lfn_base], eax           ; base index = (seq-1)*13
    mov byte [fs_lfn_have], 1
    xor ebx, ebx                     ; char index 0..12
.cl:
    cmp ebx, 13
    jae .ret
    movzx ecx, byte [fs_lfn_off + rbx]
    mov ax, [rsi + rcx]
    test ax, ax
    jz .ret                          ; 0x0000 terminator: name ends
    cmp ax, 0xFFFF
    je .ret                          ; padding
    cmp ax, 0x7F
    jbe .st
    mov ax, '?'
.st:
    mov ecx, [fs_lfn_base]
    add ecx, ebx
    cmp ecx, 259
    jae .nxt
    mov [fs_lfn_buf + rcx], al
    inc ecx
    cmp ecx, [fs_lfn_maxlen]
    jbe .nxt
    mov [fs_lfn_maxlen], ecx
.nxt:
    inc ebx
    jmp .cl
.ret:
    ret

; --- Print a directory entry (rsi -> 8.3 entry) using the accumulated LFN
; long name if present, otherwise the plain 8.3 name. Same size/<DIR>
; trailer as fs_print_entry. ---
fs_print_entry_lfn:
    cmp byte [fs_lfn_have], 0
    je fs_print_entry
    push rsi
    mov dword [fs_name_len], 0
    xor ecx, ecx
.nl:
    cmp ecx, [fs_lfn_maxlen]
    jae .nd
    mov al, [fs_lfn_buf + rcx]
    call print_char
    inc dword [fs_name_len]
    inc ecx
    jmp .nl
.nd:
    cmp dword [fs_name_len], 14
    jae .sp
.pad:
    cmp dword [fs_name_len], 14
    jae .pd
    mov al, ' '
    call print_char
    inc dword [fs_name_len]
    jmp .pad
.sp:
    mov al, ' '
    call print_char
.pd:
    pop rsi
    mov al, [rsi + 11]
    test al, 0x10
    jz .file
    push rsi
    mov rsi, fs_dir_tag_msg
    call print_string
    pop rsi
    jmp .cr
.file:
    mov eax, [rsi + 28]
    call print_dec64
.cr:
    mov al, ASCII_CR
    call print_char
    ret

; --- Compare the accumulated LFN name (uppercased) against fs_target_raw.
; Returns al=1 (and ZF set) on match, al=0 otherwise. ---
fs_lfn_match:
    mov eax, [fs_lfn_maxlen]
    cmp eax, [fs_target_raw_len]
    jne .no
    xor ecx, ecx
.l:
    cmp ecx, [fs_lfn_maxlen]
    jae .yes
    mov al, [fs_lfn_buf + rcx]
    cmp al, 'a'
    jb .cmp
    cmp al, 'z'
    ja .cmp
    sub al, 0x20
.cmp:
    mov dl, [fs_target_raw + rcx]
    cmp al, dl
    jne .no
    inc ecx
    jmp .l
.yes:
    mov al, 1
    test al, al                      ; clear ZF? set: al=1 -> ZF=0. use al as truth
    ret
.no:
    xor al, al
    ret

; --- Read fs_rec_secs sectors starting at LBA eax into buffer edi. ---
fs_read_run:
    push rcx
    push rsi
    mov ecx, [fs_rec_secs]
    mov esi, eax
.rr_loop:
    push rcx
    push rsi
    push rdi
    mov eax, esi
    call fs_read_sector
    pop rdi
    pop rsi
    pop rcx
    jc .rr_fail
    inc esi
    add edi, 512
    dec ecx
    jnz .rr_loop
    pop rsi
    pop rcx
    clc
    ret
.rr_fail:
    pop rsi
    pop rcx
    stc
    ret

; --- Read edx sectors starting at LBA eax into buffer edi (INDX blocks). ---
fs_read_secs:
    push rcx
    push rsi
    mov ecx, edx
    mov esi, eax
.rs_loop:
    push rcx
    push rsi
    push rdi
    mov eax, esi
    call fs_read_sector
    pop rdi
    pop rsi
    pop rcx
    jc .rs_fail
    inc esi
    add edi, 512
    dec ecx
    jnz .rs_loop
    pop rsi
    pop rcx
    clc
    ret
.rs_fail:
    pop rsi
    pop rcx
    stc
    ret

; --- Apply the NTFS update-sequence-array fixup to the record at edi,
; spanning ecx 512-byte sectors: restore the last word of each sector from
; the USA following the record header. ---
fs_apply_fixup:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    movzx eax, word [rdi + 4]        ; USA offset
    movzx ecx, word [rdi + 6]        ; USA count (fixup word + one per sector)
    lea rsi, [rdi + rax]             ; rsi -> USA
    add rsi, 2                       ; skip the check value
    mov edx, 0                      ; sector index
.fx_loop:
    dec ecx                          ; entries after the check value
    cmp ecx, 0
    jle .fx_done
    mov eax, edx
    shl eax, 9
    add eax, 510                     ; last word of this sector
    mov bx, [rsi]
    mov [rdi + rax], bx
    add rsi, 2
    inc edx
    jmp .fx_loop
.fx_done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- List the NTFS root directory (MFT record 5). Reads the record, applies
; fixups, then walks INDEX_ROOT and any INDEX_ALLOCATION runs. CF on error. ---
fs_ntfs_list:
    mov eax, [fs_ntfs_dir_ref]      ; current directory (5 = root, or cwd)
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .fail
    cmp dword [FS_MFT_BUF], 0x454C4946   ; "FILE"
    jne .fail
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    movzx eax, word [FS_MFT_BUF + 0x10]  ; dir record sequence number, for
    mov [fs_ntfs_dir_seq], eax           ; new $FILE_NAME parent references
    ; walk attributes for INDEX_ROOT (0x90) and INDEX_ALLOCATION (0xA0)
    movzx edx, word [FS_MFT_BUF + 20]    ; first attribute offset
.attr_loop:
    mov eax, edx
    cmp eax, 4096
    jae .no_root
    mov eax, [FS_MFT_BUF + rdx]           ; attribute type
    cmp eax, 0xFFFFFFFF
    je .no_root
    cmp eax, 0x90
    je .found_root
    mov eax, [FS_MFT_BUF + rdx + 4]       ; attribute length
    test eax, eax
    jz .no_root
    add edx, eax
    jmp .attr_loop
.found_root:
    ; resident: value at [attr + valueOffset(0x14 word)]
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]
    add eax, edx
    lea rsi, [FS_MFT_BUF + rax]           ; rsi -> INDEX_ROOT
    ; INDEX_NODE_HEADER at rsi+16; entries at +[hdr+0]
    mov eax, [rsi + 16]                   ; first entry offset (rel to node hdr)
    lea rbx, [rsi + 16]
    add rbx, rax                          ; rbx -> first index entry
    mov rsi, rbx
    call fs_ntfs_walk
    cmp byte [fs_action], 0
    je .check_alloc
    cmp byte [fs_cat_found], 0
    jne .done                             ; cat found its match in the root
    ; INDEX_ALLOCATION present? node header flags bit 0
.check_alloc:
    ; re-scan attributes for 0xA0
    movzx edx, word [FS_MFT_BUF + 20]
.alloc_scan:
    mov eax, edx
    cmp eax, 4096
    jae .done
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .done
    cmp eax, 0xA0
    je .found_alloc
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .done
    add edx, eax
    jmp .alloc_scan
.found_alloc:
    ; non-resident: data runs at [attr + runsOffset(0x20 word)]
    movzx eax, word [FS_MFT_BUF + rdx + 0x20]
    add eax, edx
    mov [fs_run_ptr], eax
    mov dword [fs_run_lcn], 0
.run_loop:
    mov eax, [fs_run_ptr]
    movzx ecx, byte [FS_MFT_BUF + rax]    ; run header
    test cl, cl
    jz .done                              ; end of runs
    inc eax
    mov ebx, ecx
    and ebx, 0x0F                         ; length field size
    mov edx, ecx
    shr edx, 4                            ; offset field size
    ; read run length (little-endian, ebx bytes)
    ; (r10-r15/rbp hold live xHCI state - use esi/edi as scratch here)
    xor r8d, r8d
    xor r9d, r9d                          ; shift
.len_bytes:
    test ebx, ebx
    jz .len_done
    movzx ecx, byte [FS_MFT_BUF + rax]
    mov esi, ecx
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec ebx
    jmp .len_bytes
.len_done:
    mov [fs_run_len], r8d
    ; read run offset (signed, edx bytes)
    xor r8d, r8d
    xor r9d, r9d
    mov edi, edx                          ; keep count for sign extension
.off_bytes:
    test edx, edx
    jz .off_done
    movzx ecx, byte [FS_MFT_BUF + rax]
    mov esi, ecx
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec edx
    jmp .off_bytes
.off_done:
    ; sign-extend r8d from (edi*8) bits
    test edi, edi
    jz .after_run                         ; sparse (no offset) - skip
    mov ecx, edi
    shl ecx, 3
    cmp ecx, 32
    jae .no_sext
    mov edx, 1
    dec ecx
    shl edx, cl                           ; sign bit mask
    test r8d, edx
    jz .no_sext
    mov ecx, edi
    shl ecx, 3
    mov edx, 0xFFFFFFFF
    shl edx, cl
    or r8d, edx                           ; sign bits set
.no_sext:
    mov [fs_run_ptr], eax                 ; advance past this run header
    add [fs_run_lcn], r8d                 ; LCN += delta
    ; read each index block of this run (fs_run_len clusters remain)
.blk_loop:
    cmp dword [fs_run_len], 0
    jle .run_loop
    mov eax, [fs_run_lcn]
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    mov edi, FS_INDX_BUF
    mov edx, [fs_indx_secs]
    call fs_read_secs
    jc .fail
    cmp dword [FS_INDX_BUF], 0x58444E49    ; "INDX"
    jne .blk_next
    mov edi, FS_INDX_BUF
    mov ecx, [fs_indx_secs]
    call fs_apply_fixup
    mov eax, [FS_INDX_BUF + 24]           ; first entry offset (rel to +24)
    lea rsi, [FS_INDX_BUF + 24]
    add rsi, rax
    call fs_ntfs_walk
    cmp byte [fs_action], 0
    je .blk_next
    cmp byte [fs_cat_found], 0
    jne .done                             ; cat found its match in this block
.blk_next:
    ; advance LCN by clusters-per-index-block, decrement remaining
    mov eax, [fs_indx_secs]
    xor edx, edx
    div dword [fs_spc]                    ; clusters per INDX block
    test eax, eax
    jnz .have_cpb
    mov eax, 1
.have_cpb:
    add [fs_run_lcn], eax
    sub [fs_run_len], eax
    jmp .blk_loop
.after_run:
    mov [fs_run_ptr], eax
    jmp .run_loop
.no_root:
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Walk a chain of NTFS index entries starting at rsi; print each real
; FILE_NAME (skip system files, DOS-namespace and sub-node pointers). Stops
; at the entry whose flags bit 1 (last) is set. ---
fs_ntfs_walk:
    push rbx
    push r12
    mov r12d, 512                    ; safety bound on entries
.walk_loop:
    dec r12d
    jz .walk_done
    ; entry: fileRef(8) length(2 @8) keyLen(2 @10) flags(2 @12)
    movzx ebx, word [rsi + 12]       ; flags
    test bl, 0x02                    ; last entry
    jnz .walk_done
    movzx eax, word [rsi + 10]       ; key (FILE_NAME) length
    test eax, eax
    jz .walk_next
    ; FILE_NAME key starts at rsi+16; MFT ref of parent at +0
    ; namespace at key+0x41, name length (chars) at key+0x40, name at +0x42
    mov rax, [rsi]                   ; file reference (low 6 bytes = record #)
    shl rax, 16
    shr rax, 16
    cmp rax, 16                      ; system files occupy records 0..15
    jb .walk_next
    mov [fs_cat_ntfs_ref], eax       ; stash record # in case cat matches it
    movzx eax, byte [rsi + 16 + 0x41]  ; namespace
    cmp al, 2                        ; DOS-only name -> skip (dup)
    je .walk_next
    cmp byte [fs_ntfs_collect], 0    ; rm -r child enumeration
    jne .do_collect
    cmp byte [fs_action], 0
    je .do_print
    call fs_ntfs_match
    cmp byte [fs_cat_found], 0
    jne .walk_done
    jmp .walk_next
.do_collect:
    call fs_ntfs_collect_child
    jmp .walk_next
.do_print:
    call fs_ntfs_print
.walk_next:
    movzx eax, word [rsi + 8]        ; entry length
    test eax, eax
    jz .walk_done
    add rsi, rax
    jmp .walk_loop
.walk_done:
    pop r12
    pop rbx
    ret

; --- Compare one NTFS index entry's FILE_NAME at rsi against fs_target_raw
; (case-folded the same way fs_ntfs_print folds for display). On a match
; against a non-directory entry, sets fs_cat_found=1 and fs_cat_size (real
; size); fs_cat_ntfs_ref was already stashed by fs_ntfs_walk. ---
fs_ntfs_match:
    push rsi
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    movzx ecx, byte [rsi + 16 + 0x40]   ; name length in UTF-16 chars
    lea rbx, [rsi + 16 + 0x42]          ; name
    cmp ecx, [fs_target_raw_len]
    jne .no_match
    lea r9, [fs_target_raw]
    xor edx, edx
.cmp_loop:
    cmp edx, ecx
    jae .name_ok
    mov ax, [rbx + rdx*2]
    cmp ax, 0x7F
    jbe .ch_ok
    mov al, '?'
.ch_ok:
    cmp al, 'a'
    jb .ch_have
    cmp al, 'z'
    ja .ch_have
    sub al, 0x20
.ch_have:
    cmp al, [r9 + rdx]
    jne .no_match
    inc edx
    jmp .cmp_loop
.name_ok:
    ; classify: al = 1 if the entry is a directory, else 0
    mov edx, [rsi + 16 + 0x38]          ; file attribute flags (low dword)
    xor eax, eax
    test edx, 0x10000000                ; directory (index present)
    jnz .is_dir
    test edx, 0x10                      ; FILE_ATTRIBUTE_DIRECTORY
    jz .have_kind
.is_dir:
    mov al, 1
.have_kind:
    cmp byte [fs_want_dir], 2           ; rm: anything matches
    je .accept
    cmp [fs_want_dir], al               ; cat/echo want 0 (file), cd wants 1 (dir)
    jne .no_match
.accept:
    mov [fs_rm_is_dir], al
    mov eax, [rsi + 16 + 0x30]          ; real size (low dword)
    mov [fs_cat_size], eax
    mov byte [fs_cat_found], 1
.no_match:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rsi
    ret

; --- Print one NTFS index entry at rsi: FILE_NAME name, padded, then
; "<DIR>" or the real file size. ---
fs_ntfs_print:
    push rsi
    push r12
    mov dword [fs_name_len], 0
    movzx r12d, byte [rsi + 16 + 0x40]  ; name length in UTF-16 chars
    lea rbx, [rsi + 16 + 0x42]          ; name
    xor ecx, ecx
.name_loop:
    cmp ecx, r12d
    jae .name_done
    mov ax, [rbx + rcx*2]
    cmp ax, 0x7F
    jbe .ch_ok
    mov ax, '?'
.ch_ok:
    push rcx
    push rbx
    call print_char
    pop rbx
    pop rcx
    inc dword [fs_name_len]
    inc ecx
    jmp .name_loop
.name_done:
.pad_loop:
    cmp dword [fs_name_len], 14
    jae .pad_done
    mov al, ' '
    call print_char
    inc dword [fs_name_len]
    jmp .pad_loop
.pad_done:
    mov eax, [rsi + 16 + 0x38]          ; file attribute flags (low dword)
    test eax, 0x10000000                ; directory (index present)
    jnz .dir
    test eax, 0x10                      ; FILE_ATTRIBUTE_DIRECTORY
    jnz .dir
    mov eax, [rsi + 16 + 0x30]          ; real size (low dword)
    call print_dec64
    jmp .cr
.dir:
    mov rsi, fs_dir_tag_msg
    call print_string
.cr:
    mov al, ASCII_CR
    call print_char
    pop r12
    pop rsi
    ret

; --- Bring up the device on port ebp and, if it is a bulk-only
; mass-storage device, mount its FAT volume and list the root directory.
; CF set = nothing usable on this port, keep scanning. CF clear = handled
; (listed, or a diagnostic was printed); fs_found set stops the scan. ---
fs_try_port:
    lea rdi, [r15 + 0x400]
    mov eax, ebp
    shl eax, 4
    add rdi, rax                     ; rdi -> PORTSC(port)
    mov eax, [rdi]
    test eax, 1                      ; CCS
    jz .fail
    mov edx, eax
    shr edx, 10
    and edx, 0xF                     ; speed
    test eax, 1 << 1                 ; already enabled?
    jnz .port_ready
    mov ebx, eax
    and ebx, 0xFF01FFFD              ; clear PED + RW1C change bits
    or ebx, 1 << 4                   ; PR
    mov [rdi], ebx
    mov ecx, 20000000
.wait_prc:
    mov eax, [rdi]
    test eax, 1 << 21                ; PRC
    jnz .prc_set
    loop .wait_prc
    jmp .fail
.prc_set:
    mov ebx, eax
    and ebx, 0xFF01FFFD
    mov [rdi], ebx
    mov eax, [rdi]
    test eax, 1 << 1                 ; PED
    jz .fail
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
    jae .fail
    mov edi, eax
    shl edi, 4
    add edi, XHCI_CMD_RING
    mov dword [edi + 0], 0
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov dword [edi + 12], (9 << 10) | 1   ; ENABLE_SLOT, Cycle=1
    inc dword [xhci_cmd_index]
    mov dword [r12], 0
    mov dl, 33
    call xhci_wait_event
    jc .fail
    mov eax, [rsi + 8]
    shr eax, 24
    cmp eax, 1
    jne .fail
    mov eax, [rsi + 12]
    shr eax, 24
    mov r10d, eax                    ; r10 = slot id
    ; --- input/output contexts: slot + EP0 ---
    mov edi, XHCI_INPUT_CTX
    mov ecx, 264
    xor eax, eax
    rep stosd
    mov edi, XHCI_OUTPUT_CTX
    mov ecx, 264
    xor eax, eax
    rep stosd
    mov dword [XHCI_INPUT_CTX + 4], 0x3   ; A0 | A1
    mov eax, [xhci_speed]
    shl eax, 20
    or eax, 1 << 27                  ; context entries = 1
    mov [XHCI_INPUT_CTX + 0x20], eax
    mov eax, ebp
    inc eax
    shl eax, 16                      ; root hub port number
    mov [XHCI_INPUT_CTX + 0x24], eax
    mov eax, 4 << 3                  ; EP type Control
    or eax, 3 << 1                   ; CErr=3
    mov ecx, [xhci_mps]
    shl ecx, 16
    or eax, ecx
    mov [XHCI_INPUT_CTX + 0x44], eax
    mov eax, XHCI_XFER_RING
    and eax, 0xFFFFFFF0
    or eax, 1                        ; DCS
    mov [XHCI_INPUT_CTX + 0x48], eax
    mov dword [XHCI_INPUT_CTX + 0x4C], 0
    mov dword [XHCI_INPUT_CTX + 0x50], 8
    mov byte [xhci_xfer_cycle], 1
    mov eax, r10d
    shl eax, 3
    mov edi, XHCI_DCBAA
    add edi, eax
    mov dword [edi], XHCI_OUTPUT_CTX
    mov dword [edi + 4], 0
    ; --- Address Device ---
    mov eax, [xhci_cmd_index]
    cmp eax, 62
    jae .disable
    mov edi, eax
    shl edi, 4
    add edi, XHCI_CMD_RING
    mov dword [edi + 0], XHCI_INPUT_CTX
    mov dword [edi + 4], 0
    mov dword [edi + 8], 0
    mov eax, r10d
    shl eax, 24
    or eax, (11 << 10) | 1           ; ADDRESS_DEVICE, Cycle=1
    mov [edi + 12], eax
    inc dword [xhci_cmd_index]
    mov dword [r12], 0
    mov dl, 33
    call xhci_wait_event
    jc .disable
    mov eax, [rsi + 8]
    shr eax, 24
    cmp eax, 1
    jne .disable
    ; --- GET_DESCRIPTOR(Configuration, 0), wLength=255 ---
    mov rax, 0x00FF000002000680
    call fs_ctrl_xfer
    jc .disable
    call fs_parse_config
    jc .disable                      ; not mass storage - keep scanning
    ; --- SET_CONFIGURATION ---
    movzx eax, byte [fs_config_val]
    shl eax, 16
    or eax, 0x0900
    call fs_ctrl_xfer
    jc .disable
    call fs_configure_endpoints
    jc .io_err
    ; --- wait for the unit to become ready ---
    mov r11d, 8
.tur_loop:
    call fs_test_ready
    jnc .ready
    call fs_req_sense                ; clear unit attention, ignore result
    dec r11d
    jnz .tur_loop
    jmp .io_err
.ready:
    call fs_mount
    jc .fs_err
    call fs_apply_cwd
    cmp byte [fs_action], 0
    je .do_list
    cmp byte [fs_action], 2
    je .do_echo
    cmp byte [fs_action], 3
    je .do_cd
    cmp byte [fs_action], 4
    je .do_rm
    call fs_cat_root
    jmp .listed
.do_list:
    call fs_list_root
    jmp .listed
.do_cd:
    call fs_cd_root
    jmp .listed
.do_rm:
    call fs_rm_root
    jmp .listed
.do_echo:
    call fs_echo_root
.listed:
    jc .io_err
    mov byte [fs_found], 1
    call fs_disable_slot
    clc
    ret
.io_err:
    mov rsi, fs_xfer_err_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    mov byte [fs_found], 1           ; device present but unusable: stop scan
    call fs_disable_slot
    clc
    ret
.fs_err:
    mov rsi, fs_no_fat_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    mov byte [fs_found], 1
    call fs_disable_slot
    clc
    ret
.disable:
    call fs_disable_slot
.fail:
    stc
    ret

; --- After a successful mount, point the directory walkers at the saved cd
; working directory instead of the root, when the cwd stack belongs to this
; volume (same partition LBA). A different volume drops the stale stack.
; NTFS ignores cd (root-only support). ---
fs_apply_cwd:
    mov byte [fs_in_subdir], 0
    mov dword [fs_ntfs_dir_ref], 5   ; default: NTFS root
    cmp dword [fs_cwd_depth], 0
    je .ret
    mov eax, [fs_part_lba]
    cmp eax, [fs_cwd_vol]
    jne .drop
    call fs_cur_fstype
    cmp al, [fs_cwd_fstype]
    je .apply
.drop:
    mov dword [fs_cwd_depth], 0
    mov dword [fs_cwd_path_len], 0
    ret
.apply:
    mov eax, [fs_cwd_depth]
    mov eax, [fs_cwd_stack + rax*4 - 4]
    cmp byte [fs_is_ntfs], 0
    jne .ntfs
    mov [fs_cur_cluster], eax
    mov byte [fs_in_subdir], 1
    ret
.ntfs:
    mov [fs_ntfs_dir_ref], eax       ; stack holds MFT record refs on NTFS
    mov byte [fs_in_subdir], 1
.ret:
    ret

; --- Classify the mounted volume for cwd-stack validation: al = 1 (FAT),
; 2 (exFAT) or 3 (NTFS). ---
fs_cur_fstype:
    mov al, 3
    cmp byte [fs_is_ntfs], 0
    jne .r
    mov al, 2
    cmp byte [fs_is_exfat], 0
    jne .r
    mov al, 1
.r:
    ret

; --- "ls"/"cat" shared handler: scan PCI for xHCI controllers and, on the
; first FAT-formatted USB mass-storage device found, either list the root
; directory or cat a file, per fs_action (0 = list, 1 = cat). ---
cmd_ls:
    mov byte [fs_action], 0
    jmp fs_scan_devices

; --- "cat <filename>" handler: rsi -> nul-terminated filename argument. ---
cmd_cat:
    mov byte [fs_want_dir], 0
    mov al, [rsi]
    or al, al
    jz .usage
    call fs_build_target_name
    mov byte [fs_action], 1
    jmp fs_scan_devices
.usage:
    mov rsi, cat_usage_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

; --- "cd [dir]" handler: rsi -> argument. With no argument, prints the
; current path. "/" (or "\") resets to the root, ".." pops one level - both
; handled locally against the saved stack, no device access. Anything else
; is a single directory name searched for in the current directory of the
; USB volume (FAT16/32/exFAT). ---
cmd_cd:
    mov al, [rsi]
    or al, al
    jz .show
    cmp al, '/'
    je .chk_root
    cmp al, 0x5C                     ; '\'
    je .chk_root
    cmp al, '.'
    je .dots
.name:
    call fs_build_target_name
    mov byte [fs_action], 3
    jmp fs_scan_devices
.chk_root:
    mov al, [rsi + 1]
    or al, al
    jz .go_root
    cmp al, ' '
    je .go_root
    jmp .name                        ; "/foo": treated as a plain name
.go_root:
    mov dword [fs_cwd_depth], 0
    mov dword [fs_cwd_path_len], 0
    ret
.dots:
    cmp byte [rsi + 1], '.'
    jne .name                        ; "." or ".foo": plain name
    mov al, [rsi + 2]
    or al, al
    jz .go_up
    cmp al, ' '
    je .go_up
    jmp .name                        ; "..foo": plain name
.go_up:
    cmp dword [fs_cwd_depth], 0
    je .done
    dec dword [fs_cwd_depth]
    call fs_cwd_path_pop
.done:
    ret
.show:
    cmp dword [fs_cwd_path_len], 0
    jne .show_path
    mov al, '/'
    call print_char
    jmp .show_cr
.show_path:
    xor ecx, ecx
.show_loop:
    cmp ecx, [fs_cwd_path_len]
    jae .show_cr
    mov al, [fs_cwd_path + rcx]
    call print_char
    inc ecx
    jmp .show_loop
.show_cr:
    mov al, ASCII_CR
    call print_char
    ret

; --- "rm [-r] <name>" handler: rsi -> arguments. Deletes a file, or a whole
; directory tree with -r, in the current directory (FAT16/32/exFAT). ---
cmd_rm:
    mov byte [fs_rm_recursive], 0
    mov al, [rsi]
    or al, al
    jz .usage
    cmp al, '-'
    jne .have_name
    cmp byte [rsi + 1], 'r'
    jne .usage
    cmp byte [rsi + 2], ' '
    jne .usage                       ; "-r" with no name, or "-rx"
    mov byte [fs_rm_recursive], 1
    add rsi, 3
.skip_sp:
    cmp byte [rsi], ' '
    jne .sp_done
    inc rsi
    jmp .skip_sp
.sp_done:
    cmp byte [rsi], 0
    je .usage
.have_name:
    cmp byte [rsi], '.'              ; refuse "." and ".." targets
    jne .go
    mov al, [rsi + 1]
    or al, al
    jz .dots
    cmp al, ' '
    je .dots
    cmp al, '.'
    jne .go
    mov al, [rsi + 2]
    or al, al
    jz .dots
    cmp al, ' '
    je .dots
.go:
    call fs_build_target_name
    mov byte [fs_action], 4
    jmp fs_scan_devices
.dots:
    mov rsi, rm_dots_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret
.usage:
    mov rsi, rm_usage_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    ret

; --- Append "/<fs_target_disp>" to the display path (best-effort: skipped
; if it wouldn't fit). ---
fs_cwd_path_append:
    mov ecx, [fs_cwd_path_len]
    mov eax, ecx
    add eax, [fs_target_raw_len]
    inc eax
    cmp eax, 255
    ja .done
    mov byte [fs_cwd_path + rcx], '/'
    inc ecx
    xor ebx, ebx
.copy:
    cmp ebx, [fs_target_raw_len]
    jae .fin
    mov al, [fs_target_disp + rbx]
    mov [fs_cwd_path + rcx], al
    inc ecx
    inc ebx
    jmp .copy
.fin:
    mov [fs_cwd_path_len], ecx
.done:
    ret

; --- Drop the last "/component" from the display path. ---
fs_cwd_path_pop:
    mov ecx, [fs_cwd_path_len]
.scan:
    test ecx, ecx
    jz .fin
    dec ecx
    cmp byte [fs_cwd_path + rcx], '/'
    jne .scan
.fin:
    mov [fs_cwd_path_len], ecx
    ret

fs_scan_devices:
    push rbx
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov byte [fs_found], 0
    xor r12, r12                     ; r12b = bus
.bus_loop:
    xor r13, r13                     ; r13b = dev
.dev_loop:
    xor r14, r14                     ; r14b = func
.func_loop:
    mov cl, 0x00
    call pci_read32
    cmp eax, 0xFFFFFFFF
    je .next_func
    mov cl, 0x08
    call pci_read32
    shr eax, 8
    cmp eax, 0x0C0330                ; class 0C / subclass 03 / prog-if 30: xHCI
    jne .next_func
    mov cl, 0x10
    call pci_read32
    mov ebx, eax
    and ebx, 0x6                     ; BAR0 memory type bits
    cmp ebx, 0x4                     ; 64-bit BAR
    jne .bar_low
    mov cl, 0x14
    call pci_read32
    test eax, eax
    jnz .next_func                   ; BAR above 4GB - unsupported
.bar_low:
    mov cl, 0x10
    call pci_read32
    and eax, 0xFFFFFFF0
    cmp eax, IDENTITY_MAP_LIMIT
    jb .mmio_ok
    cmp eax, MMIO_HIGH_BASE
    jb .next_func
    cmp eax, MMIO_HIGH_LIMIT - 1
    ja .next_func
.mmio_ok:
    mov ebp, eax                     ; rbp = capability register base
    mov cl, 0x04
    call pci_read32
    or eax, 0x06                     ; Memory Space + Bus Master
    mov cl, 0x04
    call pci_write32
    push r12
    push r13
    push r14
    call xhci_controller_init
    jc .ctl_done
    xor ebp, ebp                     ; ebp = port index
.port_loop:
    cmp ebp, r14d
    jae .ctl_done
    call fs_try_port
    jnc .ctl_done                    ; handled (or reported) - stop
    inc ebp
    jmp .port_loop
.ctl_done:
    pop r14
    pop r13
    pop r12
    cmp byte [fs_found], 0
    jne .done
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
    cmp byte [fs_found], 0
    jne .done
    mov rsi, fs_no_dev_msg
    call print_string
    mov al, ASCII_CR
    call print_char
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rbx
    ret

; --- Build the two forms of the filename cat is looking for, from the
; nul/space-terminated argument at rsi: the 11-byte 8.3 padded, uppercased
; name in fs_target_name (FAT12/16/32), and the plain uppercased name (no
; padding, dot kept) in fs_target_raw/fs_target_raw_len (exFAT). ---
fs_build_target_name:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    xor ebx, ebx
    lea rdi, [fs_target_raw]
.raw_loop:
    mov al, [rsi]
    or al, al
    jz .raw_done
    cmp al, ' '
    je .raw_done
    cmp ebx, 255
    jae .raw_done
    lea rdx, [fs_target_disp]
    mov [rdx + rbx], al
    cmp al, 'a'
    jb .raw_store
    cmp al, 'z'
    ja .raw_store
    sub al, 0x20
.raw_store:
    mov [rdi + rbx], al
    inc ebx
    inc rsi
    jmp .raw_loop
.raw_done:
    mov [fs_target_raw_len], ebx
    pop rsi
    lea rdi, [fs_target_name]
    mov ecx, 11
    mov al, ' '
.clear:
    mov [rdi], al
    inc rdi
    dec ecx
    jnz .clear
    lea rdi, [fs_target_name]
    xor ecx, ecx
    xor ebx, ebx                     ; case flags: 1=name-lower 2=name-upper 4=ext-lower 8=ext-upper
.name_loop:
    mov al, [rsi]
    or al, al
    jz .done
    cmp al, ' '
    je .done
    cmp al, '.'
    je .ext
    cmp ecx, 8
    jae .skip_char
    cmp al, 'a'
    jb .name_check_upper
    cmp al, 'z'
    ja .store
    or bl, 1
    sub al, 0x20
    jmp .store
.name_check_upper:
    cmp al, 'A'
    jb .store
    cmp al, 'Z'
    ja .store
    or bl, 2
.store:
    mov [rdi + rcx], al
    inc ecx
.skip_char:
    inc rsi
    jmp .name_loop
.ext:
    inc rsi
    xor ecx, ecx
.ext_loop:
    mov al, [rsi]
    or al, al
    jz .done
    cmp al, ' '
    je .done
    cmp ecx, 3
    jae .ext_skip
    cmp al, 'a'
    jb .ext_check_upper
    cmp al, 'z'
    ja .ext_store
    or bl, 4
    sub al, 0x20
    jmp .ext_store
.ext_check_upper:
    cmp al, 'A'
    jb .ext_store
    cmp al, 'Z'
    ja .ext_store
    or bl, 8
.ext_store:
    mov [rdi + 8 + rcx], al
    inc ecx
.ext_skip:
    inc rsi
    jmp .ext_loop
.done:
    mov byte [fs_target_case], 0
    test bl, 2                       ; name has an uppercase letter: leave as 8.3-upper
    jnz .no_name_lower
    test bl, 1
    jz .no_name_lower
    or byte [fs_target_case], 0x08
.no_name_lower:
    test bl, 8                       ; extension has an uppercase letter
    jnz .no_ext_lower
    test bl, 4
    jz .no_ext_lower
    or byte [fs_target_case], 0x10
.no_ext_lower:
    call fs_lfn_prepare
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; --- Decide whether the name needs a VFAT long-file-name (it doesn't fit a
; plain 8.3 short name). Sets fs_need_lfn and fs_lfn_count; when set, rewrites
; fs_target_name into a "NAME~1" 8.3 alias. Works off fs_target_disp (the
; original-case name of length fs_target_raw_len). ---
fs_lfn_prepare:
    mov byte [fs_need_lfn], 0
    mov dword [fs_lfn_count], 0
    mov eax, [fs_target_raw_len]
    test eax, eax
    jz .ret
    mov dword [fs_lfn_lastdot], -1
    xor ecx, ecx                     ; index
    xor ebx, ebx                     ; dot count
.scan:
    cmp ecx, [fs_target_raw_len]
    jae .scandone
    mov al, [fs_target_disp + rcx]
    cmp al, '.'
    jne .scannext
    mov [fs_lfn_lastdot], ecx
    inc ebx
.scannext:
    inc ecx
    jmp .scan
.scandone:
    mov eax, [fs_lfn_lastdot]
    cmp eax, -1
    jne .havedot
    mov eax, [fs_target_raw_len]
    mov [fs_lfn_namelen], eax
    mov dword [fs_lfn_extlen], 0
    jmp .decide
.havedot:
    mov [fs_lfn_namelen], eax
    mov ecx, [fs_target_raw_len]
    sub ecx, eax
    dec ecx
    mov [fs_lfn_extlen], ecx
.decide:
    cmp ebx, 1
    ja .need                         ; more than one dot
    cmp dword [fs_lfn_namelen], 8
    ja .need
    cmp dword [fs_lfn_extlen], 3
    ja .need
    cmp dword [fs_lfn_namelen], 0
    je .need                         ; leading-dot name (e.g. ".cfg")
    jmp .ret                         ; fits 8.3 - keep the plain short entry
.need:
    mov byte [fs_need_lfn], 1
    mov eax, [fs_target_raw_len]
    add eax, 12
    xor edx, edx
    mov ecx, 13
    div ecx
    mov [fs_lfn_count], eax           ; ceil(len/13)
    call fs_make_alias
.ret:
    ret

; --- Rewrite fs_target_name (already an uppercased, truncated 8.3 form) into
; a "NAME~1" alias: keep up to 6 name chars, append "~1", keep the extension.
; Clears fs_target_case (alias is uppercase). ---
fs_make_alias:
    xor ecx, ecx
.nl:
    cmp ecx, 8
    jae .have
    cmp byte [fs_target_name + rcx], ' '
    je .have
    inc ecx
    jmp .nl
.have:
    cmp ecx, 6
    jbe .cap
    mov ecx, 6
.cap:
    mov byte [fs_target_name + rcx], '~'
    inc ecx
    mov byte [fs_target_name + rcx], '1'
    inc ecx
.pad:
    cmp ecx, 8
    jae .done
    mov byte [fs_target_name + rcx], ' '
    inc ecx
    jmp .pad
.done:
    mov byte [fs_target_case], 0
    ret

; --- Find fs_target_name/fs_target_raw in the mounted volume's root
; directory (FAT12/16/32, exFAT or NTFS) and cat its contents. CF set on
; read error. ---
fs_cat_root:
    mov byte [fs_cat_found], 0
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
    cmp byte [fs_is_ntfs], 0
    jne .ntfs
    cmp byte [fs_is_exfat], 0
    jne .fat32
    cmp byte [fs_is_fat32], 0
    jne .fat32
    cmp byte [fs_in_subdir], 0       ; cd'd into a FAT12/16 subdir: cluster chain
    jne .fat32
    mov eax, [fs_root_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_root_secs]
    mov [fs_sec_count], eax
.f16_loop:
    cmp dword [fs_sec_count], 0
    je .search_done
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    call fs_cat_sector
    jc .search_done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .f16_loop
.fat32:
.clus_loop:
    mov eax, [fs_cur_cluster]
    cmp eax, 2
    jb .search_done
    cmp eax, 0x0FFFFFF8
    jae .search_done
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.f32_sec_loop:
    cmp dword [fs_sec_count], 0
    je .next_clus
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    cmp byte [fs_is_exfat], 0
    jne .call_exfat
    call fs_cat_sector
    jmp .call_done
.call_exfat:
    call fs_cat_sector_exfat
.call_done:
    jc .search_done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .f32_sec_loop
.next_clus:
    mov eax, [fs_cur_cluster]
    call fs_next_cluster
    jc .fail
    mov [fs_cur_cluster], eax
    jmp .clus_loop
.search_done:
    cmp byte [fs_cat_found], 0
    jne .found
    mov rsi, fs_cat_notfound_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.found:
    mov eax, [fs_cat_cluster]
    mov ecx, [fs_cat_size]
    call fs_cat_data
    clc
    ret
.fail:
    stc
    ret
.ntfs:
    call fs_ntfs_list                ; fs_action=1: matches by name instead of printing
    jc .fail
    cmp byte [fs_cat_found], 0
    jne .ntfs_found
    mov rsi, fs_cat_notfound_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.ntfs_found:
    call fs_cat_ntfs_data
    clc
    ret

; --- "echo <text> > <filename>" handler: writes fs_echo_ptr/fs_echo_len
; bytes to fs_target_name (FAT12/16/32) or fs_target_raw (exFAT, name capped
; at 15 chars) in the mounted volume's root directory. NTFS and FAT12
; (packed 12-bit entries, not handled here) are rejected to avoid
; corrupting the volume. Creates the file if it doesn't exist, or
; overwrites it in place (reusing its directory entry, allocating a fresh
; cluster) if it does. CF set on I/O error; "no free directory entry" is
; reported and treated as handled. ---
fs_echo_root:
    ; contiguous free directory entries needed by a create: LFN entries + 8.3
    mov dword [fs_echo_need_run], 1
    mov dword [fs_echo_run], 0
    cmp byte [fs_need_lfn], 0
    je .nr_done
    mov eax, [fs_lfn_count]
    inc eax
    mov [fs_echo_need_run], eax
.nr_done:
    cmp byte [fs_is_ntfs], 0
    jne .ntfs
    cmp byte [fs_is_exfat], 0
    jne .exfat
    cmp byte [fs_is_fat32], 0
    jne .fat32
    cmp byte [fs_is_fat16], 0
    je .unsupported
    cmp byte [fs_in_subdir], 0       ; cd'd into a FAT16 subdir: cluster chain
    jne .fat32
    mov byte [fs_echo_found], 0
    mov byte [fs_echo_have_slot], 0
    mov eax, [fs_root_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_root_secs]
    mov [fs_sec_count], eax
.f16_loop:
    cmp dword [fs_sec_count], 0
    je .search_done
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    call fs_echo_sector
    jc .search_done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .f16_loop
.fat32:
    mov byte [fs_echo_found], 0
    mov byte [fs_echo_have_slot], 0
.clus_loop:
    mov eax, [fs_cur_cluster]
    cmp eax, 2
    jb .search_done
    cmp eax, 0x0FFFFFF8
    jae .search_done
    mov [fs_echo_clus], eax
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.sec_loop:
    cmp dword [fs_sec_count], 0
    je .next_clus
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    call fs_echo_sector
    jc .search_done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .sec_loop
.next_clus:
    mov eax, [fs_echo_clus]
    call fs_next_cluster
    jc .fail
    mov [fs_cur_cluster], eax
    jmp .clus_loop
.exfat:
    ; name entries = ceil(len / 15); total set = 2 + name entries
    mov eax, [fs_target_raw_len]
    add eax, 14
    xor edx, edx
    mov ecx, 15
    div ecx                          ; eax = ceil(len/15)
    test eax, eax
    jnz .exfat_have_entries
    mov eax, 1                        ; at least one name entry (empty name edge case)
.exfat_have_entries:
    mov [fs_ex_name_entries], eax
    add eax, 2
    mov [fs_ex_set_entries], eax
    mov eax, [fs_cur_cluster]
    mov [fs_ex_root_clus], eax       ; current dir start (root, or cwd after cd)
    mov eax, [fs_ex_rootdir_clus]    ; the bitmap entry only lives in the root
    mov [fs_cur_cluster], eax
    call fs_exfat_find_bitmap
    mov eax, [fs_ex_root_clus]
    mov [fs_cur_cluster], eax
    mov byte [fs_echo_found], 0
    mov byte [fs_echo_have_slot], 0
    mov dword [fs_echo_ex_run], 0
.exfat_clus_loop:
    mov eax, [fs_cur_cluster]
    cmp eax, 2
    jb .search_done
    cmp eax, 0x0FFFFFF8
    jae .search_done
    mov [fs_echo_clus], eax
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.exfat_sec_loop:
    cmp dword [fs_sec_count], 0
    je .exfat_next_clus
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    call fs_echo_sector_exfat
    jc .search_done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .exfat_sec_loop
.exfat_next_clus:
    mov eax, [fs_echo_clus]
    shr eax, 7
    add eax, [fs_fat_lba]
    cmp eax, [fs_fat_cached]
    je .exfat_cached
    mov [fs_fat_cached], eax
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .exfat_cached
    mov dword [fs_fat_cached], 0xFFFFFFFF
    jmp .fail
.exfat_cached:
    mov eax, [fs_echo_clus]
    and eax, 127
    mov eax, [FS_FAT_BUF + rax*4]
    mov [fs_cur_cluster], eax
    jmp .exfat_clus_loop
.search_done:
    cmp byte [fs_echo_found], 0
    jne .have_target
    cmp byte [fs_echo_have_slot], 0
    jne .have_target
    mov rsi, fs_echo_nospace_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.have_target:
    cmp byte [fs_is_exfat], 0
    je .have_target_fat
    call fs_echo_alloc_exfat
    jc .fail
    call fs_echo_write_data
    jc .fail
    call fs_echo_write_entry_exfat
    jc .fail
    clc
    ret
.have_target_fat:
    call fs_echo_alloc
    jc .fail
    call fs_echo_write_data
    jc .fail
    ; overwrite of an existing file just updates its 8.3 entry in place
    ; (any pre-existing LFN entries stay valid); a create with a long name
    ; lays down the full LFN + 8.3 set at the free run.
    cmp byte [fs_echo_found], 0
    jne .fat_short
    cmp byte [fs_need_lfn], 0
    jne .fat_lfn
.fat_short:
    call fs_echo_write_entry
    jc .fail
    clc
    ret
.fat_lfn:
    call fs_echo_write_lfn_set
    jc .fail
    clc
    ret
.fail:
    stc
    ret
.ntfs:
    call fs_echo_ntfs
    clc
    ret
.unsupported:
    mov rsi, fs_echo_unsupported_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret

; --- Walk the root directory cluster chain (fs_cur_cluster) looking for the
; exFAT allocation bitmap entry (type 0x81), recording its first cluster in
; fs_ex_bitmap_clus (0 if not found). Mutates fs_cur_cluster/fs_fat_cached
; like the other root-directory walkers - caller must save/restore
; fs_cur_cluster around this call. ---
fs_exfat_find_bitmap:
    mov dword [fs_ex_bitmap_clus], 0
.clus_loop:
    mov eax, [fs_cur_cluster]
    cmp eax, 2
    jb .done
    cmp eax, 0x0FFFFFF8
    jae .done
    mov [fs_echo_clus], eax
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.sec_loop:
    cmp dword [fs_sec_count], 0
    je .next_clus
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .done
    xor ecx, ecx
.ent_loop:
    cmp ecx, 512
    jae .ent_done
    mov esi, FS_SECTOR_BUF
    add esi, ecx
    mov al, [rsi]
    test al, al
    jz .done
    cmp al, 0x81
    jne .ent_next
    mov eax, [rsi + 20]
    mov [fs_ex_bitmap_clus], eax
    jmp .done
.ent_next:
    add ecx, 32
    jmp .ent_loop
.ent_done:
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .sec_loop
.next_clus:
    mov eax, [fs_echo_clus]
    shr eax, 7
    add eax, [fs_fat_lba]
    cmp eax, [fs_fat_cached]
    je .cached
    mov [fs_fat_cached], eax
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .cached
    mov dword [fs_fat_cached], 0xFFFFFFFF
    jmp .done
.cached:
    mov eax, [fs_echo_clus]
    and eax, 127
    mov eax, [FS_FAT_BUF + rax*4]
    mov [fs_cur_cluster], eax
    jmp .clus_loop
.done:
    ret

; --- Scan the exFAT directory entries in FS_SECTOR_BUF for fs_target_raw
; (name match, matching fs_cat_sector_exfat) and, in the same pass, a run of
; 3 contiguous free/deleted entries (create target: file + stream + one
; name entry, name capped at 15 chars by the caller). CF set to stop the
; scan: an exact match (fs_echo_found=1) or the 0x00 end marker. ---
fs_echo_sector_exfat:
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    mov al, [rsi]
    test al, al
    jz .end_marker
    test al, 0x80
    jnz .inuse
    cmp dword [fs_echo_ex_run], 0
    jne .run_have_start
    mov eax, [fs_cur_lba]
    mov [fs_echo_ex_run_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_echo_ex_run_off], eax
.run_have_start:
    inc dword [fs_echo_ex_run]
    mov eax, [fs_echo_ex_run]
    cmp eax, [fs_ex_set_entries]
    jb .skip
    cmp byte [fs_echo_have_slot], 0
    jne .skip
    mov byte [fs_echo_have_slot], 1
    mov eax, [fs_echo_ex_run_lba]
    mov [fs_echo_lba], eax
    mov eax, [fs_echo_ex_run_off]
    mov [fs_echo_off], eax
    jmp .skip
.inuse:
    mov dword [fs_echo_ex_run], 0
    cmp al, 0x85
    je .ex_file
    cmp byte [fs_ex_active], 0
    je .skip
    cmp al, 0xC1                     ; file name entry
    jne .ex_sec_done
    xor ecx, ecx
.ex_name_loop:
    cmp ecx, 15
    jae .ex_sec_done
    mov ax, [rsi + 2 + rcx*2]
    test ax, ax
    jz .ex_sec_done
    cmp ax, 0x7F
    jbe .ex_ch_ok
    mov al, '?'
.ex_ch_ok:
    cmp al, 'a'
    jb .ex_ch_store
    cmp al, 'z'
    ja .ex_ch_store
    sub al, 0x20
.ex_ch_store:
    mov ebx, [fs_name_len]
    cmp ebx, 255
    jae .ex_name_skip
    lea rdi, [fs_ex_name_buf]
    mov [rdi + rbx], al
.ex_name_skip:
    inc dword [fs_name_len]
    inc ecx
    jmp .ex_name_loop
.ex_file:
    mov eax, [fs_entry_off]
    mov [fs_echo_ex_cand_off], eax
    mov al, [rsi + 1]                 ; secondary count
    mov [fs_ex_nrem], al
    mov byte [fs_ex_active], 1
    mov dword [fs_name_len], 0
    jmp .skip
.ex_sec_done:
    dec byte [fs_ex_nrem]
    jnz .skip
    mov byte [fs_ex_active], 0
    mov eax, [fs_name_len]
    cmp eax, [fs_target_raw_len]
    jne .skip
    test eax, eax
    jz .name_match
    push rcx
    push rsi
    push rdi
    lea rsi, [fs_ex_name_buf]
    lea rdi, [fs_target_raw]
    mov ecx, eax
    repe cmpsb
    pop rdi
    pop rsi
    pop rcx
    jne .skip
.name_match:
    mov eax, [fs_cur_lba]
    mov [fs_echo_lba], eax
    mov eax, [fs_echo_ex_cand_off]
    mov [fs_echo_off], eax
    mov byte [fs_echo_found], 1
    stc
    ret
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.not_end:
    clc
    ret
.end_marker:
    cmp byte [fs_echo_have_slot], 0
    jne .stop
    mov eax, [fs_cur_lba]
    mov [fs_echo_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_echo_off], eax
    mov byte [fs_echo_have_slot], 1
.stop:
    stc
    ret

; --- Allocate one free exFAT cluster for fs_echo_len bytes (0 bytes ->
; cluster 0) by scanning the allocation bitmap's first cluster only (bounded
; scan, same rationale as fs_echo_alloc's FAT scan cap - sufficient for
; typical small volumes). Sets the bit, marks the FAT entry end-of-chain
; (this driver always walks exFAT files via the FAT chain, ignoring
; NoFatChain). Result in fs_echo_cluster. CF set on error/no space. ---
; --- Set a 32-bit FAT entry (exFAT / FAT32): eax = cluster, edx = value.
; Read-modify-write the containing FAT sector; invalidates fs_fat_cached.
; Uses memory scratch (no register survival across USB I/O). CF on error. ---
fs_exfat_fat_set:
    mov [fs_fatset_clus], eax
    mov [fs_fatset_val], edx
    mov ecx, eax
    shr ecx, 7                        ; 128 32-bit entries per sector
    add ecx, [fs_fat_lba]
    mov [fs_fatset_lba], ecx
    mov eax, ecx
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jc .err
    mov dword [fs_fat_cached], 0xFFFFFFFF
    mov eax, [fs_fatset_clus]
    and eax, 127
    mov edx, [fs_fatset_val]
    mov [FS_FAT_BUF + rax*4], edx
    mov eax, [fs_fatset_lba]
    mov edi, FS_FAT_BUF
    call fs_write_sector
    jc .err
    clc
    ret
.err:
    stc
    ret

fs_echo_alloc_exfat:
    mov dword [fs_echo_cluster], 0
    mov dword [fs_echo_prev_clus], 0
    mov eax, [fs_echo_len]
    test eax, eax
    jz .done
    ; nclus = ceil(len / bytes-per-cluster)
    mov ecx, [fs_spc]
    shl ecx, 9
    mov eax, [fs_echo_len]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [fs_echo_nclus], eax
    cmp dword [fs_ex_bitmap_clus], 0
    je .nospace
.alloc_one:
    ; rescan the bitmap from the start; bits we already set are now on disk,
    ; so each pass finds the next still-free cluster (N is tiny).
    mov eax, [fs_ex_bitmap_clus]
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
    mov dword [fs_cat_size], 0        ; global bit index
.sec_loop:
    cmp dword [fs_sec_count], 0
    je .nospace
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    xor ecx, ecx
.byte_loop:
    cmp ecx, 512
    jae .sec_next
    mov eax, [fs_cat_size]
    cmp eax, [fs_ex_cluster_count]
    jae .nospace
    movzx edx, byte [FS_SECTOR_BUF + rcx]
    cmp dl, 0xFF
    je .byte_full
    xor ebx, ebx
.bit_loop:
    cmp ebx, 8
    jae .byte_full
    mov eax, [fs_cat_size]
    add eax, ebx
    cmp eax, [fs_ex_cluster_count]
    jae .nospace
    bt edx, ebx
    jc .bit_next
    jmp .found_bit
.bit_next:
    inc ebx
    jmp .bit_loop
.byte_full:
    add dword [fs_cat_size], 8
    inc ecx
    jmp .byte_loop
.sec_next:
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .sec_loop
.found_bit:
    mov eax, [fs_cat_size]
    add eax, ebx
    add eax, 2
    mov [fs_echo_clus], eax           ; newly allocated cluster
    bts edx, ebx
    mov [FS_SECTOR_BUF + rcx], dl
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
    ; FAT[new] = EOC
    mov eax, [fs_echo_clus]
    mov edx, 0x0FFFFFFF
    call fs_exfat_fat_set
    jc .fail
    ; link previous cluster to this one, or record it as the first
    cmp dword [fs_echo_prev_clus], 0
    jne .link_prev
    mov eax, [fs_echo_clus]
    mov [fs_echo_cluster], eax
    jmp .after_link
.link_prev:
    mov eax, [fs_echo_prev_clus]
    mov edx, [fs_echo_clus]
    call fs_exfat_fat_set
    jc .fail
.after_link:
    mov eax, [fs_echo_clus]
    mov [fs_echo_prev_clus], eax
    dec dword [fs_echo_nclus]
    jnz .alloc_one
    clc
    ret
.done:
    clc
    ret
.nospace:
    mov rsi, fs_echo_nospace_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    stc
    ret
.fail:
    stc
    ret

; --- Hash fs_target_raw[0..fs_target_raw_len) as exFAT's UTF-16LE name
; hash (each raw ASCII byte treated as a UTF-16 char with a zero high
; byte). Result in ax. ---
fs_exfat_name_hash:
    xor edx, edx
    xor ecx, ecx
    lea rsi, [fs_target_raw]
    mov ebx, [fs_target_raw_len]
.loop:
    cmp ecx, ebx
    jae .done
    movzx eax, byte [rsi + rcx]
    mov r8d, edx
    and r8d, 1
    shr edx, 1
    shl r8d, 15
    or edx, r8d
    add edx, eax
    and edx, 0xFFFF
    mov r8d, edx
    and r8d, 1
    shr edx, 1
    shl r8d, 15
    or edx, r8d
    and edx, 0xFFFF
    inc ecx
    jmp .loop
.done:
    mov ax, dx
    ret

; --- Write the 3-entry exFAT directory entry set (file/stream/name) for
; fs_target_raw/fs_echo_cluster/fs_echo_len at fs_echo_lba/off, computing
; the SetChecksum field per the exFAT spec. Entries may straddle a sector
; boundary (one read-modify-write per entry). CF set on I/O error. ---
fs_echo_write_entry_exfat:
    lea rdi, [fs_echo_ex_set]
    mov ecx, 640
    xor eax, eax
    rep stosb
    lea rdi, [fs_echo_ex_set]
    mov byte [rdi + 0], 0x85
    mov eax, [fs_ex_set_entries]      ; SecondaryCount = stream + name entries
    dec eax
    mov [rdi + 1], al
    mov word [rdi + 4], 0x0020        ; ATTR_ARCHIVE
    mov dword [rdi + 8], 0x00210000   ; CreateTimestamp: 1980-01-01 00:00:00
    mov dword [rdi + 12], 0x00210000  ; LastModifiedTimestamp
    mov dword [rdi + 16], 0x00210000  ; LastAccessedTimestamp
    lea rdi, [fs_echo_ex_set + 32]
    mov byte [rdi + 0], 0xC0
    mov byte [rdi + 1], 0x01          ; AllocationPossible (FAT chain; NoFatChain clear)
    mov eax, [fs_target_raw_len]
    mov [rdi + 3], al
    call fs_exfat_name_hash
    mov [rdi + 4], ax
    mov eax, [fs_echo_len]
    mov [rdi + 8], eax                ; ValidDataLength (low dword)
    mov eax, [fs_echo_cluster]
    mov [rdi + 20], eax
    mov eax, [fs_echo_len]
    mov [rdi + 24], eax                ; DataLength (low dword)
    ; --- name entries: 15 UTF-16 chars each, source fs_target_disp ---
    xor ebx, ebx                       ; ebx = char index into the name
.name_ent_loop:
    mov eax, ebx
    cmp eax, [fs_target_raw_len]
    jae .name_copy_done
    ; entry base = fs_echo_ex_set + 64 + (ebx/15)*32
    mov eax, ebx
    xor edx, edx
    mov ecx, 15
    div ecx                            ; eax = entry index, edx = char-in-entry
    shl eax, 5                         ; *32
    lea rdi, [fs_echo_ex_set + 64]
    add rdi, rax
    mov byte [rdi + 0], 0xC1
    lea rsi, [fs_target_disp]
    mov al, [rsi + rbx]
    mov [rdi + 2 + rdx*2], al           ; UTF-16LE low byte
    mov byte [rdi + 2 + rdx*2 + 1], 0   ; high byte = 0
    inc ebx
    jmp .name_ent_loop
.name_copy_done:
    ; checksum spans every entry byte (set_entries*32), skipping bytes 2,3 of entry 0
    mov eax, [fs_ex_set_entries]
    shl eax, 5
    mov [fs_echo_ex_off], eax           ; reuse ex_off as byte-span scratch
    xor edx, edx
    xor ecx, ecx
    lea rsi, [fs_echo_ex_set]
.chk_loop:
    cmp ecx, [fs_echo_ex_off]
    jae .chk_done
    cmp ecx, 2
    je .chk_skip
    cmp ecx, 3
    je .chk_skip
    movzx eax, byte [rsi + rcx]
    mov ebx, edx
    and ebx, 1
    shr edx, 1
    shl ebx, 15
    or edx, ebx
    add edx, eax
    and edx, 0xFFFF
.chk_skip:
    inc ecx
    jmp .chk_loop
.chk_done:
    lea rdi, [fs_echo_ex_set]
    mov [rdi + 2], dx
    mov dword [fs_echo_ex_i], 0
.write_loop:
    mov eax, [fs_echo_ex_i]
    cmp eax, [fs_ex_set_entries]
    jae .write_done
    mov eax, [fs_echo_off]
    shr eax, 5
    add eax, [fs_echo_ex_i]
    mov ecx, eax
    and ecx, 15
    shl ecx, 5
    mov [fs_echo_ex_off], ecx
    shr eax, 4
    add eax, [fs_echo_lba]
    mov [fs_echo_ex_lba], eax
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    mov eax, [fs_echo_ex_i]
    shl eax, 5
    lea rsi, [fs_echo_ex_set]
    add rsi, rax
    mov eax, [fs_echo_ex_off]
    lea rdi, [FS_SECTOR_BUF]
    add rdi, rax
    mov ecx, 32
    rep movsb
    mov eax, [fs_echo_ex_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
    inc dword [fs_echo_ex_i]
    jmp .write_loop
.write_done:
    clc
    ret
.fail:
    stc
    ret

; --- Scan the 16 directory entries in FS_SECTOR_BUF for fs_target_name
; (overwrite target) and, in the same pass, a run of fs_echo_need_run
; contiguous free (0xE5) entries (create target, recorded in fs_echo_lba/off
; once fs_echo_have_slot is set). The free run persists across sectors via
; fs_echo_run (reset by the caller before the scan). CF set to stop the
; scan: an exact name match (fs_echo_found=1) or the 0x00 end marker. ---
fs_echo_sector:
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    mov al, [rsi]
    test al, al
    jz .end_marker
    cmp al, 0xE5
    je .free_slot
    mov dword [fs_echo_run], 0        ; in-use entry breaks the free run
    mov al, [rsi + 11]
    test al, 0x08                    ; volume label / LFN entry
    jnz .skip
    push rcx
    push rdi
    push rsi
    lea rdi, [fs_target_name]
    mov rcx, 11
    repe cmpsb
    pop rsi
    pop rdi
    pop rcx
    jne .skip
    mov al, [rsi + 11]
    test al, 0x10                    ; directory: echo doesn't support this
    jnz .skip
    mov eax, [fs_cur_lba]
    mov [fs_echo_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_echo_off], eax
    mov byte [fs_echo_found], 1
    stc
    ret
.free_slot:
    cmp dword [fs_echo_run], 0
    jne .fr_have
    mov eax, [fs_cur_lba]             ; remember where this run started
    mov [fs_echo_run_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_echo_run_off], eax
.fr_have:
    inc dword [fs_echo_run]
    cmp byte [fs_echo_have_slot], 0
    jne .skip
    mov eax, [fs_echo_run]
    cmp eax, [fs_echo_need_run]
    jb .skip
    mov eax, [fs_echo_run_lba]
    mov [fs_echo_lba], eax
    mov eax, [fs_echo_run_off]
    mov [fs_echo_off], eax
    mov byte [fs_echo_have_slot], 1
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.not_end:
    clc
    ret
.end_marker:
    ; end of directory: entries from here on are free. Start the run here if
    ; none is in progress; the caller writes need_run contiguous entries.
    cmp byte [fs_echo_have_slot], 0
    jne .stop
    cmp dword [fs_echo_run], 0
    jne .use_run
    mov eax, [fs_cur_lba]
    mov [fs_echo_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_echo_off], eax
    mov byte [fs_echo_have_slot], 1
    jmp .stop
.use_run:
    mov eax, [fs_echo_run_lba]
    mov [fs_echo_lba], eax
    mov eax, [fs_echo_run_off]
    mov [fs_echo_off], eax
    mov byte [fs_echo_have_slot], 1
.stop:
    stc
    ret

; --- Set a FAT entry (dual-width: FAT16 2-byte, FAT32 4-byte): eax = cluster,
; edx = value (FAT16 stores the low word). Read-modify-write the containing
; FAT sector; invalidates fs_fat_cached. Memory scratch, no register survival
; across USB I/O. CF on error. ---
fs_fat_set:
    mov [fs_fatset_clus], eax
    mov [fs_fatset_val], edx
    mov ecx, eax
    cmp byte [fs_is_fat16], 0
    jne .f16
    shr ecx, 7
    jmp .have
.f16:
    shr ecx, 8
.have:
    add ecx, [fs_fat_lba]
    mov [fs_fatset_lba], ecx
    mov eax, ecx
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jc .err
    mov dword [fs_fat_cached], 0xFFFFFFFF
    mov eax, [fs_fatset_clus]
    mov edx, [fs_fatset_val]
    cmp byte [fs_is_fat16], 0
    jne .w16
    and eax, 127
    mov [FS_FAT_BUF + rax*4], edx
    jmp .flush
.w16:
    and eax, 255
    mov [FS_FAT_BUF + rax*2], dx
.flush:
    mov eax, [fs_fatset_lba]
    mov edi, FS_FAT_BUF
    call fs_write_sector
    jc .err
    clc
    ret
.err:
    stc
    ret

; --- Allocate a FAT32/16 cluster chain for fs_echo_len bytes (0 bytes ->
; cluster 0, no allocation). nclus = ceil(len / bytes-per-cluster). Each pass
; rescans the FAT from cluster 2 for the first free (0) entry (already-marked
; clusters are non-zero, so successive passes find the next free one), marks
; it end-of-chain, and links the previous cluster to it. First cluster lands
; in fs_echo_cluster. CF set on read/write error or "volume full". ---
fs_echo_alloc:
    mov dword [fs_echo_cluster], 0
    mov dword [fs_echo_prev_clus], 0
    mov eax, [fs_echo_len]
    test eax, eax
    jz .done
    mov ecx, [fs_spc]
    shl ecx, 9                        ; bytes/cluster
    mov eax, [fs_echo_len]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [fs_echo_nclus], eax          ; number of clusters to allocate
.alloc_one:
    mov dword [fs_cat_size], 2        ; candidate cluster
    mov dword [fs_cat_remain], 2000000 ; scan cap: bounded, no runaway
.scan:
    cmp dword [fs_cat_remain], 0
    je .nospace
    dec dword [fs_cat_remain]
    mov eax, [fs_cat_size]
    mov ecx, eax
    cmp byte [fs_is_fat16], 0
    jne .idx16
    shr ecx, 7                        ; 128 32-bit entries/sector (FAT32)
    jmp .idx_have
.idx16:
    shr ecx, 8                        ; 256 16-bit entries/sector (FAT16)
.idx_have:
    add ecx, [fs_fat_lba]
    cmp ecx, [fs_fat_cached]
    je .cached
    mov [fs_fat_cached], ecx
    mov eax, ecx
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .cached
    mov dword [fs_fat_cached], 0xFFFFFFFF
    jmp .fail
.cached:
    cmp byte [fs_is_fat16], 0
    jne .cached16
    mov eax, [fs_cat_size]
    and eax, 127
    cmp dword [FS_FAT_BUF + rax*4], 0
    jne .next
    jmp .mark
.cached16:
    mov eax, [fs_cat_size]
    and eax, 255
    cmp word [FS_FAT_BUF + rax*2], 0
    jne .next
.mark:
    ; found a free cluster in fs_cat_size: mark EOC, then link the chain
    mov eax, [fs_cat_size]
    mov [fs_echo_clus], eax
    mov edx, 0x0FFFFFFF               ; fs_fat_set stores low word for FAT16
    call fs_fat_set
    jc .fail
    cmp dword [fs_echo_prev_clus], 0
    jne .link
    mov eax, [fs_echo_clus]
    mov [fs_echo_cluster], eax        ; first cluster of the file
    jmp .after
.link:
    mov eax, [fs_echo_prev_clus]
    mov edx, [fs_echo_clus]
    call fs_fat_set
    jc .fail
.after:
    mov eax, [fs_echo_clus]
    mov [fs_echo_prev_clus], eax
    dec dword [fs_echo_nclus]
    jnz .alloc_one
    clc
    ret
.next:
    inc dword [fs_cat_size]
    jmp .scan
.done:
    clc
    ret
.nospace:
    mov rsi, fs_echo_nospace_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    stc
    ret
.fail:
    stc
    ret

; --- Advance fs_echo_clus to the next cluster in the FAT chain (dual-width:
; FAT16 = 2-byte / 256 per sector, FAT32/exFAT = 4-byte / 128 per sector).
; CF set on I/O error or end-of-chain. Uses FS_FAT_BUF / fs_fat_cached. ---
fs_echo_next_cluster:
    cmp byte [fs_is_fat16], 0
    jne .f16
    mov eax, [fs_echo_clus]
    mov ecx, eax
    shr ecx, 7
    add ecx, [fs_fat_lba]
    cmp ecx, [fs_fat_cached]
    je .c32
    mov [fs_fat_cached], ecx
    mov eax, ecx
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .c32
    mov dword [fs_fat_cached], 0xFFFFFFFF
    stc
    ret
.c32:
    mov eax, [fs_echo_clus]
    and eax, 127
    mov eax, [FS_FAT_BUF + rax*4]
    and eax, 0x0FFFFFFF
    mov [fs_echo_clus], eax
    cmp eax, 2
    jb .end
    cmp eax, 0x0FFFFFF8
    jae .end
    clc
    ret
.f16:
    mov eax, [fs_echo_clus]
    mov ecx, eax
    shr ecx, 8
    add ecx, [fs_fat_lba]
    cmp ecx, [fs_fat_cached]
    je .c16
    mov [fs_fat_cached], ecx
    mov eax, ecx
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .c16
    mov dword [fs_fat_cached], 0xFFFFFFFF
    stc
    ret
.c16:
    mov eax, [fs_echo_clus]
    and eax, 255
    movzx eax, word [FS_FAT_BUF + rax*2]
    mov [fs_echo_clus], eax
    cmp eax, 2
    jb .end
    cmp eax, 0xFFF8
    jae .end
    clc
    ret
.end:
    stc
    ret

; --- Write fs_echo_ptr/fs_echo_len bytes across the cluster chain starting
; at fs_echo_cluster (0 bytes -> nothing to do), zero-padding the final
; partial sector. Walks spc sectors per cluster and follows the FAT chain
; via fs_echo_next_cluster. CF set on write error. ---
fs_echo_write_data:
    mov eax, [fs_echo_len]
    test eax, eax
    jz .done
    mov dword [fs_echo_written], 0
    mov eax, [fs_echo_cluster]
    mov [fs_echo_clus], eax
.clus_loop:
    mov eax, [fs_echo_clus]
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov dword [fs_sec_count], 0        ; sector index within this cluster
.sec_loop:
    mov eax, [fs_echo_written]
    cmp eax, [fs_echo_len]
    jae .done                         ; all bytes flushed
    mov eax, [fs_sec_count]
    cmp eax, [fs_spc]
    jae .next_clus                    ; cluster exhausted, follow chain
    ; chunk = min(remaining, 512)
    mov eax, [fs_echo_len]
    sub eax, [fs_echo_written]
    cmp eax, 512
    jbe .have_chunk
    mov eax, 512
.have_chunk:
    mov [fs_echo_chunk], eax
    mov rsi, [fs_echo_ptr]
    mov eax, [fs_echo_written]
    add rsi, rax
    lea rdi, [FS_SECTOR_BUF]
    mov ecx, [fs_echo_chunk]
    rep movsb
    mov ecx, 512
    sub ecx, [fs_echo_chunk]
    jz .no_pad
    xor al, al
    rep stosb
.no_pad:
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
    mov eax, [fs_echo_chunk]
    add [fs_echo_written], eax
    inc dword [fs_cur_lba]
    inc dword [fs_sec_count]
    jmp .sec_loop
.next_clus:
    call fs_echo_next_cluster
    jc .fail
    jmp .clus_loop
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Write the 32-byte directory entry (fs_target_name, fs_echo_cluster,
; fs_echo_len) at fs_echo_lba/off. CF set on read/write error. ---
fs_echo_write_entry:
    mov eax, [fs_echo_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    mov eax, [fs_echo_off]
    lea rdi, [FS_SECTOR_BUF + rax]
    lea rsi, [fs_target_name]
    mov ecx, 11
    rep movsb
    mov byte [rdi], 0x20              ; ATTR_ARCHIVE
    mov ecx, 16
    xor eax, eax
    rep stosb                         ; reserved/time/date/cluster-hi fields
    mov eax, [fs_echo_off]
    lea rdi, [FS_SECTOR_BUF + rax]
    mov al, [fs_target_case]
    mov [rdi + 12], al                ; NT reserved byte: lowercase 8.3 flags
    mov eax, [fs_echo_cluster]
    mov ecx, eax
    shr ecx, 16
    mov [rdi + 20], cx                ; first cluster, high word
    mov [rdi + 26], ax                ; first cluster, low word
    mov eax, [fs_echo_len]
    mov [rdi + 28], eax                ; file size
    mov eax, [fs_echo_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
    clc
    ret
.fail:
    stc
    ret

; --- 8.3 short-name checksum (VFAT) over fs_target_name (11 bytes). Result
; in fs_lfn_sum. ---
fs_lfn_checksum:
    xor eax, eax
    xor ecx, ecx
.l:
    cmp ecx, 11
    jae .d
    movzx edx, byte [fs_target_name + rcx]
    mov ebx, eax
    and ebx, 1
    shl ebx, 7
    shr eax, 1
    or eax, ebx
    add eax, edx
    and eax, 0xFF
    inc ecx
    jmp .l
.d:
    mov [fs_lfn_sum], al
    ret

; --- Write a full VFAT long-name set: fs_lfn_count 0x0F entries (in reverse
; sequence order) followed by the 8.3 alias entry, starting at the free run
; fs_echo_lba/off. The set is staged in FS_MFT_BUF (unused on FAT volumes),
; then written entry-by-entry with a read-modify-write that follows sector
; boundaries. CF set on I/O error. ---
fs_echo_write_lfn_set:
    call fs_lfn_checksum
    ; zero (count+1)*32 bytes of the staging buffer
    mov eax, [fs_lfn_count]
    inc eax
    shl eax, 5
    mov ecx, eax
    lea rdi, [FS_MFT_BUF]
    xor eax, eax
    rep stosb
    mov dword [fs_lfn_i], 0           ; buffer entry index j (0..count-1)
.build_loop:
    mov eax, [fs_lfn_i]
    cmp eax, [fs_lfn_count]
    jae .build_short
    mov ebx, [fs_lfn_count]
    sub ebx, eax                      ; ebx = sequence number (count..1)
    mov edx, eax
    shl edx, 5
    lea rdi, [FS_MFT_BUF]
    add rdi, rdx                      ; rdi = staging entry
    mov al, bl
    cmp ebx, [fs_lfn_count]
    jne .noflag
    or al, 0x40                       ; last logical entry marker
.noflag:
    mov [rdi + 0], al
    mov byte [rdi + 11], 0x0F
    mov byte [rdi + 12], 0
    mov al, [fs_lfn_sum]
    mov [rdi + 13], al
    mov ecx, ebx
    dec ecx
    imul ecx, ecx, 13
    mov [fs_lfn_base], ecx            ; source base index = (seq-1)*13
    xor ebx, ebx                      ; char index 0..12
.char_loop:
    cmp ebx, 13
    jae .char_done
    movzx ecx, byte [fs_lfn_off + rbx]
    mov eax, [fs_lfn_base]
    add eax, ebx                      ; source char index
    cmp eax, [fs_target_raw_len]
    jb .real
    je .term
    mov word [rdi + rcx], 0xFFFF       ; past end -> padding
    jmp .char_next
.term:
    mov word [rdi + rcx], 0x0000       ; terminator
    jmp .char_next
.real:
    movzx edx, byte [fs_target_disp + rax]
    mov [rdi + rcx], dx                 ; UTF-16LE (high byte 0 via movzx)
.char_next:
    inc ebx
    jmp .char_loop
.char_done:
    inc dword [fs_lfn_i]
    jmp .build_loop
.build_short:
    ; 8.3 alias entry at staging index = count
    mov eax, [fs_lfn_count]
    shl eax, 5
    lea rdi, [FS_MFT_BUF]
    add rdi, rax
    lea rsi, [fs_target_name]
    mov ecx, 11
    rep movsb
    mov byte [rdi], 0x20               ; ATTR_ARCHIVE (rdi now at +11)
    mov eax, [fs_lfn_count]
    shl eax, 5
    lea rdi, [FS_MFT_BUF]
    add rdi, rax                       ; rdi = 8.3 entry base
    mov eax, [fs_echo_cluster]
    mov ecx, eax
    shr ecx, 16
    mov [rdi + 20], cx                 ; first cluster high
    mov [rdi + 26], ax                 ; first cluster low
    mov eax, [fs_echo_len]
    mov [rdi + 28], eax                ; size
    ; --- write (count+1) entries to disk from fs_echo_lba/off ---
    mov dword [fs_echo_ex_i], 0
.write_loop:
    mov eax, [fs_lfn_count]
    inc eax
    mov ecx, [fs_echo_ex_i]
    cmp ecx, eax
    jae .write_done
    mov eax, [fs_echo_off]
    shr eax, 5                         ; entry index within its sector
    add eax, [fs_echo_ex_i]
    mov ecx, eax
    and ecx, 15
    shl ecx, 5
    mov [fs_echo_ex_off], ecx
    shr eax, 4
    add eax, [fs_echo_lba]
    mov [fs_echo_ex_lba], eax
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    mov eax, [fs_echo_ex_i]
    shl eax, 5
    lea rsi, [FS_MFT_BUF]
    add rsi, rax
    mov eax, [fs_echo_ex_off]
    lea rdi, [FS_SECTOR_BUF]
    add rdi, rax
    mov ecx, 32
    rep movsb
    mov eax, [fs_echo_ex_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
    inc dword [fs_echo_ex_i]
    jmp .write_loop
.write_done:
    clc
    ret
.fail:
    stc
    ret

; --- Scan the 16 directory entries in FS_SECTOR_BUF for fs_target_name.
; CF set to stop the caller's scan, either because a matching file entry
; was found (fs_cat_found=1, fs_cat_cluster/fs_cat_size filled) or the
; 0x00 end-of-directory marker was hit (fs_cat_found stays 0). ---
fs_cat_sector:
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    mov al, [rsi]
    test al, al
    jz .end_marker
    cmp al, 0xE5                     ; deleted
    je .del
    mov al, [rsi + 11]
    cmp al, 0x0F                     ; long-file-name entry
    je .lfn
    test al, 0x08                    ; volume label
    jnz .skip_reset
    ; long-name match takes priority when an LFN set was accumulated
    cmp byte [fs_lfn_have], 0
    je .try_short
    call fs_lfn_match
    test al, al
    jnz .matched
    jmp .skip_reset
.try_short:
    push rcx
    push rdi
    push rsi
    lea rdi, [fs_target_name]
    mov rcx, 11
    repe cmpsb
    pop rsi
    pop rdi
    pop rcx
    jne .skip_reset
.matched:
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
    mov al, [rsi + 11]
    test al, 0x10
    jnz .m_dir
    cmp byte [fs_want_dir], 0        ; file: only a cat/rm-style match wants it
    jne .skip
    jmp .m_take
.m_dir:
    cmp byte [fs_want_dir], 0        ; directory: only a cd match wants it
    je .skip
.m_take:
    movzx eax, word [rsi + 26]       ; first cluster, low word
    mov ecx, eax
    movzx eax, word [rsi + 20]       ; first cluster, high word (FAT32)
    shl eax, 16
    or eax, ecx
    mov [fs_cat_cluster], eax
    mov eax, [rsi + 28]              ; file size
    mov [fs_cat_size], eax
    mov byte [fs_cat_found], 1
    stc
    ret
.lfn:
    call fs_lfn_accumulate
    jmp .skip
.del:
    mov byte [fs_lfn_have], 0        ; deleted entry breaks the LFN chain
    mov dword [fs_lfn_maxlen], 0
    jmp .skip
.skip_reset:
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.not_end:
    clc
    ret
.end_marker:
    stc
    ret

; --- Scan the exFAT directory entries in FS_SECTOR_BUF for fs_target_raw
; (accumulating each file's UTF-16 name, ASCII-folded and uppercased, into
; fs_ex_name_buf the same way fs_list_sector does for printing). Same CF
; convention as fs_cat_sector. ---
fs_cat_sector_exfat:
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    mov al, [rsi]
    test al, al
    jz .end_marker
    cmp al, 0x85                     ; file directory entry
    jne .ex_not_file
    mov al, [rsi + 4]                ; file attributes (low byte)
    mov [fs_ex_attr], al
    mov al, [rsi + 1]                ; secondary count
    mov [fs_ex_nrem], al
    mov byte [fs_ex_active], 1
    mov dword [fs_ex_size], 0
    mov dword [fs_name_len], 0
    jmp .skip
.ex_not_file:
    cmp byte [fs_ex_active], 0
    je .skip
    cmp al, 0xC0                     ; stream extension entry
    jne .ex_not_stream
    mov eax, [rsi + 20]              ; first cluster
    mov [fs_cat_cluster], eax
    mov eax, [rsi + 24]              ; data length (low dword)
    mov [fs_cat_size], eax
    jmp .ex_sec_done
.ex_not_stream:
    cmp al, 0xC1                     ; file name entry
    jne .ex_sec_done
    xor ecx, ecx
.ex_name_loop:
    cmp ecx, 15
    jae .ex_sec_done
    mov ax, [rsi + 2 + rcx*2]        ; UTF-16 char
    test ax, ax
    jz .ex_sec_done
    cmp ax, 0x7F
    jbe .ex_ch_ok
    mov al, '?'
.ex_ch_ok:
    cmp al, 'a'
    jb .ex_ch_store
    cmp al, 'z'
    ja .ex_ch_store
    sub al, 0x20
.ex_ch_store:
    mov ebx, [fs_name_len]
    cmp ebx, 255
    jae .ex_name_skip
    lea rdi, [fs_ex_name_buf]
    mov [rdi + rbx], al
.ex_name_skip:
    inc dword [fs_name_len]
    inc ecx
    jmp .ex_name_loop
.ex_sec_done:
    dec byte [fs_ex_nrem]
    jnz .skip
    mov byte [fs_ex_active], 0
    mov eax, [fs_name_len]
    cmp eax, [fs_target_raw_len]
    jne .skip
    cmp byte [fs_want_dir], 0
    jne .m_want_dir
    test byte [fs_ex_attr], 0x10     ; cat: directories don't match
    jnz .skip
    jmp .m_attr_ok
.m_want_dir:
    test byte [fs_ex_attr], 0x10     ; cd: only directories match
    jz .skip
.m_attr_ok:
    test eax, eax
    jz .name_match
    push rcx
    push rsi
    push rdi
    lea rsi, [fs_ex_name_buf]
    lea rdi, [fs_target_raw]
    mov ecx, eax
    repe cmpsb
    pop rdi
    pop rsi
    pop rcx
    jne .skip
.name_match:
    mov byte [fs_cat_found], 1
    stc
    ret
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.not_end:
    clc
    ret
.end_marker:
    stc
    ret

; --- Print a file's contents: eax = starting cluster, ecx = size in bytes.
; Walks the cluster chain through the FAT, reading and printing one sector
; at a time (bare LF bytes are dropped since print_char already turns CR
; into a newline). Stops early on a read error. ---
fs_cat_data:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov [fs_cat_cluster], eax
    mov [fs_cat_remain], ecx
.clus_loop:
    cmp dword [fs_cat_remain], 0
    je .done
    mov eax, [fs_cat_cluster]
    cmp eax, 2
    jb .done
    cmp eax, 0x0FFFFFF8
    jae .done
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.sec_loop:
    cmp dword [fs_sec_count], 0
    je .next_clus
    cmp dword [fs_cat_remain], 0
    je .done
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .done
    mov ecx, 512
    cmp ecx, [fs_cat_remain]
    jbe .have_len
    mov ecx, [fs_cat_remain]
.have_len:
    sub [fs_cat_remain], ecx
    mov esi, FS_SECTOR_BUF
.byte_loop:
    or ecx, ecx
    jz .byte_done
    mov al, [rsi]
    cmp al, 0x0A                     ; LF: skip, CR already newlines
    je .skip_byte
    call print_char
.skip_byte:
    inc rsi
    dec ecx
    jmp .byte_loop
.byte_done:
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .sec_loop
.next_clus:
    cmp byte [fs_is_fat16], 0
    jne .nc16
    mov eax, [fs_cat_cluster]
    shr eax, 7
    add eax, [fs_fat_lba]
    cmp eax, [fs_fat_cached]
    je .cached
    mov [fs_fat_cached], eax
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .cached
    mov dword [fs_fat_cached], 0xFFFFFFFF
    jmp .done
.cached:
    mov eax, [fs_cat_cluster]
    and eax, 127
    mov eax, [FS_FAT_BUF + rax*4]
    cmp byte [fs_is_exfat], 0
    jne .no_mask
    and eax, 0x0FFFFFFF
.no_mask:
    mov [fs_cat_cluster], eax
    jmp .clus_loop
.nc16:
    mov eax, [fs_cat_cluster]
    shr eax, 8                        ; 256 16-bit entries per sector
    add eax, [fs_fat_lba]
    cmp eax, [fs_fat_cached]
    je .cached16
    mov [fs_fat_cached], eax
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .cached16
    mov dword [fs_fat_cached], 0xFFFFFFFF
    jmp .done
.cached16:
    mov eax, [fs_cat_cluster]
    and eax, 255
    movzx eax, word [FS_FAT_BUF + rax*2]
    cmp eax, 0xFFF8
    jb .store16
    mov eax, 0x0FFFFFFF               ; normalize FAT16 EOC for .clus_loop stop
.store16:
    mov [fs_cat_cluster], eax
    jmp .clus_loop
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Read the MFT record for fs_cat_ntfs_ref (found by fs_ntfs_list in cat
; mode), locate its unnamed $DATA attribute (type 0x80), and print it -
; resident inline, non-resident via fs_ntfs_cat_data. Reuses FS_MFT_BUF,
; now done with the root-directory record it held. ---
fs_cat_ntfs_data:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov eax, [fs_cat_ntfs_ref]
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .out
    cmp dword [FS_MFT_BUF], 0x454C4946   ; "FILE"
    jne .out
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    movzx edx, word [FS_MFT_BUF + 20]    ; first attribute offset
.attr_loop:
    mov eax, edx
    cmp eax, 4096
    jae .out
    mov eax, [FS_MFT_BUF + rdx]          ; attribute type
    cmp eax, 0xFFFFFFFF
    je .out
    cmp eax, 0x80                        ; $DATA
    jne .attr_next
    cmp byte [FS_MFT_BUF + rdx + 9], 0   ; name length: 0 = unnamed stream
    je .found_data
.attr_next:
    mov eax, [FS_MFT_BUF + rdx + 4]      ; attribute length
    test eax, eax
    jz .out
    add edx, eax
    jmp .attr_loop
.found_data:
    cmp byte [FS_MFT_BUF + rdx + 8], 0   ; non-resident flag
    jne .nonresident
    ; resident: value at [attr + valueOffset(0x14 word)], length @ 0x10
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]
    add eax, edx
    lea rsi, [FS_MFT_BUF + rax]
    mov eax, [FS_MFT_BUF + rdx + 0x10]
    cmp eax, [fs_cat_size]
    jbe .res_len_ok
    mov eax, [fs_cat_size]
.res_len_ok:
    mov ecx, eax
.res_loop:
    or ecx, ecx
    jz .out
    mov al, [rsi]
    cmp al, 0x0A                         ; LF: skip, CR already newlines
    je .res_skip
    call print_char
.res_skip:
    inc rsi
    dec ecx
    jmp .res_loop
.nonresident:
    movzx eax, word [FS_MFT_BUF + rdx + 0x20]  ; data run offset
    add eax, edx
    mov edi, eax
    mov ecx, [fs_cat_size]
    call fs_ntfs_cat_data
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; --- Print a non-resident NTFS $DATA attribute: edi = offset within
; FS_MFT_BUF of its first data-run byte, ecx = size in bytes to print.
; Walks the run list (same decode as fs_ntfs_list's INDEX_ALLOCATION runs)
; but reads and prints one cluster's sectors at a time via FS_SECTOR_BUF,
; instead of walking INDX blocks. Reuses fs_run_ptr/fs_run_lcn/fs_run_len -
; safe here since fs_ntfs_list's own run walk is long done by this point. ---
fs_ntfs_cat_data:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov [fs_run_ptr], edi
    mov dword [fs_run_lcn], 0
    mov [fs_cat_remain], ecx
.run_loop:
    cmp dword [fs_cat_remain], 0
    je .done
    mov eax, [fs_run_ptr]
    movzx ecx, byte [FS_MFT_BUF + rax]   ; run header
    test cl, cl
    jz .done                             ; end of runs
    inc eax
    mov ebx, ecx
    and ebx, 0x0F                        ; length field size
    mov edx, ecx
    shr edx, 4                           ; offset field size
    xor r8d, r8d
    xor r9d, r9d
.len_bytes:
    test ebx, ebx
    jz .len_done
    movzx ecx, byte [FS_MFT_BUF + rax]
    mov esi, ecx
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec ebx
    jmp .len_bytes
.len_done:
    mov [fs_run_len], r8d
    xor r8d, r8d
    xor r9d, r9d
    mov edi, edx                         ; keep count for sign extension
.off_bytes:
    test edx, edx
    jz .off_done
    movzx ecx, byte [FS_MFT_BUF + rax]
    mov esi, ecx
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec edx
    jmp .off_bytes
.off_done:
    test edi, edi
    jz .after_run                        ; sparse run: no offset - skip
    mov ecx, edi
    shl ecx, 3
    cmp ecx, 32
    jae .no_sext
    mov edx, 1
    dec ecx
    shl edx, cl
    test r8d, edx
    jz .no_sext
    mov ecx, edi
    shl ecx, 3
    mov edx, 0xFFFFFFFF
    shl edx, cl
    or r8d, edx
.no_sext:
    mov [fs_run_ptr], eax
    add [fs_run_lcn], r8d
.clus_loop:
    cmp dword [fs_run_len], 0
    jle .run_loop
    cmp dword [fs_cat_remain], 0
    je .done
    mov eax, [fs_run_lcn]
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.sec_loop:
    cmp dword [fs_sec_count], 0
    je .clus_next
    cmp dword [fs_cat_remain], 0
    je .done
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .done
    mov ecx, 512
    cmp ecx, [fs_cat_remain]
    jbe .have_len
    mov ecx, [fs_cat_remain]
.have_len:
    sub [fs_cat_remain], ecx
    mov esi, FS_SECTOR_BUF
.byte_loop:
    or ecx, ecx
    jz .byte_done
    mov al, [rsi]
    cmp al, 0x0A                         ; LF: skip, CR already newlines
    je .skip_byte
    call print_char
.skip_byte:
    inc rsi
    dec ecx
    jmp .byte_loop
.byte_done:
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .sec_loop
.clus_next:
    inc dword [fs_run_lcn]
    dec dword [fs_run_len]
    jmp .clus_loop
.after_run:
    mov [fs_run_ptr], eax
    jmp .run_loop
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; NTFS write support ("echo <text> > <name>"): overwrite an existing root file
; (resident $DATA in place) or create a brand-new one (allocate an MFT record
; via $MFT's $BITMAP, build a FILE record with resident $DATA, insert an entry
; into root record 5's INDEX_ROOT). Small resident files only (echo <=128 B),
; root directory only, and only when record 5 has no INDEX_ALLOCATION.
; ============================================================================

; --- Inverse of fs_apply_fixup: edi=record buffer, ecx=512-byte sector count.
; Bump the update-sequence number, save each sector's last word into the USA,
; and stamp the USN into each sector's last word. Call before writing. ---
fs_write_fixup:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r9
    movzx eax, word [rdi + 4]        ; USA offset
    lea rsi, [rdi + rax]             ; -> USA (check value word first)
    mov bx, [rsi]
    inc bx                           ; new update-sequence number
    mov [rsi], bx
    add rsi, 2                       ; -> first fixup slot
    xor edx, edx                     ; sector index
.loop:
    test ecx, ecx
    jz .done
    mov r9d, edx
    shl r9d, 9
    add r9d, 510                     ; last word of this sector
    mov ax, [rdi + r9]
    mov [rsi], ax
    mov [rdi + r9], bx
    add rsi, 2
    inc edx
    dec ecx
    jmp .loop
.done:
    pop r9
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Move ecx bytes within FS_MFT_BUF from offset esi to offset edi, bouncing
; through FS_INDX_BUF so overlap is safe. ---
fs_ntfs_shift:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    mov r8d, esi
    mov r9d, edi
    xor eax, eax
.p1:
    cmp eax, ecx
    jae .p1d
    mov dl, [FS_MFT_BUF + r8 + rax]
    mov [FS_INDX_BUF + rax], dl
    inc eax
    jmp .p1
.p1d:
    xor eax, eax
.p2:
    cmp eax, ecx
    jae .p2d
    mov dl, [FS_INDX_BUF + rax]
    mov [FS_MFT_BUF + r9 + rax], dl
    inc eax
    jmp .p2
.p2d:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; --- Write FS_MFT_BUF (fs_rec_secs sectors) to [fs_ntfs_rec_lba], applying the
; write-side fixup first. CF set on error. ---
fs_ntfs_write_rec:
    push rax
    push rcx
    push rdi
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_write_fixup
    mov eax, [fs_ntfs_rec_lba]
    call fs_ntfs_flush_rec
    pop rdi
    pop rcx
    pop rax
    ret

; --- Write FS_MFT_BUF (fs_rec_secs sectors) verbatim to LBA eax (no fixup).
; CF set on error. ---
fs_ntfs_flush_rec:
    push rax
    push rcx
    push rdi
    push r8
    mov r8d, eax
    xor ecx, ecx
.wl:
    cmp ecx, [fs_rec_secs]
    jae .wd
    mov eax, ecx
    shl eax, 9
    lea rdi, [FS_MFT_BUF + rax]
    mov eax, r8d
    add eax, ecx
    push rcx
    call fs_write_sector
    pop rcx
    jc .werr
    inc ecx
    jmp .wl
.wd:
    pop r8
    pop rdi
    pop rcx
    pop rax
    clc
    ret
.werr:
    pop r8
    pop rdi
    pop rcx
    pop rax
    stc
    ret

; --- Find the first zero bit at index >= 24 in the bitmap at rsi (ecx bytes),
; set it, and return its index in eax. CF set if no free bit found. ---
fs_ntfs_bitscan:
    push rbx
    push rdx
    push r8
    mov ebx, 24
.s:
    mov eax, ebx
    shr eax, 3
    cmp eax, ecx
    jae .none
    movzx edx, byte [rsi + rax]
    mov r8d, ebx
    and r8d, 7
    bt edx, r8d
    jnc .free
    inc ebx
    jmp .s
.free:
    bts edx, r8d
    mov [rsi + rax], dl
    mov eax, ebx
    pop r8
    pop rdx
    pop rbx
    clc
    ret
.none:
    pop r8
    pop rdx
    pop rbx
    stc
    ret

; --- Build a $FILE_NAME value (parent = root record 5) at rdi from
; fs_target_disp/fs_target_raw_len. Returns its length in eax; also stores it
; in fs_ntfs_fn_len. ---
fs_ntfs_make_filename:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi                      ; base
    mov edx, [fs_target_raw_len]
    mov eax, 0x42
    lea ecx, [rax + rdx*2]           ; total length
    mov [fs_ntfs_fn_len], ecx
    ; zero the whole struct
    push rcx
    mov rdi, r8
    xor al, al
    rep stosb
    pop rcx
    mov rdi, r8
    mov eax, [fs_ntfs_dir_ref]       ; parent = current directory
    mov [rdi + 0], eax
    mov dword [rdi + 4], 0
    mov eax, [fs_ntfs_dir_seq]
    mov [rdi + 6], ax                ; parent sequence number
    mov eax, [fs_echo_len]
    mov [rdi + 0x28], eax            ; allocated size (low)
    mov [rdi + 0x30], eax            ; real size (low)
    mov dword [rdi + 0x38], 0x20     ; FILE_ATTRIBUTE_ARCHIVE
    mov eax, [fs_target_raw_len]
    mov [rdi + 0x40], al             ; name length (chars)
    mov byte [rdi + 0x41], 1         ; namespace = Win32
    lea rsi, [fs_target_disp]
    lea rbx, [rdi + 0x42]
    xor edx, edx
.nl:
    cmp edx, [fs_target_raw_len]
    jae .nd
    movzx eax, byte [rsi + rdx]
    mov [rbx + rdx*2], ax
    inc edx
    jmp .nl
.nd:
    mov eax, [fs_ntfs_fn_len]
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; --- Debug: print label (rsi) followed by eax as hex and a newline. Preserves
; all registers, including the xHCI-reserved ones. ---
fs_ntfs_log:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov ebx, eax
    call print_string
    mov rax, rbx
    call print_hex64
    mov al, ASCII_CR
    call print_char
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Top-level NTFS echo handler. ---
fs_echo_ntfs:
    push rbx
    mov eax, [fs_echo_len]
    mov rsi, fs_dbg_echo_msg
    call fs_ntfs_log
    mov byte [fs_want_dir], 0        ; overwrite targets are files only
    mov byte [fs_cat_found], 0
    call fs_ntfs_list                ; search mode (fs_action==2)
    jc .err
    movzx eax, byte [fs_cat_found]
    mov rsi, fs_dbg_search_msg
    call fs_ntfs_log
    cmp byte [fs_cat_found], 0
    je .create
    mov eax, [fs_cat_ntfs_ref]
    mov [fs_ntfs_newref], eax
    mov rsi, fs_dbg_ow_msg
    call fs_ntfs_log
    call fs_ntfs_get_security
    call fs_ntfs_overwrite
    jc .err
    jmp .ok
.create:
    call fs_ntfs_get_security
    xor eax, eax
    mov rsi, fs_dbg_create_msg
    call fs_ntfs_log
    call fs_ntfs_alloc_record
    jc .err
    mov eax, [fs_ntfs_newref]
    mov rsi, fs_dbg_alloc_msg
    call fs_ntfs_log
    call fs_ntfs_build_record
    jc .err
    call fs_ntfs_index_insert
    jc .err
.ok:
    xor eax, eax
    mov rsi, fs_dbg_ok_msg
    call fs_ntfs_log
    pop rbx
    ret
.err:
    mov rsi, fs_echo_ntfs_err_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    pop rbx
    ret

; --- Overwrite an existing file's resident $DATA (record in fs_ntfs_newref)
; with fs_echo_ptr/fs_echo_len, then patch its index-entry size. CF on error. ---
fs_ntfs_overwrite:
    mov eax, [fs_ntfs_newref]
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov [fs_ntfs_rec_lba], eax
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .fail
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .fail
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    movzx edx, word [FS_MFT_BUF + 20]
.aloop:
    cmp edx, 4096
    jae .fail
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .fail
    cmp eax, 0x80
    jne .anext
    cmp byte [FS_MFT_BUF + rdx + 9], 0    ; unnamed stream
    je .found
.anext:
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .fail
    add edx, eax
    jmp .aloop
.found:
    cmp byte [FS_MFT_BUF + rdx + 8], 0    ; resident?
    jne .fail
    mov eax, edx
    mov rsi, fs_dbg_ow_data_msg
    call fs_ntfs_log
    ; new/old attribute sizes
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]   ; value offset
    mov r8d, eax                                ; keep value offset
    mov ebx, [fs_echo_len]                      ; new value length
    lea ecx, [rax + rbx]                        ; valoff + newlen
    add ecx, 7
    and ecx, 0xFFFFFFF8                          ; new attr length
    mov r9d, [FS_MFT_BUF + rdx + 4]             ; old attr length
    ; guard: record must still fit
    push rdx
    mov eax, edx
    add eax, ecx                                ; end of this attr after resize
    mov edx, [fs_rec_secs]
    shl edx, 9
    sub edx, 8
    cmp eax, edx
    ja .fail_pop
    pop rdx
    ; shift the tail (attrs after this one + end marker) by (new-old)
    mov esi, edx
    add esi, r9d                                ; old tail start
    mov edi, edx
    add edi, ecx                                ; new tail start
    push rcx
    push rdx
    mov ecx, [FS_MFT_BUF + 0x18]                ; record used size
    sub ecx, esi                                ; tail length
    call fs_ntfs_shift
    pop rdx
    pop rcx
    ; new record used size = old + (newattrlen - oldattrlen)
    mov eax, ecx
    sub eax, r9d
    add [FS_MFT_BUF + 0x18], eax
    ; write the new value bytes
    mov eax, [fs_echo_len]
    test eax, eax
    jz .noval
    push rcx
    lea rdi, [FS_MFT_BUF + rdx]
    add rdi, r8                                 ; -> value
    mov rsi, [fs_echo_ptr]
    mov ecx, eax
    rep movsb
    pop rcx
.noval:
    mov eax, [fs_echo_len]
    mov [FS_MFT_BUF + rdx + 0x10], eax          ; value length
    mov [FS_MFT_BUF + rdx + 4], ecx             ; attr length
    ; patch this record's $FILE_NAME sizes too
    call fs_ntfs_patch_fn_size
    call fs_ntfs_fix_security
    jc .fail
    mov eax, [FS_MFT_BUF + 0x18]
    mov rsi, fs_dbg_ow_wrote_msg
    call fs_ntfs_log
    call fs_ntfs_write_rec
    jc .fail
    call fs_ntfs_patch_index
    clc
    ret
.fail_pop:
    pop rdx
.fail:
    stc
    ret

; --- Set the $FILE_NAME (0x30) real+allocated size in the record now in
; FS_MFT_BUF to fs_echo_len. ---
fs_ntfs_patch_fn_size:
    push rax
    push rdx
    movzx edx, word [FS_MFT_BUF + 20]
.loop:
    cmp edx, 4096
    jae .done
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .done
    cmp eax, 0x30
    je .found
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .done
    add edx, eax
    jmp .loop
.found:
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]   ; value offset
    add edx, eax                                ; -> FILE_NAME value
    mov eax, [fs_echo_len]
    mov [FS_MFT_BUF + rdx + 0x28], eax
    mov dword [FS_MFT_BUF + rdx + 0x2C], 0
    mov [FS_MFT_BUF + rdx + 0x30], eax
    mov dword [FS_MFT_BUF + rdx + 0x34], 0
.done:
    pop rdx
    pop rax
    ret

; --- Update the root INDEX_ROOT entry matching fs_target_raw with the new
; size (fs_echo_len). Best-effort (INDEX_ROOT only); ignores errors. ---
fs_ntfs_patch_index:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov eax, [fs_ntfs_dir_ref]
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov [fs_ntfs_rec_lba], eax
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .done
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .done
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    movzx edx, word [FS_MFT_BUF + 20]
.find90:
    cmp edx, 4096
    jae .done
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .done
    cmp eax, 0x90
    je .have90
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .done
    add edx, eax
    jmp .find90
.have90:
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]
    mov r9d, edx
    add r9d, eax                                ; INDEX_ROOT value offset
    mov esi, r9d
    add esi, 16
    add esi, [FS_MFT_BUF + r9 + 16]             ; first entry offset
.ewalk:
    movzx eax, word [FS_MFT_BUF + rsi + 12]     ; flags
    test al, 0x02
    jnz .write                                  ; end entry -> no match, still rewrite (harmless)
    ; compare name
    movzx ecx, byte [FS_MFT_BUF + rsi + 16 + 0x40]
    cmp ecx, [fs_target_raw_len]
    jne .enext
    lea rbx, [FS_MFT_BUF + rsi + 16 + 0x42]
    lea rdi, [fs_target_raw]
    xor edx, edx
.cmp:
    cmp edx, ecx
    jae .match
    movzx eax, word [rbx + rdx*2]
    cmp eax, 0x7F
    jbe .cok
    mov eax, '?'
.cok:
    cmp al, 'a'
    jb .chave
    cmp al, 'z'
    ja .chave
    sub al, 0x20
.chave:
    cmp al, [rdi + rdx]
    jne .enext
    inc edx
    jmp .cmp
.match:
    mov eax, [fs_echo_len]
    mov [FS_MFT_BUF + rsi + 16 + 0x28], eax
    mov dword [FS_MFT_BUF + rsi + 16 + 0x2C], 0
    mov [FS_MFT_BUF + rsi + 16 + 0x30], eax
    mov dword [FS_MFT_BUF + rsi + 16 + 0x34], 0
    jmp .write
.enext:
    movzx eax, word [FS_MFT_BUF + rsi + 8]
    test eax, eax
    jz .write
    add esi, eax
    jmp .ewalk
.write:
    call fs_ntfs_write_rec
.done:
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

fs_ntfs_fix_security:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    movzx edx, word [FS_MFT_BUF + 20]
.find10:
    cmp edx, 4096
    jae .fail
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .fail
    cmp eax, 0x10
    je .have10
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .fail
    add edx, eax
    jmp .find10
.have10:
    cmp dword [FS_MFT_BUF + rdx + 0x10], 0x48
    jae .sethave
    mov r9d, [FS_MFT_BUF + rdx + 4]
    mov eax, [FS_MFT_BUF + 0x18]
    add eax, 0x60
    sub eax, r9d
    mov ebx, [fs_rec_secs]
    shl ebx, 9
    sub ebx, 8
    cmp eax, ebx
    ja .fail
    mov esi, edx
    add esi, r9d
    mov edi, edx
    add edi, 0x60
    mov ecx, [FS_MFT_BUF + 0x18]
    sub ecx, esi
    call fs_ntfs_shift
    mov eax, 0x60
    sub eax, r9d
    add [FS_MFT_BUF + 0x18], eax
    lea rdi, [FS_MFT_BUF + rdx]
    add rdi, r9
    mov ecx, 0x60
    sub ecx, r9d
    xor al, al
    rep stosb
    mov dword [FS_MFT_BUF + rdx + 4], 0x60
    mov dword [FS_MFT_BUF + rdx + 0x10], 0x48
.sethave:
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]
    add eax, edx
    cmp dword [FS_MFT_BUF + rax + 0x34], 0
    jne .done
    mov ebx, [fs_ntfs_secid]
    mov [FS_MFT_BUF + rax + 0x34], ebx
    test ebx, ebx
    jnz .done
    movzx edx, word [FS_MFT_BUF + 20]
.find50:
    cmp edx, 4096
    jae .fail
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .fail
    cmp eax, 0x50
    je .done
    ja .insert
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .fail
    add edx, eax
    jmp .find50
.insert:
    mov ecx, [fs_ntfs_sd_len]
    test ecx, ecx
    jz .done
    mov eax, [FS_MFT_BUF + 0x18]
    add eax, ecx
    mov ebx, [fs_rec_secs]
    shl ebx, 9
    sub ebx, 8
    cmp eax, ebx
    ja .fail
    mov esi, edx
    mov edi, edx
    add edi, ecx
    mov ecx, [FS_MFT_BUF + 0x18]
    sub ecx, esi
    call fs_ntfs_shift
    mov ecx, [fs_ntfs_sd_len]
    lea rdi, [FS_MFT_BUF + rdx]
    lea rsi, [fs_ntfs_sd_buf]
    rep movsb
    movzx eax, word [FS_MFT_BUF + 0x28]
    mov [FS_MFT_BUF + rdx + 0x0E], ax
    inc eax
    mov [FS_MFT_BUF + 0x28], ax
    mov eax, [fs_ntfs_sd_len]
    add [FS_MFT_BUF + 0x18], eax
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.fail:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret

fs_ntfs_get_security:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov dword [fs_ntfs_secid], 0
    mov dword [fs_ntfs_sd_len], 0
    mov eax, [fs_ntfs_dir_ref]       ; template: the parent directory's security
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .done
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .done
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    movzx edx, word [FS_MFT_BUF + 20]
.loop:
    cmp edx, 4096
    jae .done
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .done
    cmp eax, 0x10
    je .si
    cmp eax, 0x50
    je .sd
.next:
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .done
    add edx, eax
    jmp .loop
.si:
    cmp byte [FS_MFT_BUF + rdx + 8], 0
    jne .next
    cmp dword [FS_MFT_BUF + rdx + 0x10], 0x48
    jb .next
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]
    add eax, edx
    mov ebx, [FS_MFT_BUF + rax + 0x34]
    mov [fs_ntfs_secid], ebx
    jmp .next
.sd:
    cmp byte [FS_MFT_BUF + rdx + 8], 0
    jne .next
    cmp byte [FS_MFT_BUF + rdx + 9], 0
    jne .next
    mov ecx, [FS_MFT_BUF + rdx + 4]
    cmp ecx, 256
    ja .next
    mov [fs_ntfs_sd_len], ecx
    lea rsi, [FS_MFT_BUF + rdx]
    lea rdi, [fs_ntfs_sd_buf]
    rep movsb
    jmp .next
.done:
    cmp dword [fs_ntfs_secid], 0
    jne .out
    cmp dword [fs_ntfs_sd_len], 0
    jne .out
    lea rdi, [fs_ntfs_sd_buf]
    xor al, al
    mov ecx, 0x68
    rep stosb
    lea rdi, [fs_ntfs_sd_buf]
    mov dword [rdi + 0], 0x50
    mov dword [rdi + 4], 0x68
    mov dword [rdi + 0x10], 80
    mov word [rdi + 0x14], 0x18
    lea rsi, [fs_ntfs_def_sd]
    lea rdi, [fs_ntfs_sd_buf + 0x18]
    mov ecx, 80
    rep movsb
    mov dword [fs_ntfs_sd_len], 0x68
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

fs_ntfs_cover_ref:
    push rbx
    push rdx
    mov eax, [fs_ntfs_newref]
    inc eax
    imul eax, [fs_rec_secs]
    shl eax, 9
    movzx edx, word [FS_MFT_BUF + 20]
.loop:
    cmp edx, 4096
    jae .fail
    mov ebx, [FS_MFT_BUF + rdx]
    cmp ebx, 0xFFFFFFFF
    je .fail
    cmp ebx, 0x80
    je .found
    mov ebx, [FS_MFT_BUF + rdx + 4]
    test ebx, ebx
    jz .fail
    add edx, ebx
    jmp .loop
.found:
    cmp byte [FS_MFT_BUF + rdx + 8], 0
    je .no
    cmp dword [FS_MFT_BUF + rdx + 0x34], 0
    jne .no
    cmp eax, [FS_MFT_BUF + rdx + 0x30]
    jbe .no
    cmp dword [FS_MFT_BUF + rdx + 0x2C], 0
    jne .grow
    cmp eax, [FS_MFT_BUF + rdx + 0x28]
    ja .fail
.grow:
    mov [FS_MFT_BUF + rdx + 0x30], eax
    mov [FS_MFT_BUF + rdx + 0x38], eax
    mov eax, 1
    pop rdx
    pop rbx
    clc
    ret
.no:
    xor eax, eax
    pop rdx
    pop rbx
    clc
    ret
.fail:
    pop rdx
    pop rbx
    stc
    ret

; --- Allocate a free MFT record via $MFT's $BITMAP (record 0). Sets
; fs_ntfs_newref. CF on error. ---
fs_ntfs_alloc_record:
    mov eax, 0                       ; MFT record 0 = $MFT
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .fail
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .fail
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    movzx edx, word [FS_MFT_BUF + 20]
.aloop:
    cmp edx, 4096
    jae .fail
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .fail
    cmp eax, 0xB0                    ; $BITMAP
    je .found
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .fail
    add edx, eax
    jmp .aloop
.found:
    cmp byte [FS_MFT_BUF + rdx + 8], 0    ; resident?
    jne .nonres
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]   ; value offset
    mov ecx, [FS_MFT_BUF + rdx + 0x10]          ; value length (bytes)
    lea rsi, [FS_MFT_BUF + rdx]
    add rsi, rax
    call fs_ntfs_bitscan
    jc .fail
    mov [fs_ntfs_newref], eax
    call fs_ntfs_cover_ref
    jc .fail
    ; rewrite record 0 (bitmap lives inside it)
    mov eax, 0
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov [fs_ntfs_rec_lba], eax
    call fs_ntfs_write_rec
    jc .fail
    ; mirror record 0 into $MFTMirr (records 0-3 are mirrored)
    mov eax, [fs_mftmirr_lba]
    call fs_ntfs_flush_rec
    ret
.nonres:
    ; decode the first data run of the non-resident $BITMAP, read one sector
    movzx eax, word [FS_MFT_BUF + rdx + 0x20]   ; run list offset
    add eax, edx
    movzx ecx, byte [FS_MFT_BUF + rax]          ; run header
    test cl, cl
    jz .fail
    inc eax
    mov ebx, ecx
    and ebx, 0x0F                               ; length field size
    mov r8d, ecx
    shr r8d, 4                                  ; offset field size
    add eax, ebx                                ; skip length bytes
    ; read offset (LCN, assume positive) into r9d
    xor r9d, r9d
    xor ecx, ecx                                ; shift
.off:
    test r8d, r8d
    jz .offd
    movzx edx, byte [FS_MFT_BUF + rax]
    shl edx, cl
    or r9d, edx
    add ecx, 8
    inc eax
    dec r8d
    jmp .off
.offd:
    mov eax, r9d                                 ; LCN
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    mov [fs_ntfs_rec_lba], eax                   ; reuse as bitmap sector LBA
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    mov ecx, 512
    lea rsi, [FS_SECTOR_BUF]
    call fs_ntfs_bitscan
    jc .fail
    mov [fs_ntfs_newref], eax
    mov eax, [fs_ntfs_rec_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
    call fs_ntfs_cover_ref
    jc .fail
    test eax, eax
    jz .nogrow
    mov eax, [fs_mft_lba]
    mov [fs_ntfs_rec_lba], eax
    call fs_ntfs_write_rec
    jc .fail
    mov eax, [fs_mftmirr_lba]
    call fs_ntfs_flush_rec
    ret
.nogrow:
    clc
    ret
.fail:
    stc
    ret

; --- Build a new FILE record (record fs_ntfs_newref) in FS_MFT_BUF with
; $STANDARD_INFORMATION, $FILE_NAME and resident $DATA, then write it. ---
fs_ntfs_build_record:
    ; zero the whole record
    mov eax, [fs_rec_secs]
    shl eax, 9
    mov ecx, eax
    lea rdi, [FS_MFT_BUF]
    xor al, al
    rep stosb
    ; header
    mov dword [FS_MFT_BUF + 0], 0x454C4946       ; "FILE"
    mov word [FS_MFT_BUF + 4], 0x30              ; USA offset
    mov eax, [fs_rec_secs]
    inc eax
    mov [FS_MFT_BUF + 6], ax                     ; USA count
    mov word [FS_MFT_BUF + 0x10], 1              ; sequence number
    mov word [FS_MFT_BUF + 0x12], 1              ; hard link count
    mov eax, [fs_rec_secs]
    inc eax
    shl eax, 1
    add eax, 0x30
    add eax, 7
    and eax, 0xFFFFFFF8                          ; first attribute offset
    mov [FS_MFT_BUF + 0x14], ax
    mov r8d, eax                                 ; write cursor
    mov word [FS_MFT_BUF + 0x16], 1              ; flags: in use
    mov eax, [fs_rec_secs]
    shl eax, 9
    mov [FS_MFT_BUF + 0x1C], eax                 ; allocated size
    mov word [FS_MFT_BUF + 0x28], 4              ; next attribute id
    mov eax, [fs_ntfs_newref]
    mov [FS_MFT_BUF + 0x2C], eax                 ; record number
    ; $STANDARD_INFORMATION (0x10)
    mov dword [FS_MFT_BUF + r8 + 0], 0x10
    mov dword [FS_MFT_BUF + r8 + 4], 0x60
    mov byte [FS_MFT_BUF + r8 + 8], 0
    mov byte [FS_MFT_BUF + r8 + 9], 0
    mov word [FS_MFT_BUF + r8 + 0x0A], 0
    mov word [FS_MFT_BUF + r8 + 0x0C], 0
    mov word [FS_MFT_BUF + r8 + 0x0E], 0
    mov dword [FS_MFT_BUF + r8 + 0x10], 0x48
    mov word [FS_MFT_BUF + r8 + 0x14], 0x18
    mov word [FS_MFT_BUF + r8 + 0x16], 0
    mov dword [FS_MFT_BUF + r8 + 0x38], 0x20     ; value+0x20 = flags (archive)
    mov eax, [fs_ntfs_secid]
    mov [FS_MFT_BUF + r8 + 0x4C], eax
    add r8d, 0x60
    ; $FILE_NAME (0x30)
    lea rdi, [fs_ex_name_buf]
    call fs_ntfs_make_filename                    ; -> fs_ntfs_fn_len
    mov dword [FS_MFT_BUF + r8 + 0], 0x30
    mov eax, [fs_ntfs_fn_len]
    lea ebx, [rax + 0x18]
    add ebx, 7
    and ebx, 0xFFFFFFF8
    mov [FS_MFT_BUF + r8 + 4], ebx
    mov byte [FS_MFT_BUF + r8 + 8], 0
    mov byte [FS_MFT_BUF + r8 + 9], 0
    mov word [FS_MFT_BUF + r8 + 0x0A], 0
    mov word [FS_MFT_BUF + r8 + 0x0C], 0
    mov word [FS_MFT_BUF + r8 + 0x0E], 1
    mov [FS_MFT_BUF + r8 + 0x10], eax
    mov word [FS_MFT_BUF + r8 + 0x14], 0x18
    mov byte [FS_MFT_BUF + r8 + 0x16], 1         ; indexed
    mov byte [FS_MFT_BUF + r8 + 0x17], 0
    lea rdi, [FS_MFT_BUF + r8 + 0x18]
    lea rsi, [fs_ex_name_buf]
    mov ecx, [fs_ntfs_fn_len]
    rep movsb
    add r8d, ebx
    mov ecx, [fs_ntfs_sd_len]
    test ecx, ecx
    jz .nosd
    lea rdi, [FS_MFT_BUF + r8]
    lea rsi, [fs_ntfs_sd_buf]
    rep movsb
    mov word [FS_MFT_BUF + r8 + 0x0E], 3
    add r8d, [fs_ntfs_sd_len]
.nosd:
    ; $DATA (0x80), resident
    mov dword [FS_MFT_BUF + r8 + 0], 0x80
    mov eax, [fs_echo_len]
    lea ebx, [rax + 0x18]
    add ebx, 7
    and ebx, 0xFFFFFFF8
    mov [FS_MFT_BUF + r8 + 4], ebx
    mov byte [FS_MFT_BUF + r8 + 8], 0
    mov byte [FS_MFT_BUF + r8 + 9], 0
    mov word [FS_MFT_BUF + r8 + 0x0A], 0
    mov word [FS_MFT_BUF + r8 + 0x0C], 0
    mov word [FS_MFT_BUF + r8 + 0x0E], 2
    mov [FS_MFT_BUF + r8 + 0x10], eax
    mov word [FS_MFT_BUF + r8 + 0x14], 0x18
    mov word [FS_MFT_BUF + r8 + 0x16], 0
    mov eax, [fs_echo_len]
    test eax, eax
    jz .nodata
    lea rdi, [FS_MFT_BUF + r8 + 0x18]
    mov rsi, [fs_echo_ptr]
    mov ecx, eax
    rep movsb
.nodata:
    add r8d, ebx
    ; end marker
    mov dword [FS_MFT_BUF + r8], 0xFFFFFFFF
    mov dword [FS_MFT_BUF + r8 + 4], 0
    add r8d, 8
    mov [FS_MFT_BUF + 0x18], r8d                 ; used size
    mov eax, r8d
    mov rsi, fs_dbg_built_msg
    call fs_ntfs_log
    ; write it
    mov eax, [fs_ntfs_newref]
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov [fs_ntfs_rec_lba], eax
    call fs_ntfs_write_rec
    ret

; --- Insert the new file's entry into root record 5's INDEX_ROOT. Bails (with
; a message, no error) if record 5 has an INDEX_ALLOCATION. CF on I/O error. ---
fs_ntfs_index_insert:
    mov eax, [fs_ntfs_dir_ref]
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov [fs_ntfs_rec_lba], eax
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .fail
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .fail
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    ; new entry length = align8(16 + fn_len)
    mov eax, [fs_ntfs_fn_len]
    add eax, 16
    add eax, 7
    and eax, 0xFFFFFFF8
    mov [fs_ntfs_ent_len], eax
    ; pass 1: if there is an INDEX_ALLOCATION (0xA0), insert into an INDX block
    movzx edx, word [FS_MFT_BUF + 20]
.p1:
    cmp edx, 4096
    jae .p1d
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .p1d
    cmp eax, 0xA0
    je .use_alloc
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .p1d
    add edx, eax
    jmp .p1
.use_alloc:
    mov eax, [fs_ntfs_ent_len]
    mov rsi, fs_dbg_indx_msg
    call fs_ntfs_log
    call fs_ntfs_indx_insert                     ; edx = 0xA0 attr offset
    jc .fail
    test eax, eax
    jz .bigdir                                   ; no INDX block had room
    ret
.p1d:
    ; pass 2: find INDEX_ROOT (0x90)
    movzx edx, word [FS_MFT_BUF + 20]
.p2:
    cmp edx, 4096
    jae .fail
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .fail
    cmp eax, 0x90
    je .have90
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .fail
    add edx, eax
    jmp .p2
.have90:
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]
    mov r9d, edx
    add r9d, eax                                 ; INDEX_ROOT value offset
    mov esi, r9d
    add esi, 16
    add esi, [FS_MFT_BUF + r9 + 16]              ; first entry offset
.ewalk:
    movzx eax, word [FS_MFT_BUF + rsi + 12]      ; flags
    test al, 0x02
    jnz .atend
    lea rax, [FS_MFT_BUF + rsi]
    push rsi
    mov rsi, rax
    call fs_ntfs_ins_here
    pop rsi
    test eax, eax
    jnz .atend                                   ; sorted insertion point
    movzx eax, word [FS_MFT_BUF + rsi + 8]
    test eax, eax
    jz .atend
    add esi, eax
    jmp .ewalk
.atend:
    ; guard: fits?
    mov eax, [FS_MFT_BUF + 0x18]
    add eax, [fs_ntfs_ent_len]
    mov ebx, [fs_rec_secs]
    shl ebx, 9
    sub ebx, 8
    cmp eax, ebx
    ja .bigdir
    mov eax, [fs_ntfs_ent_len]
    mov rsi, fs_dbg_insert_msg
    call fs_ntfs_log
    ; shift tail (from insertion point esi) up by ent_len
    mov ecx, [FS_MFT_BUF + 0x18]
    sub ecx, esi
    mov edi, esi
    add edi, [fs_ntfs_ent_len]
    push rsi
    call fs_ntfs_shift                           ; esi=src, edi=dst, ecx=len
    pop rsi
    ; write the new entry at esi
    mov eax, [fs_ntfs_newref]
    mov [FS_MFT_BUF + rsi + 0], eax
    mov dword [FS_MFT_BUF + rsi + 4], 0x00010000 ; sequence 1
    mov eax, [fs_ntfs_ent_len]
    mov [FS_MFT_BUF + rsi + 8], ax
    mov eax, [fs_ntfs_fn_len]
    mov [FS_MFT_BUF + rsi + 10], ax
    mov word [FS_MFT_BUF + rsi + 12], 0
    mov word [FS_MFT_BUF + rsi + 14], 0
    lea rdi, [FS_MFT_BUF + rsi + 16]
    lea rsi, [fs_ex_name_buf]
    mov ecx, [fs_ntfs_fn_len]
    rep movsb
    ; grow sizes by ent_len
    mov eax, [fs_ntfs_ent_len]
    add [FS_MFT_BUF + r9 + 16 + 4], eax          ; node used
    add [FS_MFT_BUF + r9 + 16 + 8], eax          ; node allocated
    add [FS_MFT_BUF + rdx + 0x10], eax           ; attr value length
    add [FS_MFT_BUF + rdx + 4], eax              ; attr length
    add [FS_MFT_BUF + 0x18], eax                 ; record used size
    call fs_ntfs_write_rec
    ret
.bigdir:
    xor eax, eax
    mov rsi, fs_dbg_bigdir_msg
    call fs_ntfs_log
    mov rsi, fs_echo_ntfs_bigdir_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.fail:
    stc
    ret

; --- Overlap-safe backward byte move within FS_INDX_BUF (dst >= src):
; esi=src offset, edi=dst offset, ecx=length. ---
fs_ntfs_shift_indx:
    push rax
    push rdx
    push r8
    push r9
    mov r8d, esi
    mov r9d, edi
    mov eax, ecx
.l:
    test eax, eax
    jz .d
    dec eax
    mov dl, [FS_INDX_BUF + r8 + rax]
    mov [FS_INDX_BUF + r9 + rax], dl
    jmp .l
.d:
    pop r9
    pop r8
    pop rdx
    pop rax
    ret

; --- Write FS_INDX_BUF (fs_indx_secs sectors) to LBA eax, applying the
; write-side fixup first. CF set on error. ---
fs_ntfs_write_indx:
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    mov r8d, eax
    mov edi, FS_INDX_BUF
    mov ecx, [fs_indx_secs]
    call fs_write_fixup
    xor ecx, ecx
.wl:
    cmp ecx, [fs_indx_secs]
    jae .wd
    mov eax, ecx
    shl eax, 9
    lea rdi, [FS_INDX_BUF + rax]
    mov eax, r8d
    add eax, ecx
    push rcx
    call fs_write_sector
    pop rcx
    jc .werr
    inc ecx
    jmp .wl
.wd:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.werr:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; --- Try to insert the new entry into the INDX block currently in FS_INDX_BUF
; (fixup already applied). Returns eax=1 if inserted (block modified), eax=0 if
; the block had no room. ---
fs_ntfs_try_block:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov esi, 0x18
    add esi, [FS_INDX_BUF + 0x18 + 0]            ; -> first index entry
.walk:
    movzx eax, word [FS_INDX_BUF + rsi + 12]     ; flags
    test al, 0x02                                ; last (end) entry
    jnz .atend
    lea rax, [FS_INDX_BUF + rsi]
    push rsi
    mov rsi, rax
    call fs_ntfs_ins_here
    pop rsi
    test eax, eax
    jnz .atend                                   ; sorted insertion point
    movzx eax, word [FS_INDX_BUF + rsi + 8]
    test eax, eax
    jz .atend
    add esi, eax
    jmp .walk
.atend:
    ; room check: node used + entlen <= node allocated (both rel to 0x18)
    mov eax, [FS_INDX_BUF + 0x18 + 4]
    add eax, [fs_ntfs_ent_len]
    cmp eax, [FS_INDX_BUF + 0x18 + 8]
    ja .noroom
    ; tail length = (0x18 + used) - insertion offset
    mov ecx, 0x18
    add ecx, [FS_INDX_BUF + 0x18 + 4]
    sub ecx, esi
    mov edi, esi
    add edi, [fs_ntfs_ent_len]
    push rsi
    call fs_ntfs_shift_indx
    pop rsi
    mov eax, [fs_ntfs_newref]
    mov [FS_INDX_BUF + rsi + 0], eax
    mov dword [FS_INDX_BUF + rsi + 4], 0x00010000
    mov eax, [fs_ntfs_ent_len]
    mov [FS_INDX_BUF + rsi + 8], ax
    mov eax, [fs_ntfs_fn_len]
    mov [FS_INDX_BUF + rsi + 10], ax
    mov word [FS_INDX_BUF + rsi + 12], 0
    mov word [FS_INDX_BUF + rsi + 14], 0
    lea rdi, [FS_INDX_BUF + rsi + 16]
    lea rsi, [fs_ex_name_buf]
    mov ecx, [fs_ntfs_fn_len]
    rep movsb
    mov eax, [fs_ntfs_ent_len]
    add [FS_INDX_BUF + 0x18 + 4], eax            ; grow node used size
    mov eax, 1
    jmp .out
.noroom:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; --- Insert the new entry into an INDEX_ALLOCATION INDX block. edx = 0xA0 attr
; offset in FS_MFT_BUF (record 5). Walks the attribute's data runs, reading each
; INDX block, and inserts into the first block with room. Returns eax=1 if
; inserted, eax=0 if no block had room; CF set on I/O error. ---
fs_ntfs_indx_insert:
    movzx eax, word [FS_MFT_BUF + rdx + 0x20]    ; runs offset
    add eax, edx
    mov [fs_run_ptr], eax
    mov dword [fs_run_lcn], 0
.run_loop:
    mov eax, [fs_run_ptr]
    movzx ecx, byte [FS_MFT_BUF + rax]
    test cl, cl
    jz .none
    inc eax
    mov ebx, ecx
    and ebx, 0x0F
    mov edx, ecx
    shr edx, 4
    xor r8d, r8d
    xor r9d, r9d
.len:
    test ebx, ebx
    jz .lend
    movzx ecx, byte [FS_MFT_BUF + rax]
    mov esi, ecx
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec ebx
    jmp .len
.lend:
    mov [fs_run_len], r8d
    xor r8d, r8d
    xor r9d, r9d
    mov edi, edx
.off:
    test edx, edx
    jz .offd
    movzx ecx, byte [FS_MFT_BUF + rax]
    mov esi, ecx
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec edx
    jmp .off
.offd:
    test edi, edi
    jz .after                                    ; sparse run: skip
    mov ecx, edi
    shl ecx, 3
    cmp ecx, 32
    jae .nosext
    mov edx, 1
    dec ecx
    shl edx, cl
    test r8d, edx
    jz .nosext
    mov ecx, edi
    shl ecx, 3
    mov edx, 0xFFFFFFFF
    shl edx, cl
    or r8d, edx
.nosext:
    mov [fs_run_ptr], eax
    add [fs_run_lcn], r8d
.blk_loop:
    cmp dword [fs_run_len], 0
    jle .run_loop
    mov eax, [fs_run_lcn]
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    mov [fs_ntfs_rec_lba], eax                    ; remember for write-back
    mov edi, FS_INDX_BUF
    mov edx, [fs_indx_secs]
    call fs_read_secs
    jc .err
    cmp dword [FS_INDX_BUF], 0x58444E49           ; "INDX"
    jne .blk_next
    mov edi, FS_INDX_BUF
    mov ecx, [fs_indx_secs]
    call fs_apply_fixup
    call fs_ntfs_try_block
    test eax, eax
    jz .blk_next
    mov eax, [fs_ntfs_rec_lba]
    call fs_ntfs_write_indx
    jc .err
    mov eax, 1
    clc
    ret
.blk_next:
    mov eax, [fs_indx_secs]
    xor edx, edx
    div dword [fs_spc]
    test eax, eax
    jnz .havecpb
    mov eax, 1
.havecpb:
    add [fs_run_lcn], eax
    sub [fs_run_len], eax
    jmp .blk_loop
.after:
    mov [fs_run_ptr], eax
    jmp .run_loop
.none:
    xor eax, eax
    clc
    ret
.err:
    stc
    ret

; --- NTFS $FILE_NAME collation: rsi = absolute address of an index entry.
; Returns eax=1 if the new file (fs_target_raw, uppercased) sorts at or before
; this entry's name (i.e. insert here), else eax=0. ASCII-uppercase compare,
; matching how the rest of the NTFS code case-folds names. ---
fs_ntfs_ins_here:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    movzx ecx, byte [rsi + 16 + 0x40]           ; entry name length (chars)
    lea rbx, [rsi + 16 + 0x42]                   ; entry name (UTF-16)
    lea rdi, [fs_target_raw]
    mov edx, [fs_target_raw_len]
    xor esi, esi                                 ; i
.l:
    cmp esi, edx
    jae .insert                                  ; target exhausted -> <= entry
    cmp esi, ecx
    jae .not                                     ; entry exhausted -> target > entry
    movzx eax, word [rbx + rsi*2]                ; entry char
    cmp eax, 0x7F
    jbe .eok
    mov eax, '?'
.eok:
    cmp al, 'a'
    jb .ehave
    cmp al, 'z'
    ja .ehave
    sub al, 0x20
.ehave:
    mov ah, [rdi + rsi]                          ; target char (already upper)
    cmp ah, al
    jb .insert                                   ; target < entry
    ja .not                                      ; target > entry
    inc esi
    jmp .l
.insert:
    mov eax, 1
    jmp .out
.not:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; cd / rm support
; ============================================================================

; --- "cd <name>": search the current directory for a subdirectory named
; fs_target_* and push its first cluster onto the cwd stack. FAT16/32 and
; exFAT only (FAT12 subdir chains and NTFS aren't walkable/writable here).
; CF set on I/O error; everything else is reported and returns CF clear. ---
fs_cd_root:
    cmp byte [fs_is_ntfs], 0
    jne .ntfs
    mov byte [fs_want_dir], 1
    mov byte [fs_cat_found], 0
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
    cmp byte [fs_is_exfat], 0
    jne .chain
    cmp byte [fs_is_fat32], 0
    jne .chain
    cmp byte [fs_in_subdir], 0
    jne .chain16
    cmp byte [fs_is_fat16], 0
    je .unsup_clear                  ; FAT12
    mov eax, [fs_root_lba]           ; FAT16 fixed root region
    mov [fs_cur_lba], eax
    mov eax, [fs_root_secs]
    mov [fs_sec_count], eax
.f16_loop:
    cmp dword [fs_sec_count], 0
    je .search_done
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    call fs_cat_sector
    jc .search_done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .f16_loop
.chain16:
    cmp byte [fs_is_fat16], 0
    je .unsup_clear                  ; FAT12 subdir
.chain:
.clus_loop:
    mov eax, [fs_cur_cluster]
    cmp eax, 2
    jb .search_done
    cmp eax, 0x0FFFFFF8
    jae .search_done
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.sec_loop:
    cmp dword [fs_sec_count], 0
    je .next_clus
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    cmp byte [fs_is_exfat], 0
    jne .scan_ex
    call fs_cat_sector
    jmp .scanned
.scan_ex:
    call fs_cat_sector_exfat
.scanned:
    jc .search_done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .sec_loop
.next_clus:
    mov eax, [fs_cur_cluster]
    call fs_next_cluster
    jc .fail
    mov [fs_cur_cluster], eax
    jmp .clus_loop
.search_done:
    mov byte [fs_want_dir], 0
    cmp byte [fs_cat_found], 0
    je .notfound
    mov eax, [fs_cat_cluster]
    cmp eax, 2
    jb .notfound                     ; degenerate entry (e.g. cluster 0)
.push_common:                        ; eax = dir cluster, or NTFS MFT record
    mov ecx, [fs_cwd_depth]
    cmp ecx, 16
    jae .toodeep
    mov [fs_cwd_stack + rcx*4], eax
    inc dword [fs_cwd_depth]
    mov eax, [fs_part_lba]
    mov [fs_cwd_vol], eax
    call fs_cur_fstype
    mov [fs_cwd_fstype], al
    call fs_cwd_path_append
    clc
    ret
.ntfs:
    mov byte [fs_want_dir], 1
    mov byte [fs_cat_found], 0
    call fs_ntfs_list                ; fs_action=3: match mode, dirs only
    mov byte [fs_want_dir], 0
    jc .fail
    cmp byte [fs_cat_found], 0
    je .notfound
    mov eax, [fs_cat_ntfs_ref]
    jmp .push_common
.notfound:
    mov rsi, cd_notfound_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.toodeep:
    mov rsi, cd_toodeep_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.unsup_clear:
    mov byte [fs_want_dir], 0
.unsupported:
    mov rsi, cd_unsupported_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.fail:
    mov byte [fs_want_dir], 0
    stc
    ret

; --- "rm [-r] <name>" work, post-mount: find the target in the current
; directory, mark its directory-entry set deleted, and free its clusters
; (whole tree with -r). FAT16/32 and exFAT only. CF set on I/O error. ---
fs_rm_root:
    cmp byte [fs_is_ntfs], 0
    jne .ntfs
    cmp byte [fs_is_exfat], 0
    jne .ex_prep
    cmp byte [fs_is_fat32], 0
    jne .prep_done
    cmp byte [fs_is_fat16], 0
    je .unsupported                  ; FAT12: no write support
    jmp .prep_done
.ex_prep:
    ; locate the allocation bitmap in the real root, then restore the cwd
    mov eax, [fs_cur_cluster]
    mov [fs_ex_root_clus], eax
    mov eax, [fs_ex_rootdir_clus]
    mov [fs_cur_cluster], eax
    call fs_exfat_find_bitmap
    mov eax, [fs_ex_root_clus]
    mov [fs_cur_cluster], eax
.prep_done:
    call fs_rm_find
    jc .fail
    cmp byte [fs_rm_found], 0
    je .notfound
    cmp byte [fs_rm_is_dir], 0
    je .do_file
    cmp byte [fs_rm_recursive], 0
    je .isdir_err
    call fs_rm_mark_deleted
    jc .fail
    mov byte [fs_rm_err], 0
    call fs_rm_free_tree
    jc .free_err
    clc
    ret
.do_file:
    call fs_rm_mark_deleted
    jc .fail
    mov eax, [fs_rm_cluster]
    cmp byte [fs_is_exfat], 0
    jne .free_ex
    call fs_free_chain
    jc .fail
    clc
    ret
.free_ex:
    call fs_ex_free_chain
    jc .fail
    clc
    ret
.ntfs:
    mov byte [fs_want_dir], 2        ; match files and directories alike
    mov byte [fs_cat_found], 0
    call fs_ntfs_list                ; fs_action=4: match mode
    mov byte [fs_want_dir], 0
    jc .fail
    cmp byte [fs_cat_found], 0
    je .notfound
    mov eax, [fs_cat_ntfs_ref]
    mov [fs_ntfs_rm_target], eax
    cmp byte [fs_rm_is_dir], 0       ; set by fs_ntfs_match
    je .ntfs_kind_ok
    cmp byte [fs_rm_recursive], 0
    je .isdir_err
.ntfs_kind_ok:
    mov byte [fs_rm_err], 0
    call fs_ntfs_remove_entry        ; unlink from the parent index first -
    jc .fail                         ; also detects the unsupported b-tree case
    cmp byte [fs_rm_err], 3
    je .ntfs_btree
    cmp byte [fs_ntfs_ent_removed], 0
    je .notfound
    cmp byte [fs_rm_is_dir], 0
    jne .ntfs_tree
    mov eax, [fs_ntfs_rm_target]
    call fs_ntfs_free_record
    jc .fail
    jmp .ntfs_check_soft
.ntfs_tree:
    call fs_ntfs_rm_tree
    jc .free_err
.ntfs_check_soft:
    cmp byte [fs_rm_err], 1          ; run-table/queue overflow: partial free
    jne .ntfs_ok
    mov rsi, rm_toobig_msg
    call print_string
    mov al, ASCII_CR
    call print_char
.ntfs_ok:
    clc
    ret
.ntfs_btree:
    mov rsi, rm_ntfs_btree_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.free_err:
    cmp byte [fs_rm_err], 1          ; queue full: report, entries already gone
    jne .fail
    mov rsi, rm_toobig_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.notfound:
    mov rsi, rm_notfound_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.isdir_err:
    mov rsi, rm_isdir_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.unsupported:
    mov rsi, rm_unsupported_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret
.fail:
    stc
    ret

; --- Walk the current directory looking for the rm target (fs_target_*),
; via fs_rm_sector/fs_rm_sector_exfat. Same walk shape as fs_cd_root; the
; FAT12 cases were already rejected by fs_rm_root. CF on read error. ---
fs_rm_find:
    mov byte [fs_rm_found], 0
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
    cmp byte [fs_is_exfat], 0
    jne .chain
    cmp byte [fs_is_fat32], 0
    jne .chain
    cmp byte [fs_in_subdir], 0
    jne .chain
    mov eax, [fs_root_lba]           ; FAT16 fixed root region
    mov [fs_cur_lba], eax
    mov eax, [fs_root_secs]
    mov [fs_sec_count], eax
.f16_loop:
    cmp dword [fs_sec_count], 0
    je .done
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    call fs_rm_sector
    jc .done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .f16_loop
.chain:
.clus_loop:
    mov eax, [fs_cur_cluster]
    cmp eax, 2
    jb .done
    cmp eax, 0x0FFFFFF8
    jae .done
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov eax, [fs_spc]
    mov [fs_sec_count], eax
.sec_loop:
    cmp dword [fs_sec_count], 0
    je .next_clus
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    cmp byte [fs_is_exfat], 0
    jne .scan_ex
    call fs_rm_sector
    jmp .scanned
.scan_ex:
    call fs_rm_sector_exfat
.scanned:
    jc .done
    inc dword [fs_cur_lba]
    dec dword [fs_sec_count]
    jmp .sec_loop
.next_clus:
    mov eax, [fs_cur_cluster]
    call fs_next_cluster
    jc .fail
    mov [fs_cur_cluster], eax
    jmp .clus_loop
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Scan the FAT directory entries in FS_SECTOR_BUF for the rm target,
; recording the location and span of its whole entry set (any 0x0F LFN
; entries plus the 8.3 entry) so it can be marked deleted, plus its first
; cluster/size/attr. Same CF convention as fs_cat_sector. ---
fs_rm_sector:
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    mov al, [rsi]
    test al, al
    jz .end_marker
    cmp al, 0xE5                     ; deleted
    je .del
    mov al, [rsi + 11]
    cmp al, 0x0F                     ; long-file-name entry
    je .lfn
    test al, 0x08                    ; volume label
    jnz .skip_reset
    cmp byte [fs_lfn_have], 0
    je .try_short
    call fs_lfn_match
    test al, al
    jnz .matched_lfn
    jmp .skip_reset
.try_short:
    push rcx
    push rdi
    push rsi
    lea rdi, [fs_target_name]
    mov rcx, 11
    repe cmpsb
    pop rsi
    pop rdi
    pop rcx
    jne .skip_reset
    ; short-name match: single-entry set at the current entry
    mov eax, [fs_cur_lba]
    mov [fs_rm_set_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_rm_set_off], eax
    mov dword [fs_rm_set_cnt], 1
    jmp .capture
.matched_lfn:
    ; set spans the accumulated LFN entries (start recorded at the first
    ; one, possibly in an earlier sector) plus this 8.3 entry
    mov eax, [fs_rm_lfn_cnt]
    inc eax
    mov [fs_rm_set_cnt], eax
.capture:
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
    mov byte [fs_rm_is_dir], 0
    mov al, [rsi + 11]
    test al, 0x10
    jz .not_dir
    mov byte [fs_rm_is_dir], 1
.not_dir:
    movzx eax, word [rsi + 26]       ; first cluster, low word
    mov ecx, eax
    movzx eax, word [rsi + 20]       ; first cluster, high word (FAT32)
    shl eax, 16
    or eax, ecx
    mov [fs_rm_cluster], eax
    mov eax, [rsi + 28]
    mov [fs_rm_size], eax
    mov byte [fs_rm_nofat], 0        ; FAT always chains through the FAT
    mov byte [fs_rm_found], 1
    stc
    ret
.lfn:
    cmp byte [fs_lfn_have], 0
    jne .lfn_more
    mov eax, [fs_cur_lba]            ; first LFN entry of a new set
    mov [fs_rm_set_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_rm_set_off], eax
    mov dword [fs_rm_lfn_cnt], 0
.lfn_more:
    inc dword [fs_rm_lfn_cnt]
    call fs_lfn_accumulate
    jmp .skip
.del:
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
    jmp .skip
.skip_reset:
    mov byte [fs_lfn_have], 0
    mov dword [fs_lfn_maxlen], 0
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.not_end:
    clc
    ret
.end_marker:
    stc
    ret

; --- Scan the exFAT directory entries in FS_SECTOR_BUF for the rm target,
; recording the entry-set location/count (0x85 file + all its secondaries)
; and the stream entry's first cluster/DataLength/NoFatChain flag. Same CF
; convention as fs_cat_sector_exfat. ---
fs_rm_sector_exfat:
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    mov al, [rsi]
    test al, al
    jz .end_marker
    cmp al, 0x85                     ; file directory entry: set start
    jne .ex_not_file
    mov eax, [fs_cur_lba]
    mov [fs_rm_set_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_rm_set_off], eax
    movzx eax, byte [rsi + 1]        ; secondary count
    inc eax
    mov [fs_rm_set_cnt], eax
    mov al, [rsi + 4]
    mov [fs_ex_attr], al
    mov al, [rsi + 1]
    mov [fs_ex_nrem], al
    mov byte [fs_ex_active], 1
    mov dword [fs_name_len], 0
    jmp .skip
.ex_not_file:
    cmp byte [fs_ex_active], 0
    je .skip
    cmp al, 0xC0                     ; stream extension entry
    jne .ex_not_stream
    mov eax, [rsi + 20]              ; first cluster
    mov [fs_rm_cluster], eax
    mov eax, [rsi + 24]              ; data length (low dword)
    mov [fs_rm_size], eax
    mov al, [rsi + 1]                ; general secondary flags
    shr al, 1
    and al, 1
    mov [fs_rm_nofat], al            ; NoFatChain
    jmp .ex_sec_done
.ex_not_stream:
    cmp al, 0xC1                     ; file name entry
    jne .ex_sec_done
    xor ecx, ecx
.ex_name_loop:
    cmp ecx, 15
    jae .ex_sec_done
    mov ax, [rsi + 2 + rcx*2]
    test ax, ax
    jz .ex_sec_done
    cmp ax, 0x7F
    jbe .ex_ch_ok
    mov al, '?'
.ex_ch_ok:
    cmp al, 'a'
    jb .ex_ch_store
    cmp al, 'z'
    ja .ex_ch_store
    sub al, 0x20
.ex_ch_store:
    mov ebx, [fs_name_len]
    cmp ebx, 255
    jae .ex_name_skip
    lea rdi, [fs_ex_name_buf]
    mov [rdi + rbx], al
.ex_name_skip:
    inc dword [fs_name_len]
    inc ecx
    jmp .ex_name_loop
.ex_sec_done:
    dec byte [fs_ex_nrem]
    jnz .skip
    mov byte [fs_ex_active], 0
    mov eax, [fs_name_len]
    cmp eax, [fs_target_raw_len]
    jne .skip
    test eax, eax
    jz .name_match
    push rcx
    push rsi
    push rdi
    lea rsi, [fs_ex_name_buf]
    lea rdi, [fs_target_raw]
    mov ecx, eax
    repe cmpsb
    pop rdi
    pop rsi
    pop rcx
    jne .skip
.name_match:
    mov byte [fs_rm_is_dir], 0
    test byte [fs_ex_attr], 0x10
    jz .nm_file
    mov byte [fs_rm_is_dir], 1
.nm_file:
    mov byte [fs_rm_found], 1
    stc
    ret
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.not_end:
    clc
    ret
.end_marker:
    stc
    ret

; --- Mark the found entry set deleted: fs_rm_set_cnt entries starting at
; fs_rm_set_lba/fs_rm_set_off. FAT: first byte := 0xE5; exFAT: clear the
; in-use bit (bit 7) of each entry type. Read-modify-write per entry,
; following sector boundaries (sets never straddle a cluster boundary in
; practice - same assumption as fs_echo_write_lfn_set). CF on I/O error. ---
fs_rm_mark_deleted:
    mov dword [fs_rm_i], 0
.loop:
    mov eax, [fs_rm_i]
    cmp eax, [fs_rm_set_cnt]
    jae .done
    mov eax, [fs_rm_set_off]
    shr eax, 5
    add eax, [fs_rm_i]
    mov ecx, eax
    and ecx, 15
    shl ecx, 5
    mov [fs_rm_off2], ecx
    shr eax, 4
    add eax, [fs_rm_set_lba]
    mov [fs_rm_lba2], eax
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    mov eax, [fs_rm_off2]
    cmp byte [fs_is_exfat], 0
    jne .ex
    mov byte [FS_SECTOR_BUF + rax], 0xE5
    jmp .write
.ex:
    and byte [FS_SECTOR_BUF + rax], 0x7F
.write:
    mov eax, [fs_rm_lba2]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
    inc dword [fs_rm_i]
    jmp .loop
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Free a FAT16/32 cluster chain starting at eax: walk the chain via
; fs_next_cluster, zeroing each entry with fs_fat_set. Preserves
; FS_SECTOR_BUF (only FS_FAT_BUF is touched), so it is safe mid-directory-
; scan. CF on I/O error. ---
fs_free_chain:
.loop:
    cmp eax, 2
    jb .done
    cmp eax, 0x0FFFFFF8
    jae .done
    mov [fs_rm_cur], eax
    call fs_next_cluster
    jc .fail
    mov [fs_rm_next], eax
    mov eax, [fs_rm_cur]
    xor edx, edx
    call fs_fat_set
    jc .fail
    mov eax, [fs_rm_next]
    jmp .loop
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Clear one exFAT allocation-bitmap bit (eax = cluster). The bitmap is
; assumed contiguous from fs_ex_bitmap_clus (same simplification as
; fs_echo_alloc_exfat's first-cluster-only scan). Uses FS_MFT_BUF as the
; sector scratch so FS_SECTOR_BUF (a directory scan in progress) survives.
; CF on I/O error. ---
fs_ex_clear_bit:
    cmp dword [fs_ex_bitmap_clus], 0
    je .done                         ; no bitmap found: FAT is still freed
    sub eax, 2
    mov ecx, eax
    and ecx, 4095                    ; bit index within its sector (512*8)
    mov [fs_rm_bit], ecx
    shr eax, 12                      ; sector index within the bitmap
    mov ecx, [fs_ex_bitmap_clus]
    sub ecx, 2
    imul ecx, [fs_spc]
    add ecx, [fs_data_lba]
    add eax, ecx
    mov [fs_rm_bit_lba], eax
    mov edi, FS_MFT_BUF
    call fs_read_sector
    jc .fail
    mov ecx, [fs_rm_bit]
    mov eax, ecx
    shr eax, 3                       ; byte offset
    and ecx, 7
    movzx edx, byte [FS_MFT_BUF + rax]
    btr edx, ecx
    mov [FS_MFT_BUF + rax], dl
    mov eax, [fs_rm_bit_lba]
    mov edi, FS_MFT_BUF
    call fs_write_sector
    jc .fail
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Free an exFAT cluster run starting at eax, described by fs_rm_nofat/
; fs_rm_size: NoFatChain set = ceil(size/cluster-bytes) contiguous clusters
; (bitmap bits only - the FAT was never valid for them); clear = walk and
; zero the FAT chain, clearing each cluster's bitmap bit. CF on error. ---
fs_ex_free_chain:
    cmp byte [fs_rm_nofat], 0
    je .chain_loop
    ; contiguous run
    cmp eax, 2
    jb .done
    mov [fs_rm_cur], eax
    mov ecx, [fs_spc]
    shl ecx, 9                       ; bytes per cluster
    mov eax, [fs_rm_size]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    test eax, eax
    jnz .have_count
    mov eax, 1                       ; size 0 with a valid cluster: free one
.have_count:
    mov [fs_rm_next], eax            ; reused as remaining count
.contig_loop:
    mov eax, [fs_rm_cur]
    call fs_ex_clear_bit
    jc .fail
    inc dword [fs_rm_cur]
    dec dword [fs_rm_next]
    jnz .contig_loop
    clc
    ret
.chain_loop:
    cmp eax, 2
    jb .done
    cmp eax, 0x0FFFFFF8
    jae .done
    mov [fs_rm_cur], eax
    call fs_next_cluster
    jc .fail
    mov [fs_rm_next], eax
    mov eax, [fs_rm_cur]
    call fs_ex_clear_bit
    jc .fail
    mov eax, [fs_rm_cur]
    xor edx, edx
    call fs_exfat_fat_set
    jc .fail
    mov eax, [fs_rm_next]
    jmp .chain_loop
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Push a directory onto the rm -r pending queue: eax = first cluster,
; ecx = size (exFAT), edx = flags (bit 0 = NoFatChain). CF when full. ---
fs_rm_q_push:
    push rbx
    mov ebx, [fs_rm_q_tail]
    cmp ebx, FS_RM_QUEUE_MAX
    jae .full
    imul ebx, ebx, 12
    mov [FS_RM_QUEUE + rbx + 0], eax
    mov [FS_RM_QUEUE + rbx + 4], ecx
    mov [FS_RM_QUEUE + rbx + 8], edx
    inc dword [fs_rm_q_tail]
    pop rbx
    clc
    ret
.full:
    pop rbx
    stc
    ret

; --- Free every cluster chain under the directory described by
; fs_rm_cluster/fs_rm_size/fs_rm_nofat, breadth-first: pop a directory off
; the queue, walk its entries freeing files and queueing subdirectories,
; then free the directory's own chain. The removed tree's directory entries
; are not individually marked (their clusters are freed wholesale); only
; the top-level entry set was marked by the caller. CF on error, with
; fs_rm_err = 1 (queue overflow) or 2 (I/O). ---
fs_rm_free_tree:
    mov dword [fs_rm_q_head], 0
    mov dword [fs_rm_q_tail], 0
    mov eax, [fs_rm_cluster]
    mov ecx, [fs_rm_size]
    movzx edx, byte [fs_rm_nofat]
    call fs_rm_q_push                ; can't fail on an empty queue
.pop:
    mov eax, [fs_rm_q_head]
    cmp eax, [fs_rm_q_tail]
    je .all_done
    imul eax, eax, 12
    mov ecx, [FS_RM_QUEUE + rax + 0]
    mov [fs_rmw_clus], ecx
    mov [fs_rmw_cur], ecx
    mov ecx, [FS_RM_QUEUE + rax + 4]
    mov [fs_rmw_size], ecx
    mov ecx, [FS_RM_QUEUE + rax + 8]
    mov [fs_rmw_nofat], cl
    inc dword [fs_rm_q_head]
    ; contiguous-cluster count for a NoFatChain directory walk
    mov dword [fs_rmw_nfleft], 0
    cmp byte [fs_rmw_nofat], 0
    je .walk
    mov ecx, [fs_spc]
    shl ecx, 9
    mov eax, [fs_rmw_size]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    test eax, eax
    jnz .have_nfleft
    mov eax, 1
.have_nfleft:
    mov [fs_rmw_nfleft], eax
.walk:
.dir_clus_loop:
    mov eax, [fs_rmw_cur]
    cmp eax, 2
    jb .walk_done
    cmp eax, 0x0FFFFFF8
    jae .walk_done
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_rmw_lba], eax
    mov eax, [fs_spc]
    mov [fs_rmw_secs], eax
.dir_sec_loop:
    cmp dword [fs_rmw_secs], 0
    je .dir_next_clus
    mov eax, [fs_rmw_lba]
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .io_fail
    call fs_rm_scan_free_sector
    jc .scan_stopped                 ; end-of-directory marker, or error
    inc dword [fs_rmw_lba]
    dec dword [fs_rmw_secs]
    jmp .dir_sec_loop
.dir_next_clus:
    cmp byte [fs_rmw_nofat], 0
    je .via_fat
    dec dword [fs_rmw_nfleft]
    jz .walk_done
    inc dword [fs_rmw_cur]
    jmp .dir_clus_loop
.via_fat:
    mov eax, [fs_rmw_cur]
    call fs_next_cluster
    jc .io_fail
    mov [fs_rmw_cur], eax
    jmp .dir_clus_loop
.scan_stopped:
    cmp byte [fs_rm_err], 0
    jne .fail
.walk_done:
    ; children handled: free this directory's own chain
    mov eax, [fs_rmw_clus]
    cmp byte [fs_is_exfat], 0
    je .free_fat_dir
    mov cl, [fs_rmw_nofat]
    mov [fs_rm_nofat], cl
    mov ecx, [fs_rmw_size]
    mov [fs_rm_size], ecx
    call fs_ex_free_chain
    jc .io_fail
    jmp .pop
.free_fat_dir:
    call fs_free_chain
    jc .io_fail
    jmp .pop
.all_done:
    clc
    ret
.io_fail:
    mov byte [fs_rm_err], 2
.fail:
    stc
    ret

; --- rm -r helper: process one directory sector in FS_SECTOR_BUF - free
; each file's cluster chain immediately, queue each subdirectory. Frees
; only touch FS_FAT_BUF/FS_MFT_BUF, so the sector buffer stays valid across
; them. CF stops the caller's walk: the 0x00 end-of-directory marker
; (fs_rm_err unchanged) or an error (fs_rm_err set). ---
fs_rm_scan_free_sector:
    cmp byte [fs_is_exfat], 0
    jne fs_rm_scan_free_exfat
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    mov al, [rsi]
    test al, al
    jz .end
    cmp al, 0xE5                     ; deleted
    je .skip
    cmp al, '.'                      ; "."/"..": never follow (self/parent)
    je .skip
    mov al, [rsi + 11]
    cmp al, 0x0F                     ; LFN entry
    je .skip
    test al, 0x08                    ; volume label
    jnz .skip
    movzx eax, word [rsi + 26]
    mov ecx, eax
    movzx eax, word [rsi + 20]
    shl eax, 16
    or eax, ecx
    cmp eax, 2
    jb .skip                         ; empty file / degenerate entry
    test byte [rsi + 11], 0x10
    jnz .subdir
    call fs_free_chain
    jc .err_io
    jmp .skip
.subdir:
    xor ecx, ecx
    xor edx, edx
    call fs_rm_q_push
    jc .err_full
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.not_end:
    clc
    ret
.end:
    stc                              ; end of directory
    ret
.err_full:
    mov byte [fs_rm_err], 1
    stc
    ret
.err_io:
    mov byte [fs_rm_err], 2
    stc
    ret

; --- exFAT variant of fs_rm_scan_free_sector: a 0xC0 stream entry after a
; 0x85 file entry carries everything needed to free (first cluster,
; DataLength, NoFatChain); name entries are ignored. ---
fs_rm_scan_free_exfat:
    mov dword [fs_entry_off], 0
.loop:
    mov eax, [fs_entry_off]
    cmp eax, 512
    jae .not_end
    mov esi, FS_SECTOR_BUF
    add esi, eax
    mov al, [rsi]
    test al, al
    jz .end
    cmp al, 0x85                     ; file directory entry
    jne .not_file
    mov al, [rsi + 4]
    mov [fs_ex_attr], al
    mov byte [fs_ex_active], 1
    jmp .skip
.not_file:
    cmp byte [fs_ex_active], 0
    je .skip
    cmp al, 0xC0                     ; stream extension entry
    jne .skip
    mov byte [fs_ex_active], 0
    mov eax, [rsi + 24]
    mov [fs_rm_size], eax
    mov al, [rsi + 1]
    shr al, 1
    and al, 1
    mov [fs_rm_nofat], al
    mov eax, [rsi + 20]
    cmp eax, 2
    jb .skip                         ; empty file
    test byte [fs_ex_attr], 0x10
    jz .file
    mov ecx, [fs_rm_size]            ; subdirectory: queue it
    movzx edx, byte [fs_rm_nofat]
    call fs_rm_q_push
    jc .err_full
    jmp .skip
.file:
    call fs_ex_free_chain
    jc .err_io
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
.not_end:
    clc
    ret
.end:
    stc
    ret
.err_full:
    mov byte [fs_rm_err], 1
    stc
    ret
.err_io:
    mov byte [fs_rm_err], 2
    stc
    ret

; ============================================================================
; NTFS cd/rm support: index-entry removal, MFT record + cluster freeing
; ============================================================================

; --- rm -r enumeration callback (fs_ntfs_collect=1): push the index entry at
; rsi ({MFT ref, 0, is-directory}) onto the FS_RM_QUEUE. Queue overflow sets
; fs_rm_err=1 (entries dropped; reported as "tree too large"). ---
fs_ntfs_collect_child:
    push rax
    push rcx
    push rdx
    mov ecx, [rsi + 16 + 0x38]       ; file attribute flags
    xor edx, edx
    test ecx, 0x10000000
    jnz .dir
    test ecx, 0x10
    jz .kind
.dir:
    mov edx, 1
.kind:
    mov eax, [rsi]                   ; MFT record (low dword)
    xor ecx, ecx
    call fs_rm_q_push
    jnc .out
    mov byte [fs_rm_err], 1
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; --- rm -r for NTFS: breadth-first free of everything under the target
; directory (fs_ntfs_rm_target). Pops {ref, isdir} off the queue; files are
; freed directly, directories are enumerated (children pushed) and then
; freed. Nothing under the removed tree needs index-entry surgery - only
; the top-level entry was unlinked, and each subtree's INDX clusters are
; freed wholesale with their records. CF on error (fs_rm_err 1=overflow,
; 2=I/O). ---
fs_ntfs_rm_tree:
    mov dword [fs_rm_q_head], 0
    mov dword [fs_rm_q_tail], 0
    mov eax, [fs_ntfs_rm_target]
    xor ecx, ecx
    mov edx, 1
    call fs_rm_q_push                ; can't fail on an empty queue
.pop:
    mov eax, [fs_rm_q_head]
    cmp eax, [fs_rm_q_tail]
    je .done
    imul eax, eax, 12
    mov ecx, [FS_RM_QUEUE + rax + 0]
    mov [fs_ntfs_cur_dir], ecx
    mov ecx, [FS_RM_QUEUE + rax + 8]
    inc dword [fs_rm_q_head]
    test ecx, ecx
    jnz .dir
    mov eax, [fs_ntfs_cur_dir]       ; plain file: free its record + clusters
    call fs_ntfs_free_record
    jc .fail
    jmp .pop
.dir:
    mov eax, [fs_ntfs_cur_dir]
    mov [fs_ntfs_dir_ref], eax       ; point the walker at this directory
    mov byte [fs_ntfs_collect], 1
    call fs_ntfs_list
    mov byte [fs_ntfs_collect], 0
    jc .fail
    cmp byte [fs_rm_err], 1          ; queue overflowed while collecting
    je .fail
    mov eax, [fs_ntfs_cur_dir]
    call fs_ntfs_free_record         ; frees its INDX clusters too
    jc .fail
    jmp .pop
.done:
    clc
    ret
.fail:
    cmp byte [fs_rm_err], 0
    jne .f
    mov byte [fs_rm_err], 2
.f:
    stc
    ret

; --- Remove every index entry whose file reference (low dword) matches
; fs_ntfs_rm_target from the current directory (fs_ntfs_dir_ref): first the
; record's INDEX_ROOT, then every INDEX_ALLOCATION INDX block. Removal is a
; plain tail shift - entries carrying a sub-node pointer would need a b-tree
; rebalance, so those set fs_rm_err=3 and stop (nothing freed yet at that
; point). Counts removals in fs_ntfs_ent_removed. CF on I/O error. ---
fs_ntfs_remove_entry:
    mov byte [fs_ntfs_ent_removed], 0
    mov eax, [fs_ntfs_dir_ref]
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov [fs_ntfs_rec_lba], eax
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .fail
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .fail
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    ; --- pass 1: INDEX_ROOT (0x90) ---
    movzx edx, word [FS_MFT_BUF + 20]
.find90:
    cmp edx, 4096
    jae .indx_pass
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .indx_pass
    cmp eax, 0x90
    je .have90
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .indx_pass
    add edx, eax
    jmp .find90
.have90:
    mov [fs_nre_attr], edx
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]
    add eax, edx
    mov [fs_nre_root], eax           ; INDEX_ROOT value offset
    mov esi, eax
    add esi, 16
    add esi, [FS_MFT_BUF + rax + 16] ; first index entry
    mov byte [fs_nre_mod], 0
.rwalk:
    movzx eax, word [FS_MFT_BUF + rsi + 12]  ; entry flags
    test al, 0x02
    jnz .root_done
    movzx ecx, word [FS_MFT_BUF + rsi + 10]  ; key length
    test ecx, ecx
    jz .rnext
    mov ecx, [FS_MFT_BUF + rsi]
    cmp ecx, [fs_ntfs_rm_target]
    jne .rnext
    test al, 0x01                    ; sub-node pointer: needs a rebalance
    jnz .subnode
    movzx ecx, word [FS_MFT_BUF + rsi + 8]
    mov [fs_nre_len], ecx
    ; shift the tail down over this entry
    push rsi
    mov edi, esi
    mov esi, edi
    add esi, [fs_nre_len]
    mov ecx, [FS_MFT_BUF + 0x18]
    sub ecx, esi
    call fs_ntfs_shift
    pop rsi
    ; shrink all the sizes insert grew
    mov eax, [fs_nre_len]
    mov edx, [fs_nre_root]
    sub [FS_MFT_BUF + rdx + 16 + 4], eax     ; node used size
    sub [FS_MFT_BUF + rdx + 16 + 8], eax     ; node allocated size
    mov edx, [fs_nre_attr]
    sub [FS_MFT_BUF + rdx + 0x10], eax       ; attr value length
    sub [FS_MFT_BUF + rdx + 4], eax          ; attr length
    sub [FS_MFT_BUF + 0x18], eax             ; record used size
    inc byte [fs_ntfs_ent_removed]
    mov byte [fs_nre_mod], 1
    jmp .rwalk                       ; next entry shifted into place at esi
.rnext:
    movzx eax, word [FS_MFT_BUF + rsi + 8]
    test eax, eax
    jz .root_done
    add esi, eax
    jmp .rwalk
.root_done:
    cmp byte [fs_nre_mod], 0
    je .indx_pass
    call fs_ntfs_write_rec
    jc .fail
.indx_pass:
    ; --- pass 2: INDEX_ALLOCATION (0xA0) INDX blocks ---
    movzx edx, word [FS_MFT_BUF + 20]
.finda0:
    cmp edx, 4096
    jae .done
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .done
    cmp eax, 0xA0
    je .havea0
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .done
    add edx, eax
    jmp .finda0
.havea0:
    ; walk the attribute's data runs (same decode as fs_ntfs_indx_insert)
    movzx eax, word [FS_MFT_BUF + rdx + 0x20]
    add eax, edx
    mov [fs_run_ptr], eax
    mov dword [fs_run_lcn], 0
.run_loop:
    mov eax, [fs_run_ptr]
    movzx ecx, byte [FS_MFT_BUF + rax]
    test cl, cl
    jz .done
    inc eax
    mov ebx, ecx
    and ebx, 0x0F
    mov edx, ecx
    shr edx, 4
    xor r8d, r8d
    xor r9d, r9d
.len:
    test ebx, ebx
    jz .lend
    movzx ecx, byte [FS_MFT_BUF + rax]
    mov esi, ecx
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec ebx
    jmp .len
.lend:
    mov [fs_run_len], r8d
    xor r8d, r8d
    xor r9d, r9d
    mov edi, edx
.off:
    test edx, edx
    jz .offd
    movzx ecx, byte [FS_MFT_BUF + rax]
    mov esi, ecx
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec edx
    jmp .off
.offd:
    test edi, edi
    jz .after                        ; sparse run: skip
    mov ecx, edi
    shl ecx, 3
    cmp ecx, 32
    jae .nosext
    mov edx, 1
    dec ecx
    shl edx, cl
    test r8d, edx
    jz .nosext
    mov ecx, edi
    shl ecx, 3
    mov edx, 0xFFFFFFFF
    shl edx, cl
    or r8d, edx
.nosext:
    mov [fs_run_ptr], eax
    add [fs_run_lcn], r8d
.blk_loop:
    cmp dword [fs_run_len], 0
    jle .run_loop
    mov eax, [fs_run_lcn]
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    mov [fs_ntfs_rec_lba], eax       ; remember for write-back
    mov edi, FS_INDX_BUF
    mov edx, [fs_indx_secs]
    call fs_read_secs
    jc .fail
    cmp dword [FS_INDX_BUF], 0x58444E49
    jne .blk_next
    mov edi, FS_INDX_BUF
    mov ecx, [fs_indx_secs]
    call fs_apply_fixup
    call fs_ntfs_rm_block
    cmp byte [fs_rm_err], 3
    je .done                         ; b-tree branch entry: bail out
    test eax, eax
    jz .blk_next
    mov eax, [fs_ntfs_rec_lba]
    call fs_ntfs_write_indx
    jc .fail
.blk_next:
    mov eax, [fs_indx_secs]
    xor edx, edx
    div dword [fs_spc]
    test eax, eax
    jnz .havecpb
    mov eax, 1
.havecpb:
    add [fs_run_lcn], eax
    sub [fs_run_len], eax
    jmp .blk_loop
.after:
    mov [fs_run_ptr], eax
    jmp .run_loop
.subnode:
    mov byte [fs_rm_err], 3
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Scan the INDX block in FS_INDX_BUF (fixup applied) and remove every
; entry matching fs_ntfs_rm_target by shifting the node tail forward.
; Returns eax=1 if the block was modified. A matching entry with a sub-node
; pointer sets fs_rm_err=3 and stops. ---
fs_ntfs_rm_block:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor r8d, r8d                     ; modified flag
    mov esi, 0x18
    add esi, [FS_INDX_BUF + 0x18 + 0]
.walk:
    movzx eax, word [FS_INDX_BUF + rsi + 12]
    test al, 0x02
    jnz .done
    movzx ecx, word [FS_INDX_BUF + rsi + 10]
    test ecx, ecx
    jz .next
    mov ecx, [FS_INDX_BUF + rsi]
    cmp ecx, [fs_ntfs_rm_target]
    jne .next
    test al, 0x01
    jnz .subnode
    movzx ecx, word [FS_INDX_BUF + rsi + 8]
    mov [fs_nre_len], ecx
    ; forward move: dst = esi, src = esi + entlen, count = node end - src
    mov eax, 0x18
    add eax, [FS_INDX_BUF + 0x18 + 4]
    mov edx, esi
    add edx, ecx
    sub eax, edx
    push rsi
    mov edi, esi
    mov esi, edx
    mov ecx, eax
    call fs_ntfs_shiftf_indx
    pop rsi
    mov eax, [fs_nre_len]
    sub [FS_INDX_BUF + 0x18 + 4], eax        ; shrink node used size
    inc byte [fs_ntfs_ent_removed]
    mov r8d, 1
    jmp .walk                        ; re-examine the shifted-in entry
.next:
    movzx eax, word [FS_INDX_BUF + rsi + 8]
    test eax, eax
    jz .done
    add esi, eax
    jmp .walk
.subnode:
    mov byte [fs_rm_err], 3
.done:
    mov eax, r8d
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; --- Overlap-safe forward byte move within FS_INDX_BUF (dst <= src):
; esi=src offset, edi=dst offset, ecx=length. ---
fs_ntfs_shiftf_indx:
    push rax
    push rdx
    push r8
    push r9
    mov r8d, esi
    mov r9d, edi
    xor eax, eax
.l:
    cmp eax, ecx
    jae .d
    mov dl, [FS_INDX_BUF + r8 + rax]
    mov [FS_INDX_BUF + r9 + rax], dl
    inc eax
    jmp .l
.d:
    pop r9
    pop r8
    pop rdx
    pop rax
    ret

; --- Free one MFT record (eax = record number): collect its non-resident
; runs, clear the header's in-use flag, clear its $MFT bitmap bit, then
; clear every collected cluster's $Bitmap bit. CF on I/O error. ---
fs_ntfs_free_record:
    mov [fs_ntfs_rm_ref], eax
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov [fs_ntfs_rec_lba], eax
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .fail
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .ok                          ; not a live FILE record: nothing to free
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    call fs_ntfs_collect_runs        ; -> FS_NTFS_RUNS / fs_ntfs_run_cnt
    and word [FS_MFT_BUF + 0x16], 0xFFFE   ; clear the in-use flag
    call fs_ntfs_write_rec
    jc .fail
    call fs_ntfs_free_mft_bit
    jc .fail
    call fs_ntfs_free_runs
    jc .fail
.ok:
    clc
    ret
.fail:
    stc
    ret

; --- Collect every data run of every non-resident attribute of the record
; in FS_MFT_BUF into FS_NTFS_RUNS as {LCN, length-in-clusters} dword pairs
; (count in fs_ntfs_run_cnt). Sparse runs own no clusters and are skipped.
; Table overflow (absurdly fragmented) sets fs_rm_err=1 and stops - the
; remaining clusters leak but the volume stays consistent. ---
fs_ntfs_collect_runs:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov dword [fs_ntfs_run_cnt], 0
    movzx edx, word [FS_MFT_BUF + 20]
.aloop:
    cmp edx, 4096
    jae .done
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .done
    cmp byte [FS_MFT_BUF + rdx + 8], 0
    je .anext                        ; resident: no clusters
    movzx eax, word [FS_MFT_BUF + rdx + 0x20]
    add eax, edx
    mov [fs_ncr_ptr], eax
    mov dword [fs_ncr_lcn], 0
.rloop:
    mov eax, [fs_ncr_ptr]
    movzx ecx, byte [FS_MFT_BUF + rax]
    test cl, cl
    jz .anext
    inc eax
    mov ebx, ecx
    and ebx, 0x0F
    shr ecx, 4
    mov [fs_nvl_offsz], ecx
    ; run length -> r8d
    xor r8d, r8d
    xor r9d, r9d
.lb:
    test ebx, ebx
    jz .ld
    movzx esi, byte [FS_MFT_BUF + rax]
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec ebx
    jmp .lb
.ld:
    mov [fs_nvl_len], r8d
    ; run offset delta -> r8d (signed)
    mov ebx, [fs_nvl_offsz]
    xor r8d, r8d
    xor r9d, r9d
.ob:
    test ebx, ebx
    jz .od
    movzx esi, byte [FS_MFT_BUF + rax]
    mov ecx, r9d
    shl esi, cl
    or r8d, esi
    add r9d, 8
    inc eax
    dec ebx
    jmp .ob
.od:
    mov [fs_ncr_ptr], eax
    mov ebx, [fs_nvl_offsz]
    test ebx, ebx
    jz .rloop                        ; sparse: no clusters, LCN unchanged
    shl ebx, 3
    cmp ebx, 32
    jae .nosext
    mov ecx, ebx
    dec ecx
    mov esi, 1
    shl esi, cl
    test r8d, esi
    jz .nosext
    mov ecx, ebx
    mov esi, 0xFFFFFFFF
    shl esi, cl
    or r8d, esi
.nosext:
    add [fs_ncr_lcn], r8d
    mov eax, [fs_ntfs_run_cnt]
    cmp eax, FS_NTFS_RUNS_MAX
    jae .overflow
    shl eax, 3
    mov ecx, [fs_ncr_lcn]
    mov [FS_NTFS_RUNS + rax], ecx
    mov ecx, [fs_nvl_len]
    mov [FS_NTFS_RUNS + rax + 4], ecx
    inc dword [fs_ntfs_run_cnt]
    jmp .rloop
.overflow:
    mov byte [fs_rm_err], 1
    jmp .done
.anext:
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .done
    add edx, eax
    jmp .aloop
.done:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Clear MFT record fs_ntfs_rm_ref's bit in $MFT's $BITMAP (record 0):
; resident bitmaps are patched in the record (and mirrored), non-resident
; ones via a sector read-modify-write mapped through the run list. CF on
; I/O error. Clobbers FS_MFT_BUF/FS_SECTOR_BUF. ---
fs_ntfs_free_mft_bit:
    mov eax, [fs_mft_lba]            ; record 0 = $MFT itself
    mov [fs_ntfs_rec_lba], eax
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .fail
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .fail
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    movzx edx, word [FS_MFT_BUF + 20]
.bloop:
    cmp edx, 4096
    jae .fail
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .fail
    cmp eax, 0xB0                    ; $BITMAP
    je .bfound
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .fail
    add edx, eax
    jmp .bloop
.bfound:
    cmp byte [FS_MFT_BUF + rdx + 8], 0
    jne .nonres
    ; resident: clear the bit in place, rewrite record 0 + its mirror
    movzx eax, word [FS_MFT_BUF + rdx + 0x14]
    add eax, edx
    mov ecx, [fs_ntfs_rm_ref]
    mov ebx, ecx
    shr ebx, 3
    cmp ebx, [FS_MFT_BUF + rdx + 0x10]      ; past the value: nothing to clear
    jae .ok
    add eax, ebx
    and ecx, 7
    movzx edx, byte [FS_MFT_BUF + rax]
    btr edx, ecx
    mov [FS_MFT_BUF + rax], dl
    call fs_ntfs_write_rec           ; fs_ntfs_rec_lba still = record 0
    jc .fail
    mov eax, [fs_mftmirr_lba]
    call fs_ntfs_flush_rec
    ret
.nonres:
    mov [fs_ntfs_tmp_attr], edx
    mov eax, [fs_ntfs_rm_ref]
    shr eax, 12                      ; bitmap sector index (4096 bits/sector)
    xor edx, edx
    div dword [fs_spc]               ; eax = VCN, edx = sector within cluster
    mov [fs_ntfs_bmp_rem], edx
    mov edx, [fs_ntfs_tmp_attr]
    call fs_ntfs_vcn_to_lcn
    jc .fail
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    add eax, [fs_ntfs_bmp_rem]
    mov [fs_ntfs_bmp_lba], eax
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
    mov eax, [fs_ntfs_rm_ref]
    and eax, 4095
    mov ecx, eax
    shr eax, 3
    and ecx, 7
    movzx edx, byte [FS_SECTOR_BUF + rax]
    btr edx, ecx
    mov [FS_SECTOR_BUF + rax], dl
    mov eax, [fs_ntfs_bmp_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    ret
.ok:
    clc
    ret
.fail:
    stc
    ret

; --- Clear the volume $Bitmap (record 6) bit of every cluster collected in
; FS_NTFS_RUNS. Bitmap sectors are mapped through record 6's $DATA run list
; and cached one at a time (read once, flushed when the walk moves on). CF
; on I/O error. Clobbers FS_MFT_BUF/FS_SECTOR_BUF. ---
fs_ntfs_free_runs:
    cmp dword [fs_ntfs_run_cnt], 0
    je .done
    mov eax, 6                       ; MFT record 6 = $Bitmap
    imul eax, [fs_rec_secs]
    add eax, [fs_mft_lba]
    mov edi, FS_MFT_BUF
    call fs_read_run
    jc .fail
    cmp dword [FS_MFT_BUF], 0x454C4946
    jne .fail
    mov edi, FS_MFT_BUF
    mov ecx, [fs_rec_secs]
    call fs_apply_fixup
    movzx edx, word [FS_MFT_BUF + 20]
.dloop:
    cmp edx, 4096
    jae .fail
    mov eax, [FS_MFT_BUF + rdx]
    cmp eax, 0xFFFFFFFF
    je .fail
    cmp eax, 0x80
    jne .dnext
    cmp byte [FS_MFT_BUF + rdx + 9], 0
    je .dfound
.dnext:
    mov eax, [FS_MFT_BUF + rdx + 4]
    test eax, eax
    jz .fail
    add edx, eax
    jmp .dloop
.dfound:
    cmp byte [FS_MFT_BUF + rdx + 8], 0
    je .fail                         ; $Bitmap's $DATA is always non-resident
    mov [fs_ntfs_bmp_attr], edx
    mov dword [fs_ntfs_bmp_secidx], 0xFFFFFFFF
    mov byte [fs_ntfs_bmp_dirty], 0
    mov dword [fs_ntfs_ri], 0
.run:
    mov eax, [fs_ntfs_ri]
    cmp eax, [fs_ntfs_run_cnt]
    jae .flush_done
    shl eax, 3
    mov ecx, [FS_NTFS_RUNS + rax]
    mov [fs_ntfs_rl_c], ecx          ; current cluster
    mov ecx, [FS_NTFS_RUNS + rax + 4]
    mov [fs_ntfs_rl_len], ecx        ; clusters remaining
.clus:
    cmp dword [fs_ntfs_rl_len], 0
    je .run_next
    mov eax, [fs_ntfs_rl_c]
    shr eax, 12                      ; bitmap sector index
    cmp eax, [fs_ntfs_bmp_secidx]
    je .have_sec
    cmp byte [fs_ntfs_bmp_dirty], 0  ; sector change: flush the old one
    je .load
    push rax
    mov eax, [fs_ntfs_bmp_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    pop rax
    jc .fail
    mov byte [fs_ntfs_bmp_dirty], 0
.load:
    mov [fs_ntfs_bmp_secidx], eax
    xor edx, edx
    div dword [fs_spc]               ; eax = VCN, edx = sector within cluster
    mov [fs_ntfs_bmp_rem], edx
    mov edx, [fs_ntfs_bmp_attr]
    call fs_ntfs_vcn_to_lcn
    jc .fail
    imul eax, [fs_spc]
    add eax, [fs_part_lba]
    add eax, [fs_ntfs_bmp_rem]
    mov [fs_ntfs_bmp_lba], eax
    mov edi, FS_SECTOR_BUF
    call fs_read_sector
    jc .fail
.have_sec:
    mov eax, [fs_ntfs_rl_c]
    and eax, 4095                    ; bit within this bitmap sector
    mov ecx, eax
    shr eax, 3
    and ecx, 7
    movzx edx, byte [FS_SECTOR_BUF + rax]
    btr edx, ecx
    mov [FS_SECTOR_BUF + rax], dl
    mov byte [fs_ntfs_bmp_dirty], 1
    inc dword [fs_ntfs_rl_c]
    dec dword [fs_ntfs_rl_len]
    jmp .clus
.run_next:
    inc dword [fs_ntfs_ri]
    jmp .run
.flush_done:
    cmp byte [fs_ntfs_bmp_dirty], 0
    je .done
    mov eax, [fs_ntfs_bmp_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
.done:
    clc
    ret
.fail:
    stc
    ret

; --- Map a VCN to an LCN through the non-resident attribute at offset edx
; in FS_MFT_BUF: eax = VCN in, eax = LCN out. CF set when the VCN is
; unmapped (sparse run, or past the last run). ---
fs_ntfs_vcn_to_lcn:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov edi, eax                     ; remaining VCN
    xor esi, esi                     ; running LCN
    movzx eax, word [FS_MFT_BUF + rdx + 0x20]
    add eax, edx                     ; run cursor
.run:
    movzx ecx, byte [FS_MFT_BUF + rax]
    test cl, cl
    jz .nomap
    inc eax
    mov ebx, ecx
    and ebx, 0x0F
    shr ecx, 4
    mov [fs_nvl_offsz], ecx
    ; run length -> r8d
    xor r8d, r8d
    xor r9d, r9d
.lb:
    test ebx, ebx
    jz .ld
    movzx edx, byte [FS_MFT_BUF + rax]
    mov ecx, r9d
    shl edx, cl
    or r8d, edx
    add r9d, 8
    inc eax
    dec ebx
    jmp .lb
.ld:
    mov [fs_nvl_len], r8d
    ; offset delta -> r8d (signed)
    mov ebx, [fs_nvl_offsz]
    xor r8d, r8d
    xor r9d, r9d
.ob:
    test ebx, ebx
    jz .od
    movzx edx, byte [FS_MFT_BUF + rax]
    mov ecx, r9d
    shl edx, cl
    or r8d, edx
    add r9d, 8
    inc eax
    dec ebx
    jmp .ob
.od:
    mov ebx, [fs_nvl_offsz]
    test ebx, ebx
    jz .check                        ; sparse run: LCN unchanged
    shl ebx, 3
    cmp ebx, 32
    jae .nosext
    mov ecx, ebx
    dec ecx
    mov edx, 1
    shl edx, cl
    test r8d, edx
    jz .nosext
    mov ecx, ebx
    mov edx, 0xFFFFFFFF
    shl edx, cl
    or r8d, edx
.nosext:
    add esi, r8d
.check:
    mov edx, [fs_nvl_len]
    cmp edi, edx
    jb .in_run
    sub edi, edx
    jmp .run
.in_run:
    cmp dword [fs_nvl_offsz], 0
    je .nomap                        ; VCN falls inside a sparse run
    lea eax, [rsi + rdi]
    clc
    jmp .out
.nomap:
    stc
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

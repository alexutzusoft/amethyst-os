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
    mov eax, (6 << 10) | (1 << 1)    ; LINK, TC=1
    or eax, r9d
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
    cmp byte [fs_is_ntfs], 0
    jne fs_ntfs_list
    cmp byte [fs_is_exfat], 0
    jne .fat32
    cmp byte [fs_is_fat32], 0
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
    shr eax, 7                       ; 128 FAT32 entries per sector
    add eax, [fs_fat_lba]
    cmp eax, [fs_fat_cached]
    je .cached
    mov [fs_fat_cached], eax
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .cached
    mov dword [fs_fat_cached], 0xFFFFFFFF
    jmp .fail
.cached:
    mov eax, [fs_cur_cluster]
    and eax, 127
    mov eax, [FS_FAT_BUF + rax*4]
    cmp byte [fs_is_exfat], 0
    jne .no_mask
    and eax, 0x0FFFFFFF
.no_mask:
    mov [fs_cur_cluster], eax
    jmp .clus_loop
.done:
    clc
    ret
.fail:
    stc
    ret

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
    je .skip
    mov al, [rsi + 11]
    test al, 0x08                    ; volume label (LFN's 0x0F includes it)
    jnz .skip
    call fs_print_entry
.skip:
    add dword [fs_entry_off], 32
    jmp .loop
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
    mov eax, 5                       ; MFT record 5 = root directory
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
    cmp byte [fs_action], 0
    je .do_print
    call fs_ntfs_match
    cmp byte [fs_cat_found], 0
    jne .walk_done
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
    mov eax, [rsi + 16 + 0x38]          ; file attribute flags (low dword)
    test eax, 0x10000000                ; directory (index present)
    jnz .no_match
    test eax, 0x10                      ; FILE_ATTRIBUTE_DIRECTORY
    jnz .no_match
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
    cmp byte [fs_action], 0
    je .do_list
    cmp byte [fs_action], 2
    je .do_echo
    call fs_cat_root
    jmp .listed
.do_list:
    call fs_list_root
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

; --- "ls"/"cat" shared handler: scan PCI for xHCI controllers and, on the
; first FAT-formatted USB mass-storage device found, either list the root
; directory or cat a file, per fs_action (0 = list, 1 = cat). ---
cmd_ls:
    mov byte [fs_action], 0
    jmp fs_scan_devices

; --- "cat <filename>" handler: rsi -> nul-terminated filename argument. ---
cmd_cat:
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
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; --- Find fs_target_name/fs_target_raw in the mounted volume's root
; directory (FAT12/16/32, exFAT or NTFS) and cat its contents. CF set on
; read error. ---
fs_cat_root:
    mov byte [fs_cat_found], 0
    cmp byte [fs_is_ntfs], 0
    jne .ntfs
    cmp byte [fs_is_exfat], 0
    jne .fat32
    cmp byte [fs_is_fat32], 0
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
    shr eax, 7
    add eax, [fs_fat_lba]
    cmp eax, [fs_fat_cached]
    je .cached
    mov [fs_fat_cached], eax
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .cached
    mov dword [fs_fat_cached], 0xFFFFFFFF
    jmp .fail
.cached:
    mov eax, [fs_cur_cluster]
    and eax, 127
    mov eax, [FS_FAT_BUF + rax*4]
    cmp byte [fs_is_exfat], 0
    jne .no_mask
    and eax, 0x0FFFFFFF
.no_mask:
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
; bytes to fs_target_name in the mounted volume's root directory. FAT32/16
; only - exFAT/NTFS and FAT12 (packed 12-bit entries, not handled here) are
; rejected to avoid corrupting the volume. Creates the file if it doesn't
; exist, or overwrites it in place (reusing its directory entry, allocating
; a fresh cluster) if it does. CF set on I/O error; "no free directory
; entry" is reported and treated as handled. ---
fs_echo_root:
    cmp byte [fs_is_ntfs], 0
    jne .unsupported
    cmp byte [fs_is_exfat], 0
    jne .unsupported
    cmp byte [fs_is_fat32], 0
    jne .fat32
    cmp byte [fs_is_fat16], 0
    je .unsupported
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
    shr eax, 7
    add eax, [fs_fat_lba]
    cmp eax, [fs_fat_cached]
    je .cached
    mov [fs_fat_cached], eax
    mov edi, FS_FAT_BUF
    call fs_read_sector
    jnc .cached
    mov dword [fs_fat_cached], 0xFFFFFFFF
    jmp .fail
.cached:
    mov eax, [fs_echo_clus]
    and eax, 127
    mov eax, [FS_FAT_BUF + rax*4]
    and eax, 0x0FFFFFFF
    mov [fs_cur_cluster], eax
    jmp .clus_loop
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
    call fs_echo_alloc
    jc .fail
    call fs_echo_write_data
    jc .fail
    call fs_echo_write_entry
    jc .fail
    clc
    ret
.fail:
    stc
    ret
.unsupported:
    mov rsi, fs_echo_unsupported_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    clc
    ret

; --- Scan the 16 directory entries in FS_SECTOR_BUF for fs_target_name
; (overwrite target) and, in the same pass, the first free (0x00 or 0xE5)
; entry (create target, recorded in fs_echo_lba/off if fs_echo_have_slot
; was still 0). CF set to stop the caller's scan: an exact name match was
; found (fs_echo_found=1) or the 0x00 end-of-directory marker was hit. ---
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
    cmp byte [fs_echo_have_slot], 0
    jne .skip
    mov eax, [fs_cur_lba]
    mov [fs_echo_lba], eax
    mov eax, [fs_entry_off]
    mov [fs_echo_off], eax
    mov byte [fs_echo_have_slot], 1
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

; --- Allocate one free FAT32/16 cluster for fs_echo_len bytes (0 bytes ->
; cluster 0, no allocation). echo's input is bounded well under one
; cluster (CMD_BUFFER_SIZE = 128 bytes vs. a minimum 512-byte cluster),
; so a single cluster always suffices - no chain-linking needed. Scans
; the FAT for the first free (0) entry starting at cluster 2, marks it
; end-of-chain, and flushes that FAT sector. Result in fs_echo_cluster.
; CF set on read/write error, "file too large" or "volume full". ---
fs_echo_alloc:
    mov dword [fs_echo_cluster], 0
    mov eax, [fs_echo_len]
    test eax, eax
    jz .done
    mov ecx, [fs_spc]
    shl ecx, 9                        ; bytes/cluster
    cmp eax, ecx
    ja .too_big
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
    mov dword [FS_FAT_BUF + rax*4], 0x0FFFFFFF   ; mark end-of-chain
    jmp .mark
.cached16:
    mov eax, [fs_cat_size]
    and eax, 255
    cmp word [FS_FAT_BUF + rax*2], 0
    jne .next
    mov word [FS_FAT_BUF + rax*2], 0xFFFF        ; mark end-of-chain
.mark:
    mov eax, [fs_cat_size]
    mov [fs_echo_cluster], eax
    mov eax, [fs_fat_cached]
    mov edi, FS_FAT_BUF
    call fs_write_sector
    jc .fail
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
.too_big:
    mov rsi, fs_echo_toobig_msg
    call print_string
    mov al, ASCII_CR
    call print_char
    stc
    ret
.fail:
    stc
    ret

; --- Write fs_echo_ptr/fs_echo_len bytes (0 bytes -> nothing to do) into
; the single cluster fs_echo_cluster, zero-padding the rest of the
; sector. CF set on write error. ---
fs_echo_write_data:
    mov eax, [fs_echo_len]
    test eax, eax
    jz .done
    mov eax, [fs_echo_cluster]
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_lba]
    mov [fs_cur_lba], eax
    mov rsi, [fs_echo_ptr]
    lea rdi, [FS_SECTOR_BUF]
    mov ecx, [fs_echo_len]
    rep movsb
    mov ecx, 512
    sub ecx, [fs_echo_len]
    jz .no_pad
    xor al, al
    rep stosb
.no_pad:
    mov eax, [fs_cur_lba]
    mov edi, FS_SECTOR_BUF
    call fs_write_sector
    jc .fail
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
    je .skip
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
    test al, 0x10                    ; directory: cat doesn't support this
    jnz .skip
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
    test byte [fs_ex_attr], 0x10     ; directory: cat doesn't support this
    jnz .skip
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

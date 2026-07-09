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

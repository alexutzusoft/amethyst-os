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

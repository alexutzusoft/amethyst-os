; AmethystOS - Stage 1
; Real mode -> Protected mode -> Long mode, then hands off to kernel.asm.
;
; This same file serves two boot paths:
;  - El Torito "no emulation" CD boot: BIOS loads the whole stage1+kernel
;    blob (KERNEL_SECTORS sectors, see tools/build.sh -boot-load-size) in
;    one shot at 0x7C00 before jumping here - no disk I/O needed.
;  - Raw HDD/USB boot (build/AmethystOS.img, written LBA 0 = this file's
;    first sector): BIOS only loads this one 512-byte sector at 0x7C00.
;    The boot sector below is therefore also a valid MBR (partition table
;    + 0x55AA signature at the standard offsets) and loads the rest of
;    the blob itself via INT 13h extended reads before continuing.
;
; Whether the rest of the blob still needs loading is detected via a canary
; value placed right after this boot sector (see `canary` below), rather
; than guessing from the BIOS-supplied boot drive number in DL: different
; BIOS/hypervisor vendors assign wildly different drive numbers to their
; El Torito CD-ROM emulation (observed directly: SeaBIOS used a value
; >=0xE0, VMware's BIOS used one indistinguishable from a real hard disk),
; so a DL-range heuristic isn't reliable. Checking whether the expected
; bytes are already there works regardless of vendor.

[BITS 16]
[ORG 0x7C00]

KERNEL_SECTORS equ 32   ; must match tools/build.sh -boot-load-size
ESP_LBA        equ 2048 ; 1MiB-aligned start of the ESP partition, raw image only
ESP_SECTORS    equ 2880 ; 1440KB FAT image / 512, raw image only
CANARY_VALUE   equ 0x5A5AA5A5

; --- Scratch area for the BIOS memory map (see detect_memory below), between
; the page-table/IDT pages the kernel claims at 0x1000-0x4FFF and this blob's
; own load address 0x7C00. Read by `sysinfo ram` in kernel.asm - keep these
; two files' copies of these equs in sync. ---
MMAP_COUNT_ADDR   equ 0x5000
MMAP_ENTRIES_ADDR equ 0x5008
MMAP_MAX_ENTRIES  equ 64

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl

    ; If the canary right after this sector already holds its expected
    ; value, the whole blob was already loaded for us (El Torito CD boot)
    ; - skip the read entirely rather than risk corrupting good memory
    ; with a read against the wrong device geometry.
    cmp dword [0x7E00], CANARY_VALUE
    je .skip_load

    mov ah, 0x42
    mov si, dap
    mov dl, [boot_drive]
    int 0x13

.skip_load:
    mov ax, 0x0003          ; set video mode 3 (80x25 text) - clears screen
    int 0x10

    call detect_memory
    call enable_a20
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1                ; set PE (protection enable) bit
    mov cr0, eax

    jmp CODE32_SEG:protected_mode_start   ; far jump flushes the prefetch queue

; --- BIOS INT 15h, EAX=E820: build a physical memory map into MMAP_ENTRIES_ADDR
; so `sysinfo ram` can report real installed RAM later - once the kernel is in
; long mode, BIOS interrupts are no longer reachable, so this has to happen
; here, before enable_a20/protected mode. ds=es=0 already (set above). ---
detect_memory:
    xor ebx, ebx
    xor bp, bp                     ; bp = entries stored so far
    mov di, MMAP_ENTRIES_ADDR
.loop:
    mov eax, 0xE820
    mov edx, 0x534D4150             ; 'SMAP'
    mov ecx, 24
    int 0x15
    jc .done                        ; carry set: unsupported, or failed on the first call
    cmp eax, 0x534D4150
    jne .done

    mov eax, [di + 8]                ; length low dword
    or eax, [di + 12]                ; | length high dword - skip bogus zero-length entries
    jz .skip

    cmp bp, MMAP_MAX_ENTRIES
    jae .done
    inc bp
    add di, 24
.skip:
    test ebx, ebx
    jz .done                        ; ebx=0 after this call: that was the last entry
    jmp .loop
.done:
    movzx eax, bp
    mov [MMAP_COUNT_ADDR], eax
    ret

; --- Fast A20 gate enable (via system control port 0x92) ---
enable_a20:
    in al, 0x92
    or al, 2
    out 0x92, al
    ret

boot_drive: db 0

; Disk Address Packet for INT 13h AH=42h: loads the rest of the blob
; (sectors 1..KERNEL_SECTORS-1) right after this already-loaded sector.
dap:
    db 0x10                 ; packet size
    db 0                     ; reserved
    dw KERNEL_SECTORS - 1    ; sector count
    dw 0x7E00                ; destination offset
    dw 0x0000                ; destination segment
    dq 1                     ; starting LBA

; --- MBR partition table + boot signature, at the standard fixed offsets.
; Only used/read for the raw-disk boot path (Rufus/dd write of
; build/AmethystOS.img) so tools like fdisk show a sane bootable layout;
; the boot code above jumps here unconditionally regardless of contents,
; so this table isn't load-bearing for booting itself. ---
times 446 - ($ - $$) db 0

    ; Partition 1 is deliberately left unused/zeroed: the region it would
    ; describe (LBA 0, the boot+kernel blob) starts at the MBR sector
    ; itself, and no legitimate partition ever overlaps the MBR. Declaring
    ; a real partition there caused some BIOS firmware's boot-device
    ; enumeration to hang/fault outright on real hardware. Booting doesn't
    ; need this entry anyway - BIOS jumps to 0x7C00 unconditionally regardless
    ; of partition table contents.
    times 16 db 0

    db 0x00                          ; partition 2: ESP, not marked bootable
    db 0xFE, 0xFF, 0xFF
    db 0xEF                          ; type: EFI System Partition
    db 0xFE, 0xFF, 0xFF
    dd ESP_LBA
    dd ESP_SECTORS

    times 32 db 0                    ; partitions 3 and 4: unused

    dw 0xAA55                        ; boot signature

; Canary checked at boot: if this already holds CANARY_VALUE, the whole
; blob (this second sector onward) was already loaded for us.
canary: dd CANARY_VALUE

; --- Global Descriptor Table: null, flat 32-bit code/data, flat 64-bit code ---
gdt_start:
gdt_null:
    dq 0x0

gdt_code32:
    dw 0xFFFF        ; limit low
    dw 0x0000        ; base low
    db 0x00          ; base mid
    db 10011010b     ; access: present, ring0, code, executable, readable
    db 11001111b     ; flags: 4K granularity, 32-bit + limit high
    db 0x00          ; base high

gdt_data32:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b     ; access: present, ring0, data, writable
    db 11001111b
    db 0x00

gdt_code64:
    dw 0x0000
    dw 0x0000
    db 0x00
    db 10011010b     ; access: present, ring0, code, executable, readable
    db 00100000b     ; flags: long-mode code segment (L bit set)
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE32_SEG equ gdt_code32 - gdt_start
DATA32_SEG equ gdt_data32 - gdt_start
CODE64_SEG equ gdt_code64 - gdt_start

; --- Page table locations (identity-mapped low memory scratch area) ---
PML4_ADDR equ 0x1000
PDPT_ADDR equ 0x2000
PD_ADDR   equ 0x3000

%include "src/kernel/kernel.asm"

times 16384 - ($ - $$) db 0

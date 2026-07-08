; AmethystOS - UEFI boot stub.
; Assembled separately from stage1.asm/kernel.asm with `nasm -f win64` and
; linked into a PE32+ EFI application (BOOTX64.EFI) by tools/build.sh, using
; the mingw-w64 linker purely as a PE linker (no C runtime/libc involved).
;
; Entry point uses the Microsoft x64 calling convention, NOT System V like
; the rest of this project's (nonexistent, since it's all freestanding asm)
; calling conventions would otherwise imply: args in RCX, RDX, R8, R9 (not
; RDI, RSI, ...), and every call site must reserve 32 bytes of "shadow
; space" on the stack for the callee, even though nothing here uses it.
;
; This is a standalone proof that the hybrid ISO's UEFI entry point is
; picked up by real UEFI firmware - it does not yet touch VGA, IDT, or any
; of kernel.asm. It prints via the firmware's own console protocol and
; halts. Bridging this to the real kernel is future work.

[BITS 64]

section .text
global efi_main

; efi_main(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
;   RCX = ImageHandle (unused)
;   RDX = SystemTable
efi_main:
    sub rsp, 0x28           ; 32-byte shadow space + keep rsp 16-aligned for calls

    mov rbx, rdx             ; rbx (non-volatile) = SystemTable, survives the call below

    ; EFI_SYSTEM_TABLE.ConOut is at offset 0x40 (24-byte EFI_TABLE_HEADER,
    ; then FirmwareVendor ptr, FirmwareRevision+pad, ConsoleInHandle, ConIn,
    ; ConsoleOutHandle, then ConOut)
    mov rax, [rbx + 0x40]    ; rax = ConOut (EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*)

    ; EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL.OutputString is the 2nd function
    ; pointer (after Reset), at offset 0x08
    mov rcx, rax              ; This
    lea rdx, [rel msg]
    call [rax + 0x08]         ; ConOut->OutputString(ConOut, msg)

.halt:
    hlt
    jmp .halt

section .data
msg: dw __utf16__("AmethystOS (UEFI stage)"), 13, 10, 0

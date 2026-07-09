; AmethystOS Kernel - everything from protected mode onward.
; %include'd by stage1.asm right after the GDT/segment equs it needs,
; and assembled into the same flat binary (no separate linking step).

; --- VGA text-mode framebuffer layout ---
VGA_MEM       equ 0xB8000
VGA_COLS      equ 80
VGA_ROWS      equ 25
VGA_ROW_BYTES equ VGA_COLS * 2
VGA_SIZE      equ VGA_ROW_BYTES * VGA_ROWS      ; 4000: one byte past the last cell
VGA_LAST_ROW  equ VGA_ROW_BYTES * (VGA_ROWS - 1) ; 3840: start of the bottom row
VGA_ATTR      equ 0x0F                            ; white on black
VGA_ATTR_SEL  equ 0xF0                            ; inverted: black on white (selection highlight)

HELP_NAME_WIDTH equ 10

; --- 8259 PIC ports/values ---
PIC1_CMD  equ 0x20
PIC1_DATA equ 0x21
PIC2_CMD  equ 0xA0
PIC2_DATA equ 0xA1
PIC_EOI            equ 0x20
ICW1_INIT          equ 0x11
PIC1_VECTOR_OFFSET equ 0x20
PIC2_VECTOR_OFFSET equ 0x28
ICW3_MASTER        equ 0x04
ICW3_SLAVE         equ 0x02
ICW4_8086          equ 0x01
PIC1_MASK          equ 0xF8   ; unmask IRQ0 (timer) + IRQ1 (keyboard) + IRQ2 (slave cascade)
PIC2_MASK_ALL      equ 0xEF   ; unmask IRQ12 (PS/2 mouse) on the slave

IRQ0_VECTOR  equ 0x20
IRQ1_VECTOR  equ 0x21
IRQ12_VECTOR equ 0x2C

; --- Only the first 1GB is identity-mapped (see protected_mode_start), and
; there is no page-fault handler - so any pointer read out of an ACPI table
; (which can be garbage, e.g. a revision-0 RSDP's unused extended fields)
; must be bounds-checked before it is ever dereferenced, or a bad value
; triple-faults real hardware. ---
IDENTITY_MAP_LIMIT equ 0x40000000

; --- BIOS memory map captured by stage1.asm's detect_memory (real mode,
; before the switch to protected/long mode - BIOS interrupts aren't
; reachable from here). Keep these equs in sync with stage1.asm's copy. ---
MMAP_COUNT_ADDR   equ 0x5000
MMAP_ENTRIES_ADDR equ 0x5008
MMAP_MAX_ENTRIES  equ 64

; --- 8042 keyboard controller ports/values ---
KBD_DATA_PORT equ 0x60
KBD_CMD_PORT  equ 0x64
KBD_CMD_READ_CFG        equ 0x20
KBD_CMD_WRITE_CFG        equ 0x60
KBD_IRQ1_ENABLE_BIT      equ 0x01
KBD_STATUS_OUTPUT_FULL   equ 0x01
KBD_STATUS_INPUT_FULL    equ 0x02
KBD_BREAK_BIT      equ 0x80
KBD_SCANCODE_MASK  equ 0x7F
SC_LSHIFT   equ 0x2A
SC_RSHIFT   equ 0x36
SC_CAPSLOCK equ 0x3A
SC_CTRL     equ 0x1D   ; LCtrl (bare) and RCtrl (0xE0-prefixed) share this base code
SC_LEFT     equ 0x4B   ; only valid 0xE0-prefixed (set-1 arrows are all extended codes)
SC_RIGHT    equ 0x4D
SC_UP       equ 0x48
SC_DOWN     equ 0x50

; --- PS/2 aux (mouse) port, cursor experimental feature ---
PS2_CMD_ENABLE_AUX          equ 0xA8
PS2_CMD_WRITE_AUX           equ 0xD4
MOUSE_CMD_ENABLE_REPORTING  equ 0xF4
MOUSE_CMD_DISABLE_REPORTING equ 0xF5
KBD_IRQ12_ENABLE_BIT        equ 0x02
KBD_STATUS_AUX_DATA         equ 0x20
MOUSE_ALWAYS1_BIT equ 0x08
MOUSE_SIGN_X      equ 0x10
MOUSE_SIGN_Y      equ 0x20
MOUSE_OVERFLOW_X  equ 0x40
MOUSE_OVERFLOW_Y  equ 0x80
MOUSE_BTN_LEFT    equ 0x01
MOUSE_BTN_RIGHT   equ 0x02
MOUSE_SCROLL_THRESHOLD equ 24
MOUSE_CMD_SET_SAMPLE_RATE equ 0xF3
MOUSE_CMD_GET_DEVICE_ID   equ 0xF2

HIST_ROWS equ 200
KBD_EXTENDED_PREFIX equ 0xE0

; --- CRT controller (hardware cursor) ports/registers ---
CRTC_INDEX       equ 0x3D4
CRTC_DATA        equ 0x3D5
CRTC_CURSOR_LOW  equ 0x0F
CRTC_CURSOR_HIGH equ 0x0E
CRTC_CURSOR_START equ 0x0A
CRTC_CURSOR_DISABLE_BIT equ 0x20

; --- ASCII control characters ---
ASCII_CR equ 0x0D
ASCII_BS equ 0x08

CMD_BUFFER_SIZE equ 128
EXEC_BUFFER_SIZE equ 256
CMD_HISTORY_ENTRIES equ 16

PIT_HZ equ 100
PIT_DIVISOR equ 11931   ; 1193182 / PIT_HZ, rounded


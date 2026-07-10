echo_cmd_end:
run_cmd db "run"
run_cmd_end:
clear_cmd db "clear"
clear_cmd_end:
help_cmd db "help"
help_cmd_end:
reboot_cmd db "reboot"
reboot_cmd_end:
halt_cmd db "halt"
halt_cmd_end:
mem_cmd db "mem"
mem_cmd_end:
peek_cmd db "peek"
peek_cmd_end:
poke_cmd db "poke"
poke_cmd_end:
cpuid_cmd db "cpuid"
cpuid_cmd_end:
uptime_cmd db "uptime"
uptime_cmd_end:
shutdown_cmd db "shutdown"
shutdown_cmd_end:
acpi_cmd db "acpi"
acpi_cmd_end:
color_cmd db "color"
color_cmd_end:
sysinfo_cmd db "sysinfo"
sysinfo_cmd_end:
date_cmd db "date"
date_cmd_end:
time_cmd db "time"
time_cmd_end:
draw_cmd db "draw"
draw_cmd_end:
calc_cmd db "calc"
calc_cmd_end:
cursor_cmd db "cursor"
cursor_cmd_end:
usb_cmd db "usb"
usb_cmd_end:
unknown_msg db "Unknown command: ", 0
run_bad_hex_msg db "Invalid hex byte", 0
run_too_long_msg db "Too many bytes for exec_buffer", 0
reboot_msg db "Rebooting...", 0
halt_msg db "Halted.", 0
shutdown_fail_msg db "Shutdown failed - it's now safe to turn off your computer.", 0
uptime_suffix db " s", 0
rsdp_sig db "RSD PTR "

acpi_rsdp_msg db "RSDP: ", 0
acpi_rev_msg db "ACPI revision: ", 0
acpi_fadt_msg db "FADT: ", 0
acpi_via_xsdt_msg db "(via XSDT) ", 0
acpi_via_rsdt_msg db "(via RSDT) ", 0
acpi_via_scan_msg db "(via scan) ", 0
acpi_pm1a_msg db "PM1a_CNT: ", 0
acpi_pm1b_msg db "PM1b_CNT: ", 0
acpi_space_msg db " ", 0
acpi_io_msg db "(io)", 0
acpi_mem_msg db "(mmio)", 0
acpi_none_msg db "none", 0
acpi_enabled_msg db "ACPI already enabled: ", 0
acpi_yes_msg db "yes", 0
acpi_no_msg db "no", 0
acpi_dsdt_msg db "DSDT: ", 0
acpi_s5_msg db "_S5: ", 0
acpi_found_msg db "found ", 0
acpi_notfound_msg db "not found", 0
acpi_typa_msg db "SLP_TYPa=", 0
acpi_typb_msg db " SLP_TYPb=", 0
acpi_valid_msg db " (valid)", 0
acpi_invalid_msg db " (INVALID)", 0
acpi_badpkg_msg db "_S5 package decode failed (unexpected AML structure)", 0

si_cpu_str db "cpu", 0
si_ram_str db "ram", 0
si_gpu_str db "gpu", 0
si_general_str db "general", 0

sysinfo_cpu_hdr db "-- CPU --", 0
sysinfo_vendor_msg db "Vendor: ", 0
sysinfo_brand_msg db "Model: ", 0
sysinfo_family_msg db "Family: ", 0
sysinfo_model_msg db " Model: ", 0
sysinfo_stepping_msg db " Stepping: ", 0
sysinfo_cores_msg db "Logical CPUs: ", 0
sysinfo_cores_unknown_msg db "unknown (no MADT)", 0
sysinfo_unknown_msg db "unknown", 0

sysinfo_ram_hdr db "-- RAM --", 0
sysinfo_ram_unavailable_msg db "not available (BIOS E820 unsupported)", 0
sysinfo_ram_total_msg db "Usable RAM: ", 0
sysinfo_mb_msg db " MB", 0
sysinfo_ram_regions_msg db "Memory map regions: ", 0

sysinfo_gpu_hdr db "-- GPU --", 0
sysinfo_gpu_found_msg db "PCI ", 0
sysinfo_gpu_bus_msg db " bus ", 0
sysinfo_gpu_dev_msg db " dev ", 0
sysinfo_gpu_func_msg db " func ", 0
sysinfo_gpu_id_msg db " id ", 0
sysinfo_gpu_none_msg db "no display controller found on the PCI bus", 0

; Preset color name table: {name_ptr, name_len, attr_byte}, 17 bytes each,
; ends with a zero name_ptr. Attr byte = white background (0x7) foreground,
; matching VGA_ATTR's black-background scheme (0x0_).
color_names:
    dq color_red,    color_red_end - color_red,    0x04
    dq color_green,  color_green_end - color_green, 0x02
    dq color_blue,   color_blue_end - color_blue,   0x01
    dq color_yellow, color_yellow_end - color_yellow, 0x0E
    dq color_white,  color_white_end - color_white, 0x0F
    dq 0

color_red db "red"
color_red_end:
color_green db "green"
color_green_end:
color_blue db "blue"
color_blue_end:
color_yellow db "yellow"
color_yellow_end:
color_white db "white"
color_white_end:

null_idt_descriptor:
    dw 0
    dq 0

cursor_pos dq 0
text_attr db VGA_ATTR
xhci_cmd_index dd 0
xhci_evt_index dd 0
xhci_evt_cycle db 1
xhci_speed dd 0
xhci_mps dd 0
xhci_xfer_cycle db 1
cmd_len db 0
cmd_buffer times CMD_BUFFER_SIZE db 0
timer_ticks dq 0
cpuid_vendor times 13 db 0
cpu_brand times 49 db 0
dec_buffer times 21 db 0
pm1a_cnt dq 0
pm1b_cnt dq 0
pm1a_mmio db 0
pm1b_mmio db 0
dsdt_addr dq 0
smi_cmd dq 0
acpi_enable_val db 0
slp_typa dq 0
slp_typb dq 0

; Scratch buffer for `run`'s raw machine code - no execute-permission
; distinction is set up in the page tables, so this is directly callable.
exec_buffer times EXEC_BUFFER_SIZE db 0
shift_state db 0
caps_lock db 0
ctrl_state db 0
extended_pending db 0
cmd_cursor db 0
sel_active db 0
sel_anchor db 0
cmd_render_len db 0
cmd_history times CMD_HISTORY_ENTRIES * CMD_BUFFER_SIZE db 0
cmd_history_len times CMD_HISTORY_ENTRIES db 0
cmd_history_write dw 0
cmd_history_count dw 0
cmd_history_pos dw 0
cmd_history_saved times CMD_BUFFER_SIZE db 0
cmd_history_saved_len db 0
line_start_pos dq 0
scroll_offset dw 0
cursor_start_shape db 0
hist_write dw 0
hist_count dw 0
history_buffer times HIST_ROWS * VGA_ROW_BYTES db 0
live_shadow times VGA_SIZE db 0

; Experimental mouse cursor state (see `cursor` command / mouse_isr)
cursor_enabled db 0
mouse_x db 0
mouse_y db 0
mouse_packet times 4 db 0
mouse_packet_idx db 0
mouse_packet_size db 3
mouse_has_wheel db 0
mouse_prev_buttons db 0
mouse_scroll_accum dw 0
cursor_cell_valid db 0
cursor_cell_saved_attr db 0

; US QWERTY set-1 scancode -> lowercase ASCII (0 = unmapped/ignored)
scancode_table:
    db 0, 0, '1', '2', '3', '4', '5', '6', '7', '8'
    db '9', '0', '-', '=', 0x08, 0
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0x0D, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', 39, '`', 0
    db 0x5C, 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0
    db 0, 0, ' '
scancode_table_end:

; Same layout as scancode_table, but for shift held (uppercase letters,
; shifted symbols). Caps-lock-only adjustment is applied separately in
; keyboard_isr so caps lock doesn't also shift symbols/digits.
shifted_scancode_table:
    db 0, 0, '!', '@', '#', '$', '%', '^', '&', '*'
    db '(', ')', '_', '+', 0x08, 0
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0x0D, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0
    db '|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0
    db 0, 0, ' '

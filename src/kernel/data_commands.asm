command_table:
    dq echo_cmd, echo_cmd_end - echo_cmd, cmd_echo
    dq run_cmd, run_cmd_end - run_cmd, cmd_run
    dq clear_cmd, clear_cmd_end - clear_cmd, cmd_clear
    dq help_cmd, help_cmd_end - help_cmd, cmd_help
    dq reboot_cmd, reboot_cmd_end - reboot_cmd, cmd_reboot
    dq halt_cmd, halt_cmd_end - halt_cmd, cmd_halt
    dq mem_cmd, mem_cmd_end - mem_cmd, cmd_mem
    dq peek_cmd, peek_cmd_end - peek_cmd, cmd_peek
    dq poke_cmd, poke_cmd_end - poke_cmd, cmd_poke
    dq cpuid_cmd, cpuid_cmd_end - cpuid_cmd, cmd_cpuid
    dq uptime_cmd, uptime_cmd_end - uptime_cmd, cmd_uptime
    dq shutdown_cmd, shutdown_cmd_end - shutdown_cmd, cmd_shutdown
    dq acpi_cmd, acpi_cmd_end - acpi_cmd, cmd_acpi
    dq color_cmd, color_cmd_end - color_cmd, cmd_color
    dq sysinfo_cmd, sysinfo_cmd_end - sysinfo_cmd, cmd_sysinfo
    dq date_cmd, date_cmd_end - date_cmd, cmd_date
    dq time_cmd, time_cmd_end - time_cmd, cmd_time
    dq cursor_cmd, cursor_cmd_end - cursor_cmd, cmd_cursor_toggle
    dq draw_cmd, draw_cmd_end - draw_cmd, cmd_draw
    dq calc_cmd, calc_cmd_end - calc_cmd, cmd_calc
    dq usb_cmd, usb_cmd_end - usb_cmd, cmd_usb
    dq ls_cmd, ls_cmd_end - ls_cmd, cmd_ls
    dq dir_cmd, dir_cmd_end - dir_cmd, cmd_ls
    dq cat_cmd, cat_cmd_end - cat_cmd, cmd_cat
    dq 0

command_descriptions:
    dq desc_echo,     desc_echo_end - desc_echo
    dq desc_run,      desc_run_end - desc_run
    dq desc_clear,    desc_clear_end - desc_clear
    dq desc_help,     desc_help_end - desc_help
    dq desc_reboot,   desc_reboot_end - desc_reboot
    dq desc_halt,     desc_halt_end - desc_halt
    dq desc_mem,      desc_mem_end - desc_mem
    dq desc_peek,     desc_peek_end - desc_peek
    dq desc_poke,     desc_poke_end - desc_poke
    dq desc_cpuid,    desc_cpuid_end - desc_cpuid
    dq desc_uptime,   desc_uptime_end - desc_uptime
    dq desc_shutdown, desc_shutdown_end - desc_shutdown
    dq desc_acpi,     desc_acpi_end - desc_acpi
    dq desc_color,    desc_color_end - desc_color
    dq desc_sysinfo,  desc_sysinfo_end - desc_sysinfo
    dq desc_date,     desc_date_end - desc_date
    dq desc_time,     desc_time_end - desc_time
    dq desc_cursor,   desc_cursor_end - desc_cursor
    dq desc_draw,     desc_draw_end - desc_draw
    dq desc_calc,     desc_calc_end - desc_calc
    dq desc_usb,      desc_usb_end - desc_usb
    dq desc_ls,       desc_ls_end - desc_ls
    dq desc_dir,      desc_dir_end - desc_dir
    dq desc_cat,      desc_cat_end - desc_cat

desc_echo db "print text, or write it to a file: echo <text> [> <filename>] (FAT)"
desc_echo_end:
desc_run db "assemble and execute raw hex machine code: run <hex bytes>"
desc_run_end:
desc_clear db "clear the screen"
desc_clear_end:
desc_help db "list available commands"
desc_help_end:
desc_reboot db "reboot the machine"
desc_reboot_end:
desc_halt db "halt the CPU"
desc_halt_end:
desc_mem db "hexdump memory: mem <addr> <len>"
desc_mem_end:
desc_peek db "read a byte from memory: peek <addr>"
desc_peek_end:
desc_poke db "write a byte to memory: poke <addr> <value>"
desc_poke_end:
desc_cpuid db "run CPUID: cpuid [leaf]"
desc_cpuid_end:
desc_uptime db "show system uptime"
desc_uptime_end:
desc_shutdown db "power off the machine"
desc_shutdown_end:
desc_acpi db "probe and display ACPI power-management tables"
desc_acpi_end:
desc_color db "set text color: color <red|green|blue|yellow|white|HH>"
desc_color_end:
desc_sysinfo db "show hardware info: sysinfo [cpu|ram|gpu|general]"
desc_sysinfo_end:
desc_date db "show the current date"
desc_date_end:
desc_time db "show the current time"
desc_time_end:
desc_cursor db "experimental: toggle the PS/2 mouse cell cursor: cursor <on|off>"
desc_cursor_end:
desc_draw db "show a fun ASCII drawing: draw [gem|cat|amethyst_text]"
desc_draw_end:
desc_calc db "basic arithmetic: calc <a> <+|-|*|/|%|sqrt> [b]"
desc_calc_end:
desc_usb db "scan PCI for USB host controllers (UHCI/OHCI/EHCI/xHCI)"
desc_usb_end:
desc_ls db "list files on the first USB drive found (FAT, read-only)"
desc_ls_end:
desc_dir db "same as ls"
desc_dir_end:
desc_cat db "print a file's contents: cat <filename> (FAT, read-only)"
desc_cat_end:

help_sep db " - ", 0
color_usage_msg db "Usage: color <red|green|blue|yellow|white|HH>", 0
sysinfo_usage_msg db "Usage: sysinfo <cpu|ram|gpu|general>", 0
cursor_usage_msg db "Usage: cursor <on|off>", 0
cursor_on_msg db "Cursor on (experimental).", 0
cursor_off_msg db "Cursor off.", 0

calc_usage_msg db "Usage: calc <a> <+|-|*|/|%|sqrt> [b]", 0
calc_divzero_msg db "Division by zero", 0
calc_neg_sqrt_msg db "Cannot take sqrt of a negative number", 0
calc_sqrt_str db "sqrt", 0

draw_usage_msg db "Usage: draw <gem|cat|amethyst_text>", 0
draw_gem_str db "gem", 0
draw_cat_str db "cat", 0
draw_logo_str db "amethyst_text", 0

draw_art_gem db "    /\  ", ASCII_CR
             db "   /  \ ", ASCII_CR
             db "  / /\ \", ASCII_CR
             db " /_/  \_\", ASCII_CR
             db " \ \  / /", ASCII_CR
             db "  \ \/ / ", ASCII_CR
             db "   \  /  ", ASCII_CR
             db "    \/   Amethyst", ASCII_CR, 0

draw_art_cat db " /\_/\ ", ASCII_CR
             db "( o.o )", ASCII_CR
             db " > ^ < ", ASCII_CR, 0

draw_art_logo db "   _              _   _               _   ", ASCII_CR
              db "  /_\  _ __  ___ | |_| |__ _  _ ___ _| |_ ", ASCII_CR
              db " / _ \| '  \/ -_)|  _| '_ \ || (_-<  _  |", ASCII_CR
              db "/_/ \_\_|_|_\___| \__|_.__/\_, /__/\____|", ASCII_CR
              db "                           |__/           ", ASCII_CR, 0

usb_header_msg db "Scanning PCI for USB controllers...", 0
usb_none_msg db "No USB controllers found.", 0
usb_bus_msg db "bus ", 0
usb_dev_msg db " dev ", 0
usb_func_msg db " func ", 0
usb_vendor_msg db " vendor 0x", 0
usb_device_msg db " device 0x", 0
usb_type_msg db " type ", 0
usb_type_uhci_msg db "UHCI (USB1.1)", 0
usb_type_ohci_msg db "OHCI (USB1.1)", 0
usb_type_ehci_msg db "EHCI (USB2.0)", 0
usb_type_xhci_msg db "xHCI (USB3.x)", 0
usb_type_unknown_msg db "unknown", 0
usb_dev_found_msg db "  device: class 0x", 0
usb_name_msg db "  name: ", 0
usb_vendor_name_msg db "  vendor: ", 0
xhci_dbg_csz_msg db "  xhci: 64-byte contexts unsupported, skipping", 0
xhci_dbg_reset_msg db "  xhci: reset/run timeout, skipping", 0
xhci_dbg_scratch_msg db "  xhci: too many scratchpad buffers, skipping", 0
xhci_dbg_timeout_msg db "  event wait timeout", 0

fs_no_dev_msg db "No USB mass-storage device found.", 0
fs_xfer_err_msg db "USB storage transfer error.", 0
fs_no_fat_msg db "No FAT/exFAT/NTFS filesystem found on the USB device.", 0
fs_dir_tag_msg db "<DIR>", 0
cat_usage_msg db "Usage: cat <filename>", 0
fs_cat_notfound_msg db "cat: file not found", 0
echo_redir_usage_msg db "Usage: echo <text> > <filename>", 0
fs_echo_unsupported_msg db "echo: only FAT16/32/exFAT write is supported (found NTFS, or FAT12 volume)", 0
fs_echo_nospace_msg db "echo: no free directory entry or cluster", 0
fs_echo_toobig_msg db "echo: text too large for one cluster", 0
fs_echo_name_toobig_msg db "echo: filename too long for exFAT write (max 15 chars)", 0
fs_echo_ntfs_bigdir_msg db "echo: NTFS root dir too large for write (has INDEX_ALLOCATION)", 0
fs_echo_ntfs_err_msg db "echo: NTFS write failed", 0
fs_dbg_echo_msg db "[ntfs] echo len=", 0
fs_dbg_search_msg db "[ntfs] search found=", 0
fs_dbg_ow_msg db "[ntfs] overwrite ref=", 0
fs_dbg_ow_data_msg db "[ntfs] data attr off=", 0
fs_dbg_ow_wrote_msg db "[ntfs] overwrite wrote used=", 0
fs_dbg_create_msg db "[ntfs] create path", 0
fs_dbg_alloc_msg db "[ntfs] alloc ref=", 0
fs_dbg_built_msg db "[ntfs] built record used=", 0
fs_dbg_insert_msg db "[ntfs] index insert entlen=", 0
fs_dbg_indx_msg db "[ntfs] indx-alloc insert entlen=", 0
fs_dbg_bigdir_msg db "[ntfs] bigdir (has 0xA0)", 0
fs_dbg_ok_msg db "[ntfs] ok", 0


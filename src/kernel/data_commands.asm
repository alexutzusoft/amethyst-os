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

desc_echo db "print the given text"
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


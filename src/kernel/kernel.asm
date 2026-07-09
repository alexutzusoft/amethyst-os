; AmethystOS Kernel - everything from protected mode onward.
; %include'd by stage1.asm right after the GDT/segment equs it needs,
; and assembled into the same flat binary (no separate linking step).
; Split into topic files below; order matters (equs/entry first, data last).

%include "src/kernel/defs.inc.asm"
%include "src/kernel/entry.asm"
%include "src/kernel/interrupts.asm"
%include "src/kernel/input.asm"
%include "src/kernel/commands_basic.asm"
%include "src/kernel/commands_sysinfo.asm"
%include "src/kernel/commands_acpi.asm"
%include "src/kernel/commands_misc.asm"
%include "src/kernel/data_commands.asm"
%include "src/kernel/display.asm"
%include "src/kernel/data_strings.asm"

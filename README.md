# AmethystOS

A tiny x86-64 operating system written in pure assembly (NASM), booting
from real mode through protected mode into 64-bit long mode with no
bootloader dependencies beyond the code in this repo.

Boots via legacy BIOS (MBR/El Torito) or UEFI, into a simple text-mode
shell with commands like `help`, `echo`, `clear`, `run`, `calc`, `mem`,
`peek`/`poke`, `cpuid`, `acpi`, `sysinfo`, `uptime`, `date`/`time`, `color`,
`cursor`, `draw`, and `reboot`/`halt`/`shutdown`.

## Build & run (QEMU)

```
tools/build.sh
tools/run.sh
```

`build.sh` produces `build/AmethystOS.iso` (hybrid BIOS+UEFI, for
`-cdrom`/optical boot) and `build/AmethystOS.img` (raw disk image for
`dd`/Rufus-style USB writing).

Other run scripts:

- `tools/run.sh` - boot the ISO under BIOS (default QEMU path)
- `tools/run-raw.sh` - boot the raw `.img` as a disk, exercising the MBR path directly
- `tools/run-uefi.sh` - boot the ISO under OVMF (real UEFI firmware)

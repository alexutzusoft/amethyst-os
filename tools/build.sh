#!/usr/bin/env bash
# Assembles the bootloader and packs it into a hybrid BIOS+UEFI bootable ISO.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p build/iso

# --- Legacy BIOS path: unchanged flat real-mode blob, auto-loaded by El
# Torito "no emulation" at 0x7C00 (see stage1.asm/kernel.asm). ---
nasm -f bin src/boot/stage1.asm -o build/boot.bin
cp build/boot.bin build/iso/boot.bin

# --- UEFI path: assemble uefi.asm to a COFF object, then link it into a
# PE32+ EFI application. x86_64-w64-mingw32-ld is used purely as a PE
# linker here - no C runtime or libc is involved. ---
nasm -f win64 src/boot/uefi.asm -o build/uefi.obj
x86_64-w64-mingw32-ld -nostdlib -shared -Bsymbolic -subsystem 10 \
    -e efi_main -o build/BOOTX64.EFI build/uefi.obj

# Pack BOOTX64.EFI into a small FAT floppy image at the path UEFI firmware
# looks for by default (/EFI/BOOT/BOOTX64.EFI on the ESP). Built with
# mtools so no loopback mount (and thus no root) is needed.
rm -f build/iso/esp.img
mformat -C -f 1440 -i build/iso/esp.img ::
mmd -i build/iso/esp.img ::/EFI ::/EFI/BOOT
mcopy -i build/iso/esp.img build/BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI

# Also mirror BOOTX64.EFI into /EFI/BOOT on the ISO9660 tree itself (some
# USB-imaging tools, notably on Windows, expect this even though the FAT
# image above is what UEFI firmware actually boots from).
mkdir -p build/iso/EFI/BOOT
cp build/BOOTX64.EFI build/iso/EFI/BOOT/BOOTX64.EFI

# --- Combine both into one ISO: a BIOS El Torito entry (-b) plus a UEFI
# El Torito entry (-eltorito-alt-boot -e) pointing at the FAT image. This
# is for optical media / QEMU -cdrom and OVMF -cdrom testing only - El
# Torito's BIOS entry only works when the medium is read as an optical
# disc. (We previously tried xorriso -isohybrid-mbr to also make this same
# .iso raw-USB-bootable, but that patches in ISOLINUX's own hybrid MBR,
# which looks for a file literally named isolinux.bin and fails outright
# against our own boot.bin - see build/amethyst-os.img below instead.) ---
xorriso -as mkisofs -o build/amethyst-os.iso \
    -b boot.bin -no-emul-boot -boot-load-size 128 \
    -eltorito-alt-boot \
    -e esp.img -no-emul-boot \
    build/iso

echo "Built build/amethyst-os.iso"

# --- Raw disk image for USB (Rufus DD mode / dd): our own MBR (boot.bin's
# first sector, see stage1.asm) placed directly at LBA 0 so BIOS finds it
# on a raw read, followed by the 1MiB-aligned ESP partition for UEFI raw-
# disk boot. Built from scratch (not reusing the ISO9660 layout above)
# since boot.bin needs to physically BE sector 0 of the medium. ---
cp build/boot.bin build/amethyst-os.img
truncate -s 1M build/amethyst-os.img
cat build/iso/esp.img >> build/amethyst-os.img

echo "Built build/amethyst-os.img"

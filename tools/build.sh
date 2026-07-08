#!/usr/bin/env bash
# Assembles the bootloader and packs it into a bootable ISO.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mkdir -p build/iso
nasm -f bin src/boot/stage1.asm -o build/boot.bin
cp build/boot.bin build/iso/boot.bin
xorriso -as mkisofs -o build/AmethystOS.iso \
    -b boot.bin -no-emul-boot -boot-load-size 16 \
    build/iso

echo "Built build/AmethystOS.iso"

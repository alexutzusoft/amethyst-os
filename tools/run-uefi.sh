#!/usr/bin/env bash
# Boots the built ISO in QEMU under real UEFI firmware (OVMF), exercising
# the hybrid ISO's UEFI El Torito entry instead of the legacy BIOS path
# tools/run.sh uses.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd

# UEFI firmware writes NVRAM variables to its "vars" pflash, so it can't be
# the shared read-only template - copy it per run.
mkdir -p build
cp "$OVMF_VARS_TEMPLATE" build/OVMF_VARS.fd

qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
    -cdrom build/amethyst-os.iso -boot order=d

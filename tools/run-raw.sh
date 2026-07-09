#!/usr/bin/env bash
# Boots build/amethyst-os.img as a raw disk in QEMU, exercising the same
# code path a real BIOS/USB raw write would (legacy MBR boot at LBA 0),
# independent of the El Torito CD path tools/run.sh uses.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

qemu-system-x86_64 -drive file=build/amethyst-os.img,format=raw -boot order=c

#!/usr/bin/env bash
# Boots the built ISO in QEMU.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

qemu-system-x86_64 -cdrom build/amethyst-os.iso -boot order=d -netdev user,id=n0 -device e1000,netdev=n0

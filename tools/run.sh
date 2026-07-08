#!/usr/bin/env bash
# Boots the built ISO in QEMU.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

qemu-system-x86_64 -cdrom build/AmethystOS.iso -boot order=d

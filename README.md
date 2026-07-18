# AmethystOS

**A standalone x86-64 operating system written in pure NASM assembly with zero external bootloader dependencies.**

---

## Overview

AmethystOS is a standalone x86-64 operating system written from scratch in pure NASM assembly. Built for systems programmers and OS enthusiasts, it demonstrates custom bare-metal initialization, dual BIOS/UEFI booting into 64-bit long mode, custom xHCI USB drivers, and native filesystem parsing without external libraries or third-party bootloaders.

## Features

- **Dual BIOS & UEFI Booting** — Boots seamlessly from legacy MBR/El Torito or modern UEFI firmware directly into 64-bit long mode without external bootloaders.
- **Native xHCI & USB Storage Drivers** — Features custom USB3 controller management and bulk-only mass storage transport for bare-metal disk access.
- **Multi-Filesystem Engine** — Parses and manipulates FAT16, FAT32, exFAT, and NTFS directory structures, including VFAT long filenames and MFT records.
- **Interactive System Shell** — Provides a text-mode command suite for system diagnostics, hardware inspection, memory editing, power management, and file operations.

## Maintainers

| Name | Role | GitHub |
|---|---|---|
| Alexutzu | Lead Engineer | [@alexutzusoft](https://github.com/alexutzusoft) |

## License

TreeSoft Open Source © Alexutzu

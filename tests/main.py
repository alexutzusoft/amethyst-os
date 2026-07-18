#!/usr/bin/env python3
"""AmethystOS test suite entrypoint.

Boots an AmethystOS .iso in a headless QEMU, types a single command into the
shell, captures what ends up on the VGA text-mode screen, prints it, and then
kills QEMU forcefully (no shell exit / shutdown command is issued).

Usage:
    python3 tests/main.py "help"
    python3 tests/main.py "echo hello" --iso path/to/amethyst-os.iso
    python3 tests/main.py "ls" --usb fat32
    python3 tests/main.py "cat readme.txt" --usb ntfs --usb-size 256
"""

import argparse
import os
import sys

# Ensure the tests directory is in sys.path for package imports
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from src.runner import DEFAULT_ISO, print_screen_output, run_command_test
from src.usb import (
    SUPPORTED_FORMATS,
    UsbBuildError,
    build_usb_image,
    ram_backed_dir,
)


def main():
    parser = argparse.ArgumentParser(description="AmethystOS headless test harness.")
    parser.add_argument("command", help="command to type into the AmethystOS shell")
    parser.add_argument("--iso", default=DEFAULT_ISO, help="path to the .iso (default: %(default)s)")
    parser.add_argument("--qemu", default="qemu-system-x86_64", help="QEMU binary")
    parser.add_argument("--memory", type=int, default=256, help="guest RAM in MiB")
    parser.add_argument("--boot-timeout", type=float, default=30.0,
                        help="max seconds to wait for the shell to come up")
    parser.add_argument("--cmd-timeout", type=float, default=15.0,
                        help="max seconds to wait for command output to settle")
    parser.add_argument("--key-delay", type=float, default=0.06,
                        help="delay between simulated keystrokes")
    parser.add_argument("--kvm", action="store_true", help="enable KVM acceleration")
    parser.add_argument("--usb", metavar="FORMAT", type=str.lower, choices=SUPPORTED_FORMATS,
                        help="attach a real USB3 stick formatted as one of: "
                             + ", ".join(SUPPORTED_FORMATS))
    parser.add_argument("--usb-size", type=int, default=128, metavar="MB",
                        help="size of the generated USB image in MiB (default: %(default)s)")
    parser.add_argument("--usb-image", metavar="PATH",
                        help="with --usb: where to write the generated image "
                             "(default: build/usb-<format>.img); without --usb: "
                             "attach this existing image as the USB stick as-is")
    parser.add_argument("--keep-usb", action="store_true",
                        help="don't delete the generated USB image after the run")
    args = parser.parse_args()

    usb_image = None
    keep_usb = args.keep_usb or args.usb_image is not None
    if args.usb:
        if args.usb_image:
            out = args.usb_image
        elif keep_usb:
            # asked to keep it but gave no path -> the conventional build/ name
            out = os.path.join(TESTS_DIR, "..", "build", f"usb-{args.usb}.img")
        else:
            # throwaway: build in RAM (tmpfs) so nothing ever hits a real disk;
            # fall back to build/ only where no tmpfs is available.
            ram = ram_backed_dir()
            name = f"amethyst-usb-{args.usb}-{os.getpid()}.img"
            out = (os.path.join(ram, name) if ram
                   else os.path.join(TESTS_DIR, "..", "build", name))
        try:
            usb_image = build_usb_image(args.usb, out, size_mb=args.usb_size)
        except UsbBuildError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
    elif args.usb_image:
        if not os.path.isfile(args.usb_image):
            print(f"error: usb image not found: {args.usb_image}", file=sys.stderr)
            return 2
        usb_image = args.usb_image

    try:
        rows = run_command_test(
            command=args.command,
            iso=args.iso,
            qemu=args.qemu,
            memory=args.memory,
            boot_timeout=args.boot_timeout,
            cmd_timeout=args.cmd_timeout,
            key_delay=args.key_delay,
            kvm=args.kvm,
            usb_image=usb_image,
        )
    finally:
        if usb_image and not keep_usb:
            try:
                os.remove(usb_image)
            except OSError:
                pass

    if rows is None:
        return 2

    print_screen_output(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())

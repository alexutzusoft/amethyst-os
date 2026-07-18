#!/usr/bin/env python3
"""AmethystOS test suite entrypoint.

Boots an AmethystOS .iso in a headless QEMU, types a single command into the
shell, captures what ends up on the VGA text-mode screen, prints it, and then
kills QEMU forcefully (no shell exit / shutdown command is issued).

Usage:
    python3 tests/main.py "help"
    python3 tests/main.py "echo hello" --iso path/to/amethyst-os.iso
"""

import argparse
import os
import sys

# Ensure the tests directory is in sys.path for package imports
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

from src.runner import DEFAULT_ISO, print_screen_output, run_command_test


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
    args = parser.parse_args()

    rows = run_command_test(
        command=args.command,
        iso=args.iso,
        qemu=args.qemu,
        memory=args.memory,
        boot_timeout=args.boot_timeout,
        cmd_timeout=args.cmd_timeout,
        key_delay=args.key_delay,
        kvm=args.kvm,
    )

    if rows is None:
        return 2

    print_screen_output(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())

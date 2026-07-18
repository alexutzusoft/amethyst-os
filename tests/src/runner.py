"""Test runner and process management for QEMU integration tests."""

import os
import subprocess
import sys
import time

from .keyboard import type_command
from .qmp import QMP, pick_free_port
from .usb import usb_qemu_args
from .vga import VGA_COLS, wait_for_stable_screen

SRC_DIR = os.path.dirname(os.path.abspath(__file__))
TESTS_DIR = os.path.dirname(SRC_DIR)
DEFAULT_ISO = os.path.normpath(os.path.join(TESTS_DIR, "..", "build", "amethyst-os.iso"))


def build_qemu_args(qemu, iso, qmp_port, memory, kvm, usb_image=None):
    """Build command line arguments for QEMU.

    If usb_image is given, attach it as a real xHCI (USB3) mass-storage stick
    so the guest's `usb`/`ls`/`cat`/`cd` commands see it.
    """
    args = [
        qemu,
        "-cdrom", iso,
        "-boot", "d",
        "-m", str(memory),
        "-display", "none",
        "-no-reboot",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server,nowait",
    ]
    if usb_image:
        args += usb_qemu_args(usb_image)
    if kvm:
        args += ["-enable-kvm"]
    return args


def run_command_test(command, iso=DEFAULT_ISO, qemu="qemu-system-x86_64", memory=256,
                     boot_timeout=30.0, cmd_timeout=15.0, key_delay=0.06, kvm=False,
                     usb_image=None):
    """Execute a single shell command inside an AmethystOS guest under QEMU and return output lines."""
    if not os.path.isfile(iso):
        print(f"error: iso not found: {iso}", file=sys.stderr)
        return None

    qmp_port = pick_free_port()
    qemu_args = build_qemu_args(qemu, iso, qmp_port, memory, kvm, usb_image)
    proc = subprocess.Popen(qemu_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    qmp = None
    try:
        qmp = QMP(qmp_port)

        print(f"[*] booting {os.path.basename(iso)}...")
        wait_for_stable_screen(qmp, boot_timeout)

        # The very first sendkey after boot is sometimes swallowed before the
        # guest's keyboard path is fully live; type a space and erase it so
        # the loss hits a throwaway key instead of the command's first letter.
        qmp.hmp("sendkey spc")
        time.sleep(0.3)
        qmp.hmp("sendkey backspace")
        time.sleep(0.3)

        print(f"[*] typing: {command!r}")
        type_command(qmp, command, key_delay)

        # Give the Enter keystroke a moment to register, then wait for the output to settle
        time.sleep(0.3)
        rows = wait_for_stable_screen(qmp, cmd_timeout)
    finally:
        if qmp is not None:
            qmp.close()
        proc.kill()
        proc.wait()

    # Trim trailing blank rows for readable output.
    while rows and not rows[-1]:
        rows.pop()

    return rows


def print_screen_output(rows):
    """Print trimmed screen output rows with visual boundaries."""
    if rows is None:
        return
    print("-" * VGA_COLS)
    print("\n".join(rows))
    print("-" * VGA_COLS)

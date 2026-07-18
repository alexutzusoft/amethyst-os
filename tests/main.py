#!/usr/bin/env python3
"""AmethystOS test harness.

Boots an AmethystOS .iso in a headless QEMU, types a single command into the
shell, captures what ends up on the VGA text-mode screen, prints it, and then
kills QEMU forcefully (no shell exit / shutdown command is issued).

AmethystOS draws straight to the VGA text buffer at physical 0xB8000 rather than
to a serial port, so we can't just read stdout. Instead we drive QEMU over QMP
(TCP on localhost, so it works on Windows/Linux/macOS alike):
  - `sendkey` (via human-monitor-command) types the command,
  - `xp` (examine physical memory) dumps the 80x25 text buffer, which we decode.

Boot and command completion are detected by polling the screen until its
contents stop changing, rather than by fixed sleeps.

Usage:
    python3 tests/main.py "help"
    python3 tests/main.py "echo hello" --iso path/to/amethyst-os.iso
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ISO = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "build", "amethyst-os.iso"))

# VGA text mode: 80 columns x 25 rows, 2 bytes per cell (char, attribute).
VGA_BASE = 0xB8000
VGA_COLS = 80
VGA_ROWS = 25
VGA_CELLS = VGA_COLS * VGA_ROWS
VGA_BYTES = VGA_CELLS * 2


# --------------------------------------------------------------------------- #
# Key mapping: character -> QEMU `sendkey` key name.
# --------------------------------------------------------------------------- #

# Characters produced by pressing a key together with Shift, mapped to the
# unshifted key name that sendkey expects.
_SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right",
    ":": "semicolon", '"': "apostrophe",
    "<": "comma", ">": "dot", "?": "slash",
    "|": "backslash", "~": "grave_accent",
}

# Characters that map directly to a named (unshifted) key.
_DIRECT = {
    " ": "spc", "\t": "tab",
    "-": "minus", "=": "equal",
    "[": "bracket_left", "]": "bracket_right",
    ";": "semicolon", "'": "apostrophe",
    ",": "comma", ".": "dot", "/": "slash",
    "\\": "backslash", "`": "grave_accent",
}


def char_to_sendkey(ch):
    """Translate a single character into a QEMU sendkey argument."""
    if ch.isalpha() and ch.isascii():
        return f"shift-{ch.lower()}" if ch.isupper() else ch
    if ch.isdigit() and ch.isascii():
        return ch
    if ch in _DIRECT:
        return _DIRECT[ch]
    if ch in _SHIFTED:
        return f"shift-{_SHIFTED[ch]}"
    raise ValueError(f"unsupported character in command: {ch!r}")


# --------------------------------------------------------------------------- #
# Minimal QMP client over localhost TCP.
# --------------------------------------------------------------------------- #

def pick_free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class QMP:
    def __init__(self, port, connect_timeout=15.0):
        deadline = time.time() + connect_timeout
        self.sock = None
        while self.sock is None:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5.0)
            except OSError:
                if time.time() > deadline:
                    raise TimeoutError(f"could not connect to QMP on port {port}")
                time.sleep(0.1)
        self.sock.settimeout(10.0)
        self._buf = b""
        self._recv()               # consume the QMP greeting
        self.execute("qmp_capabilities")

    def _recv(self):
        while b"\n" not in self._buf:
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError("QMP connection closed")
            self._buf += data
        line, self._buf = self._buf.split(b"\n", 1)
        return json.loads(line)

    def _recv_result(self):
        # Skip asynchronous events; return the first command result/error.
        while True:
            msg = self._recv()
            if "return" in msg or "error" in msg:
                return msg

    def execute(self, command, **arguments):
        req = {"execute": command}
        if arguments:
            req["arguments"] = arguments
        self.sock.sendall((json.dumps(req) + "\n").encode())
        resp = self._recv_result()
        if "error" in resp:
            raise RuntimeError(f"QMP error for {command}: {resp['error']}")
        return resp["return"]

    def hmp(self, command_line):
        """Run a human-monitor command and return its text output."""
        return self.execute("human-monitor-command", **{"command-line": command_line})

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# Screen capture / input.
# --------------------------------------------------------------------------- #

def read_screen(qmp):
    """Dump the VGA text buffer and return it as a list of 25 text rows."""
    out = qmp.hmp(f"xp /{VGA_BYTES}xb {hex(VGA_BASE)}")
    raw = []
    for line in out.splitlines():
        if ":" not in line:
            continue
        _, rest = line.split(":", 1)
        for tok in rest.split():
            if tok.startswith("0x"):
                raw.append(int(tok, 16))
    chars = raw[0::2]  # even bytes are the glyphs; odd bytes are attributes
    rows = []
    for r in range(VGA_ROWS):
        cells = chars[r * VGA_COLS:(r + 1) * VGA_COLS]
        text = "".join(chr(c) if 32 <= c < 127 else " " for c in cells)
        rows.append(text.rstrip())
    return rows


def wait_for_stable_screen(qmp, timeout, poll_interval=0.3, stable_polls=3,
                           require_nonempty=True):
    """Poll the VGA buffer until it is unchanged for `stable_polls` polls.

    Returns the rows of the settled screen. The blinking hardware cursor lives
    in CRTC registers, not the text buffer, so an idle screen really is static.
    """
    deadline = time.time() + timeout
    prev = None
    stable = 0
    while time.time() < deadline:
        rows = read_screen(qmp)
        if not require_nonempty or any(rows):
            if rows == prev:
                stable += 1
                if stable >= stable_polls:
                    return rows
            else:
                stable = 0
            prev = rows
        time.sleep(poll_interval)
    raise TimeoutError(f"screen did not settle within {timeout}s")


def type_command(qmp, command, key_delay):
    for ch in command:
        qmp.hmp(f"sendkey {char_to_sendkey(ch)}")
        time.sleep(key_delay)
    qmp.hmp("sendkey ret")


# --------------------------------------------------------------------------- #
# Main.
# --------------------------------------------------------------------------- #

def build_qemu_args(qemu, iso, qmp_port, memory, kvm):
    args = [
        qemu,
        "-cdrom", iso,
        "-m", str(memory),
        "-display", "none",
        "-no-reboot",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server,nowait",
    ]
    if kvm:
        args += ["-enable-kvm"]
    return args


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

    if not os.path.isfile(args.iso):
        print(f"error: iso not found: {args.iso}", file=sys.stderr)
        return 2

    qmp_port = pick_free_port()
    qemu_args = build_qemu_args(args.qemu, args.iso, qmp_port, args.memory, args.kvm)
    proc = subprocess.Popen(qemu_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    qmp = None
    try:
        qmp = QMP(qmp_port)

        print(f"[*] booting {os.path.basename(args.iso)}...")
        wait_for_stable_screen(qmp, args.boot_timeout)

        print(f"[*] typing: {args.command!r}")
        type_command(qmp, args.command, args.key_delay)

        # Give the Enter keystroke a moment to register, then wait for the
        # command's output to stop changing.
        time.sleep(0.3)
        rows = wait_for_stable_screen(qmp, args.cmd_timeout)
    finally:
        if qmp is not None:
            qmp.close()
        proc.kill()          # forceful close, no shell exit command
        proc.wait()

    # Trim trailing blank rows for readable output.
    while rows and not rows[-1]:
        rows.pop()

    print("-" * VGA_COLS)
    print("\n".join(rows))
    print("-" * VGA_COLS)
    return 0


if __name__ == "__main__":
    sys.exit(main())

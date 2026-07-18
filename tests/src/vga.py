"""VGA text mode screen capture and polling utilities."""

import time

# VGA text mode: 80 columns x 25 rows, 2 bytes per cell (char, attribute).
VGA_BASE = 0xB8000
VGA_COLS = 80
VGA_ROWS = 25
VGA_CELLS = VGA_COLS * VGA_ROWS
VGA_BYTES = VGA_CELLS * 2


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
